"""Independent Ingress web service. All durable data and HA actions stay in Runtime."""
import hmac
import json
import re
import secrets
import ssl
import asyncio
from urllib.parse import urlsplit
from browser_access import BrowserAccess
from pathlib import Path
from aiohttp import web, ClientSession, ClientTimeout, ClientError

VERSION = "0.3.0"
MAX_RESPONSE = 8 * 1024 * 1024


class DashboardGateway:
    def __init__(self, runtime_url, key, server_id, *, standalone_mode="disabled", standalone_host="homeassistant.local", sessions_path=None):
        self.runtime_url, self.key, self.server_id = runtime_url.rstrip("/"), key, server_id
        self.csrf = secrets.token_urlsafe(32)
        self.session = None
        self.connections = 0
        self.standalone_mode = standalone_mode
        self.standalone_host = standalone_host.lower()
        self.browsers = BrowserAccess(sessions_path)

    @property
    def configured(self):
        return len(self.key) == 64 and bool(self.server_id)

    def app(self, standalone=False):
        @web.middleware
        async def boundary(request, handler):
            if standalone:
                try: host = urlsplit('//'+request.host).hostname
                except ValueError: host = None
                if self.standalone_mode == "disabled" or host != self.standalone_host:
                    return web.Response(status=403)
                user = self.browsers.user(request.cookies.get(BrowserAccess.cookie))
                if user: request['browser_user'] = user
                elif request.path not in ('/', '/api/browser/login'):
                    return web.json_response({'error':'Browser-Anmeldung abgelaufen. Bitte neu verbinden.'}, status=401, headers=self.headers())
            elif request.remote != "172.30.32.2":
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
        app.router.add_get("/", self.browser_page if standalone else self.page)
        if standalone:
            app.router.add_post("/api/browser/login", self.browser_login)
            app.router.add_post("/api/browser/logout", self.browser_logout)
        else:
            app.router.add_post("/api/browser/pair", self.browser_pair)
            app.router.add_post("/api/browser/revoke", self.browser_revoke)
        app.router.add_get("/api/status", self.status)
        app.router.add_get("/api/published", self.proxy)
        app.router.add_get("/api/published/{id}", self.proxy)
        app.router.add_get("/api/published/{id}/values", self.proxy)
        app.router.add_post("/api/published/{id}/actions", self.proxy)
        app.router.add_get("/api/published/{id}/camera/{component}", self.proxy)
        app.cleanup_ctx.append(self.lifecycle)
        return app

    async def lifecycle(self, app):
        if self.session is None: self.session = ClientSession(timeout=ClientTimeout(total=12))
        yield
        if self.session and not self.session.closed: await self.session.close()

    def headers(self):
        return {"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
                "Content-Security-Policy": "default-src 'none'; script-src 'nonce-"+self.csrf+"'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"}

    async def page(self, request):
        folder = Path(__file__).with_name("dashboard_web")
        css = (folder / "renderer.css").read_text() + (folder / "navigation.css").read_text()
        js = (folder / "renderer.js").read_text()
        # Only the session CSRF nonce reaches the browser; no Runtime credential.
        body = """<aside class="tool-sidebar"><div class="tool-brand"><span class="tool-brand-mark"><svg viewBox="0 0 24 24" preserveAspectRatio="none" aria-hidden="true"><path d="M12 1 23 9.5h-3V23h-6.5v-8h-3v8H4V9.5H1Z"/></svg></span><div><strong>Nodivra</strong><small>Dashboards</small></div></div>
        <nav aria-label="Nodivra Navigation"><a class="tool-link" href="./" aria-current="page">Dashboards</a></nav>
        <nav id="dashboard-page-nav" aria-label="Dashboard-Seiten" hidden></nav>
        <nav class="tool-settings"><span class="tool-link">Webdienst 0.3.0 · Gemeinsame Runtime</span></nav></aside><main id="dashboard"></main>"""
        controls = ""
        if request.get('browser_user'):
            controls = '<button id="browser-logout" class="dash-link">Browser abmelden</button>'
        elif self.standalone_mode != "disabled":
            controls = '<button id="browser-pair" class="dash-link">Browser verbinden</button><button id="browser-revoke" class="dash-link">Alle Browser abmelden</button>'
        body += '<div class="browser-tools">'+controls+'<p id="browser-result" role="status"></p></div>'
        browser_script = """
        const api=async(path,body={})=>{const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-Nodivra-CSRF':CSRF},body:JSON.stringify(body)});if(!r.ok)throw Error('Anfrage nicht bestätigt. Verbindung prüfen.');return r.json();};
        const feedback=document.getElementById('browser-result');
        document.getElementById('browser-pair')?.addEventListener('click',async()=>{try{const d=await api('api/browser/pair');feedback.textContent='Öffne '+d.url+' im anderen Browser. Einmalcode: '+d.code+' · 5 Minuten gültig. '+d.notice;}catch(e){feedback.textContent=e.message;}});
        document.getElementById('browser-revoke')?.addEventListener('click',async()=>{if(!confirm('Alle gekoppelten Browser abmelden?'))return;try{await api('api/browser/revoke');feedback.textContent='Alle Browser wurden abgemeldet.';}catch(e){feedback.textContent=e.message;}});
        document.getElementById('browser-logout')?.addEventListener('click',async()=>{try{await api('api/browser/logout');location.reload();}catch(e){feedback.textContent=e.message;}});
        """.replace(':CSRF', ':'+json.dumps(self.csrf))
        return web.Response(text="<!doctype html><html lang='de'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Nodivra Dashboards</title><style>"+css+"</style></head><body class='tool-layout'>"+body+"<script nonce='"+self.csrf+"'>"+js+"\n"+browser_script+"\nNodivra.boot("+json.dumps({"mode":"viewer", "csrf":self.csrf})+");</script></body></html>", content_type="text/html")

    async def browser_pair(self, request):
        if self.standalone_mode == "disabled": raise web.HTTPForbidden()
        await self.check(request)
        code = self.browsers.issue(request.headers.get("X-Remote-User-Id", ""))
        return web.json_response(dict(code=code, url=self.standalone_mode+'://'+self.standalone_host+':8669/', notice='Lokales HTTP ist unverschlüsselt; nur im vertrauenswürdigen Heimnetz verwenden.' if self.standalone_mode=='http' else ''))

    async def browser_revoke(self, request):
        await self.check(request)
        self.browsers.revoke()
        return web.json_response({'revoked':True})

    async def browser_login(self, request):
        data = await request.json()
        token = self.browsers.redeem(data.get('code') if isinstance(data,dict) else None)
        if token is None: return web.json_response({'error':'Code ungültig, abgelaufen oder zu viele Versuche. In HA einen neuen Code erstellen.'}, status=403)
        request['browser_user'] = self.browsers.user(token)
        try: await self.check(request)
        except Exception:
            self.browsers.logout(token)
            raise
        response = web.json_response({'connected':True})
        response.set_cookie(BrowserAccess.cookie, token, max_age=30*86400, httponly=True, secure=self.standalone_mode=='https', samesite='Strict', path='/')
        return response

    async def browser_logout(self, request):
        self.browsers.logout(request.cookies.get(BrowserAccess.cookie))
        response = web.json_response({'disconnected':True}); response.del_cookie(BrowserAccess.cookie, path='/')
        return response

    async def browser_page(self, request):
        if request.get('browser_user'):
            await self.check(request)
            return await self.page(request)
        nonce = self.csrf
        html = """<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Nodivra · Browser verbinden</title>
        <style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#171d20;color:#eef1f4;font:14px -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:360px;padding:32px}h1{font-size:23px;font-weight:400}p{line-height:1.6;color:#aab5bf}input,button{font:inherit;padding:12px;border-radius:9px;border:1px solid #414950;box-sizing:border-box;width:100%;margin-top:10px}input{background:#242b30;color:white}button{background:#1673ff;color:white;cursor:pointer}</style>
        <main><h1><svg width="20" height="17" viewBox="0 0 24 24" preserveAspectRatio="none" aria-hidden="true" style="fill:#1673ff;margin-right:8px"><path d="M12 1 23 9.5h-3V23h-6.5v-8h-3v8H4V9.5H1Z"/></svg>Nodivra Dashboards</h1><p>Öffne Nodivra Dashboards in Home Assistant und wähle „Browser verbinden“. Gib hier den fünf Minuten gültigen Einmalcode ein.</p><input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="10" aria-label="Einmalcode" placeholder="Einmalcode"><button id="login">Verbinden</button><p id="result" role="status"></p></main>
        <script nonce="NONCE">document.getElementById('login').onclick=async()=>{const b=document.getElementById('login');b.disabled=true;try{const r=await fetch('api/browser/login',{method:'POST',headers:{'Content-Type':'application/json','X-Nodivra-CSRF':CSRF},body:JSON.stringify({code:document.getElementById('code').value.trim()})});if(r.ok){location.reload();return;}document.getElementById('result').textContent='Verbindung nicht bestätigt. Code und Runtime prüfen.';}catch(e){document.getElementById('result').textContent='Webdienst nicht erreichbar.';}finally{b.disabled=false;}};</script></html>"""
        return web.Response(text=html.replace('NONCE',nonce).replace(':CSRF',':'+json.dumps(nonce)),content_type='text/html')

    def upstream_headers(self, request):
        return {"Authorization": "Bearer " + self.key, "X-Nodivra-HA-User": request.get("browser_user", request.headers.get("X-Remote-User-Id", ""))}

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
    mode = options.get('standalone_mode', 'disabled')
    host = options.get('standalone_host', 'homeassistant.local').lower()
    if mode not in ('disabled','http','https') or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}',host): raise ValueError('Ungültige Browser-Konfiguration.')
    context = None
    if mode == 'https':
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain('/ssl/fullchain.pem','/ssl/privkey.pem')
    gateway = DashboardGateway(address, options.get("access_key", ""), options.get("server_id", ""), standalone_mode=mode, standalone_host=host, sessions_path='/data/browser-sessions.json')
    async def run():
        ingress = web.AppRunner(gateway.app(), access_log=None)
        await ingress.setup(); await web.TCPSite(ingress,'0.0.0.0',8099).start()
        direct = None
        try:
            if mode != 'disabled':
                direct = web.AppRunner(gateway.app(standalone=True),access_log=None)
                await direct.setup(); await web.TCPSite(direct,'0.0.0.0',8669,ssl_context=context).start()
            await asyncio.Event().wait()
        finally:
            if direct: await direct.cleanup()
            await ingress.cleanup()
    asyncio.run(run())


if __name__ == "__main__":
    main()
