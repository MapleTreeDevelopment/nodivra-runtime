"""Independent Ingress web service. All durable data and HA actions stay in Runtime."""
import hmac
import json
import re
import secrets
from pathlib import Path
from aiohttp import web, ClientSession, ClientTimeout, ClientError

VERSION = "0.1.0"
MAX_RESPONSE = 8 * 1024 * 1024


class DashboardGateway:
    def __init__(self, runtime_url, key, server_id):
        self.runtime_url, self.key, self.server_id = runtime_url.rstrip("/"), key, server_id
        self.csrf = secrets.token_urlsafe(32)
        self.session = None
        self.connections = 0

    @property
    def configured(self):
        return len(self.key) == 64 and bool(self.server_id)

    def app(self):
        @web.middleware
        async def boundary(request, handler):
            if request.remote != "172.30.32.2":
                return web.Response(status=403)
            if request.method not in ("GET", "HEAD") and (
                request.content_type != "application/json" or not
                hmac.compare_digest(request.headers.get("X-Nodivra-CSRF", "").encode(), self.csrf.encode())):
                return web.Response(status=403)
            try:
                response = await handler(request)
            except web.HTTPException as error:
                message = {401: "Dashboard-Verbindung ungültig. In der Mac-App neu verbinden.",
                           403: "Zugriff nicht erlaubt. Mit einem HA-Administratorkonto öffnen.",
                           409: "Die verbundene Runtime stimmt nicht überein. Verbindung in der Mac-App prüfen.",
                           502: "Die Runtime hat keine gültige Antwort geliefert.",
                           503: "Runtime nicht erreichbar. Bedienung pausiert; Aktionen werden nicht automatisch wiederholt."}.get(error.status, "Anfrage nicht zulässig.")
                response = web.json_response({"error": message}, status=error.status)
            except (ClientError, TimeoutError, ValueError, TypeError, KeyError):
                response = web.json_response({"error": "Runtime nicht erreichbar. Bedienung pausiert; Aktionen werden nicht automatisch wiederholt."}, status=503)
            if not response.prepared:
                response.headers.update(self.headers())
            return response

        app = web.Application(middlewares=[boundary], client_max_size=8192)
        app.router.add_get("/", self.page)
        app.router.add_get("/api/status", self.status)
        app.router.add_get("/api/published", self.proxy)
        app.router.add_get("/api/published/{id}", self.proxy)
        app.router.add_get("/api/published/{id}/values", self.proxy)
        app.router.add_post("/api/published/{id}/actions", self.proxy)
        app.router.add_get("/api/published/{id}/camera/{component}", self.proxy)
        app.cleanup_ctx.append(self.lifecycle)
        return app

    async def lifecycle(self, app):
        self.session = ClientSession(timeout=ClientTimeout(total=12))
        yield
        await self.session.close()

    def headers(self):
        return {"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
                "Content-Security-Policy": "default-src 'none'; script-src 'nonce-"+self.csrf+"'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"}

    async def page(self, request):
        folder = Path(__file__).with_name("dashboard_web")
        css = (folder / "renderer.css").read_text() + (folder / "navigation.css").read_text()
        js = (folder / "renderer.js").read_text()
        # Only the session CSRF nonce reaches the browser; no Runtime credential.
        body = """<aside class="tool-sidebar"><div class="tool-brand"><div><strong>Nodivra</strong><small>Dashboards</small></div></div>
        <nav aria-label="Nodivra Navigation"><a class="tool-link" href="./" aria-current="page">Dashboards</a></nav>
        <nav id="dashboard-page-nav" aria-label="Dashboard-Seiten" hidden></nav>
        <nav class="tool-settings"><span class="tool-link">Webdienst 0.1.0 · Gemeinsame Runtime</span></nav></aside><main id="dashboard"></main>"""
        return web.Response(text="<!doctype html><html lang='de'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Nodivra Dashboards</title><style>"+css+"</style></head><body class='tool-layout'>"+body+"<script nonce='"+self.csrf+"'>"+js+"\nNodivra.boot("+json.dumps({"mode":"viewer", "csrf":self.csrf})+");</script></body></html>", content_type="text/html")

    def upstream_headers(self, request):
        return {"Authorization": "Bearer " + self.key, "X-Nodivra-HA-User": request.headers.get("X-Remote-User-Id", "")}

    async def check(self, request):
        if not self.configured:
            raise web.HTTPServiceUnavailable()
        async with self.session.get(self.runtime_url+"/api/v1/dashboard-display/status", headers=self.upstream_headers(request), allow_redirects=False) as response:
            if response.status == 401:
                raise web.HTTPUnauthorized()
            if response.status == 403:
                raise web.HTTPForbidden()
            if response.status != 200:
                raise web.HTTPServiceUnavailable()
            data = await response.json()
            if data.get("serverID") != self.server_id or data.get("protocolVersion") != 1:
                raise web.HTTPConflict()
            return data

    async def status(self, request):
        data = await self.check(request)
        return web.json_response({"version": VERSION, "runtimeVersion": data.get("version"), "connected": data.get("connected") is True})

    async def proxy(self, request):
        if not self.configured:
            return web.json_response({"error": "Verbinde diese App in der Nodivra Mac-App unter Runtime → Dashboard-Webdienst. Vorhandene Dashboards bleiben in der gemeinsamen Runtime gespeichert."}, status=503)
        if self.connections >= 16:
            return web.json_response({"error": "Viele gleichzeitige Anfragen. Bitte kurz warten."}, status=429)
        self.connections += 1
        response = None
        try:
            await self.check(request)
            suffix = request.path.removeprefix("/api/")
            camera = "/camera/" in suffix
            # Only fixed, registered display routes are proxied. Never forward arbitrary URLs or headers.
            url = self.runtime_url + "/api/v1/dashboard-display/" + suffix
            body = await request.read() if request.method == "POST" else None
            headers = self.upstream_headers(request)
            if body is not None: headers["Content-Type"] = "application/json"
            async with self.session.request(request.method, url, params=request.query, data=body, headers=headers,
                                            allow_redirects=False, timeout=ClientTimeout(total=50 if camera else 12, sock_read=15)) as upstream:
                if upstream.status != 200:
                    # Do not echo an upstream HTML page, redirect URL, or credential-bearing error.
                    message = {401:"Dashboard-Verbindung ungültig. In der Mac-App neu verbinden.",
                               403:"Zugriff nicht erlaubt. Mit einem HA-Administratorkonto öffnen.",
                               409:"Dashboard geändert. Bitte neu laden; eine Aktion nicht ungeprüft wiederholen.",
                               404:"Dashboard oder Komponente nicht vorhanden.",
                               429:"Zu viele gleichzeitige Anfragen. Bitte kurz warten."}.get(upstream.status, "Anfrage nicht bestätigt. Runtime-Verbindung und Gerätezustand prüfen.")
                    return web.json_response({"error":message}, status=upstream.status if 400 <= upstream.status < 600 else 502)
                if camera:
                    if upstream.content_type not in ("image/jpeg", "image/png", "multipart/x-mixed-replace"):
                        raise web.HTTPBadGateway()
                    response = web.StreamResponse(headers=self.headers() | {"Content-Type":upstream.headers["Content-Type"]})
                    await response.prepare(request)
                    async for chunk in upstream.content.iter_chunked(65536): await response.write(chunk)
                    await response.write_eof()
                    return response
                if upstream.content_type != "application/json": raise web.HTTPBadGateway()
                data = bytearray()
                async for chunk in upstream.content.iter_chunked(65536):
                    data.extend(chunk)
                    if len(data) > MAX_RESPONSE: raise web.HTTPBadGateway()
                return web.Response(body=data, content_type="application/json")
        except (ClientError, TimeoutError, ConnectionError):
            if response is not None: return response
            raise web.HTTPServiceUnavailable()
        finally:
            self.connections -= 1


def main():
    options = json.loads(Path("/data/options.json").read_text())
    address = options.get("runtime_url", "")
    if not re.fullmatch(r"http://[a-z0-9]+-nodivra-runtime:8668", address):
        raise ValueError("Bitte den internen Hostnamen der Nodivra Runtime einstellen.")
    gateway = DashboardGateway(address, options.get("access_key", ""), options.get("server_id", ""))
    web.run_app(gateway.app(), host="0.0.0.0", port=8099, access_log=None, print=lambda _: None)


if __name__ == "__main__":
    main()
