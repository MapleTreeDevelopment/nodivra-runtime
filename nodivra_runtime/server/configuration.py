"""Home Assistant ingress configuration; never available on the LAN API port."""
import asyncio
import hashlib
import hmac
from pathlib import Path
import secrets
import time
import platform
import uuid
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from dashboards import DashboardError
from navigation import navigation, navigation_style
from aiohttp import web, ClientSession, ClientTimeout

class RuntimeConfiguration:
    def __init__(self, runtime, token, supervisor="http://supervisor"):
        self.runtime, self.token, self.supervisor = runtime, token, supervisor
        self.csrf = secrets.token_urlsafe(32)
        self.lock = asyncio.Lock()
        self.info_cache = None
        self.info_at = 0

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
                if request.path != "/" and not await self.runtime.ha.is_admin(request.headers.get("X-Remote-User-Id", "")):
                    return web.json_response({"error": "Bitte mit einem Home-Assistant-Administratorkonto öffnen. Falls Home Assistant gerade startet, die Seite anschließend neu laden."}, status=403, headers={"Cache-Control": "no-store"})
                response = await handler(request)
            except DashboardError as error:
                response = web.json_response({"error": error.message}, status=error.status)
            except web.HTTPException as error:
                response = web.json_response({"error": "Anfrage konnte nicht verarbeitet werden."}, status=error.status)
            except (ValueError, TypeError, KeyError):
                response = web.json_response({"error": "Ungültige Anfrage."}, status=422)
            except Exception:
                response = web.json_response({"error": "Anfrage nicht bestätigt. Bitte den aktuellen Status neu laden, bevor du die Aktion erneut ausführst."}, status=503)
            response.headers.update({"Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                "Content-Security-Policy": "default-src 'none'; script-src 'nonce-" + self.csrf + "'; style-src 'nonce-" + self.csrf + "'; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"})
            if request.path.startswith("/dashboards/"):
                response.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'nonce-" + self.csrf + "'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"
            return response
        app = web.Application(middlewares=[boundary], client_max_size=8192)
        if hasattr(self.runtime, "dashboards"): self.runtime.dashboards.ingress_routes(app, self.csrf)
        app.router.add_get("/", self.page)
        app.router.add_get("/status", self.status)
        app.router.add_get("/dashboard", self.dashboard)
        app.router.add_post("/automations/{id}/state", self.program_state)
        app.router.add_post("/automations/{id}/recovery", self.program_recovery)
        app.router.add_post("/generate", self.generate)
        app.router.add_post("/apply", self.apply)
        return app

    async def page(self, request):
        view = "runtime" if request.query.get("view") == "runtime" else "automations"
        title, subtitle = (("Runtime", "Eine Verbindung für alle deine Werkzeuge.") if view == "runtime"
                           else ("Automationen", "Deine Abläufe. Direkt im Blick."))
        html = Path(__file__).with_name("configuration.html").read_text()
        for key, value in {"__NONCE__": self.csrf, "__NAV_STYLE__": navigation_style(), "__NAVIGATION__": navigation(view),
                           "__VIEW__": view, "__TITLE__": title, "__SUBTITLE__": subtitle}.items():
            html = html.replace(key, value)
        return web.Response(text=html, content_type="text/html")

    async def status(self, request):
        info = await self.call("GET", "/addons/self/info")
        key = info["options"].get("access_key", "")
        # Hash is a concurrency token, not the credential itself.
        return web.json_response({"configured": len(key) >= 32, "revision": hashlib.sha256(key.encode()).hexdigest(),
                                  "version": info.get("version", ""), "connected": self.runtime.ha.connected})

    @staticmethod
    def addon_summary(info):
        return {"installedVersion": info.get("version"), "latestVersion": info.get("version_latest"),
                "updateAvailable": info.get("update_available") is True}

    async def dashboard(self, request):
        unavailable = False
        if self.info_cache is None or time.monotonic() - self.info_at > 15:
            try:
                self.info_cache = self.addon_summary(await self.call("GET", "/addons/self/info"))
                self.info_at = time.monotonic()
            except Exception:
                unavailable = True
        return web.json_response(self.runtime.dashboard() | {"addon": None if unavailable else self.info_cache,
                                "architecture": platform.machine(), "configured": len(self.runtime.key) >= 32})

    async def program_state(self, request):
        identity = str(uuid.UUID(request.match_info["id"]))
        data = await request.json()
        if not isinstance(data, dict) or type(data.get("expectedStateVersion")) is not int:
            return web.json_response({"error": "Status zuerst aktualisieren."}, status=422)
        if data.get("enabled") is True and data.get("mode") == "execute" and data.get("confirmExecution") is not True:
            return web.json_response({"error": "Bitte das Aktivieren mit Geräteaktionen bestätigen."}, status=409)
        # The Mac API and ingress share the same locks, validation and lifecycle.
        response = await self.runtime.change_state(identity, data)
        return web.json_response({"updated": True}) if response.status == 200 else response

    async def program_recovery(self, request):
        identity = str(uuid.UUID(request.match_info["id"]))
        response = await self.runtime.change_recovery(identity, await request.json())
        return web.json_response({"updated": True}) if response.status == 200 else response

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
