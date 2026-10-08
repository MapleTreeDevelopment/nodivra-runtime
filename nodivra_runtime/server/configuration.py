"""Home Assistant ingress configuration; never available on the LAN API port."""
import asyncio
import hashlib
import hmac
from pathlib import Path
import secrets
from aiohttp import web, ClientSession, ClientTimeout

class RuntimeConfiguration:
    def __init__(self, runtime, token, supervisor="http://supervisor"):
        self.runtime, self.token, self.supervisor = runtime, token, supervisor
        self.csrf = secrets.token_urlsafe(32)
        self.lock = asyncio.Lock()

    async def call(self, method, path, data=None):
        async with ClientSession(timeout=ClientTimeout(total=15)) as session:
            async with session.request(method, self.supervisor + path, json=data,
                                       headers={"Authorization": "Bearer " + self.token}, allow_redirects=False) as response:
                if response.status != 200:
                    raise RuntimeError("Konfiguration konnte nicht gespeichert werden.")
                result = await response.json()
                if result.get("result") != "ok":
                    raise RuntimeError("Konfiguration konnte nicht bestätigt werden.")
                return result.get("data", {})

    def app(self):
        @web.middleware
        async def boundary(request, handler):
            # Trust the TCP peer, never a user-controlled forwarded header.
            if request.remote != "172.30.32.2":
                return web.Response(status=403)
            if request.method != "GET" and (request.content_type != "application/json" or
                    not hmac.compare_digest(request.headers.get("X-Nodivra-CSRF", "").encode(), self.csrf.encode())):
                return web.Response(status=403)
            try:
                response = await handler(request)
            except (ValueError, TypeError, KeyError):
                response = web.json_response({"error": "Ungültige Anfrage."}, status=422)
            except Exception:
                response = web.json_response({"error": "Speichern nicht bestätigt. Bitte die Konfiguration erneut öffnen; kein Schlüssel wird automatisch wiederholt ersetzt."}, status=503)
            response.headers.update({"Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                "Content-Security-Policy": "default-src 'none'; script-src 'nonce-" + self.csrf + "'; style-src 'nonce-" + self.csrf + "'; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"})
            return response
        app = web.Application(middlewares=[boundary], client_max_size=8192)
        app.router.add_get("/", self.page)
        app.router.add_get("/status", self.status)
        app.router.add_post("/generate", self.generate)
        app.router.add_post("/apply", self.apply)
        return app

    async def page(self, request):
        return web.Response(text=Path(__file__).with_name("configuration.html").read_text().replace("__NONCE__", self.csrf), content_type="text/html")

    async def status(self, request):
        info = await self.call("GET", "/addons/self/info")
        key = info["options"].get("access_key", "")
        # Hash is a concurrency token, not the credential itself.
        return web.json_response({"configured": len(key) >= 32, "revision": hashlib.sha256(key.encode()).hexdigest(),
                                  "version": info.get("version", ""), "connected": self.runtime.ha.connected})

    async def generate(self, request):
        return web.json_response({"key": secrets.token_hex(32)})

    async def apply(self, request):
        data = await request.json()
        key = data.get("key", "")
        if not isinstance(key, str) or len(key) != 64 or any(c not in "0123456789abcdef" for c in key):
            raise ValueError("Invalid key")
        async with self.lock:
            info = await self.call("GET", "/addons/self/info")
            options = info["options"]
            old = options.get("access_key", "")
            if old.startswith("!secret "):
                return web.json_response({"error": "Der Schlüssel wird über secrets.yaml verwaltet. Bitte diese Zuordnung zuerst in Home Assistant ändern."}, status=409)
            if hashlib.sha256(old.encode()).hexdigest() != data.get("revision"):
                return web.json_response({"error": "Die Konfiguration wurde geändert. Bitte die Seite neu laden."}, status=409)
            if len(old) >= 32 and data.get("confirmReplacement") is not True:
                return web.json_response({"error": "Bitte das Ersetzen des bisherigen Schlüssels bestätigen."}, status=409)
            options["access_key"] = key
            try:
                await self.call("POST", "/addons/self/options", {"options": options})
            except Exception:
                pass  # A lost acknowledgement is reconciled by reading, never repeating the write.
            saved = await self.call("GET", "/addons/self/info")
            if saved["options"].get("access_key") != key:
                raise RuntimeError("Unconfirmed write")
            self.runtime.key = key
            return web.json_response({"saved": True, "revision": hashlib.sha256(key.encode()).hexdigest()})
