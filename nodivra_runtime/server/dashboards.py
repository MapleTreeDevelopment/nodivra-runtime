"""Independent, revisioned dashboard documents. No Lovelace or automation writes."""
import asyncio
import base64
from contextlib import contextmanager
from collections import deque
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import threading
import time
import uuid
from aiohttp import web, ClientTimeout, ClientError

MAX_DOCUMENT = 4 * 1024 * 1024
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
ENTITY = re.compile(r"^[a-z_][a-z0-9_]*\.[a-z0-9_]+$")

class DashboardError(Exception):
    def __init__(self, status, message): self.status, self.message = status, message

def canonical(value): return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
def require(condition, message="Ungültiges Dashboard.", status=422):
    if not condition: raise DashboardError(status, message)
def identifier(value):
    require(isinstance(value, str) and UUID.fullmatch(value) is not None, "Ungültige Kennung.")
    return value
def text(value, limit=160): return isinstance(value, str) and len(value) <= limit
def number(value, low, high): return type(value) is int and low <= value <= high

def validate(document, complete=False):
    require(isinstance(document, dict))
    require(document.get("schemaVersion") == 1, "Diese Dashboard-Version wird noch nicht unterstützt.")
    identifier(document.get("id"))
    require(text(document.get("title")) and document["title"].strip(), "Gib dem Dashboard einen Namen.")
    require("subtitle" not in document or text(document["subtitle"], 240))
    require("showClock" not in document or type(document["showClock"]) is bool)
    require(len(canonical(document).encode()) <= MAX_DOCUMENT, "Das Dashboard ist zu groß (maximal 4 MB).")
    theme = document.get("theme", {})
    require(isinstance(theme, dict) and theme.get("palette") in (None, "slate", "cloud", "sand", "midnight"))
    require(isinstance(theme, dict) and theme.get("appearance") in ("system", "light", "dark") and theme.get("font") in ("system", "rounded", "serif"))
    require(isinstance(theme.get("accent"), str) and re.fullmatch(r"#[a-fA-F0-9]{6}", theme["accent"]) is not None)
    require(number(theme.get("radius"), 0, 32) and number(theme.get("spacing"), 4, 24) and number(theme.get("fontSize"), 12, 22))
    assets = document.get("assets", [])
    require(isinstance(assets, list) and len(assets) <= 12)
    asset_ids = set()
    for asset in assets:
        require(isinstance(asset, dict)); identity = identifier(asset.get("id")); require(identity not in asset_ids)
        asset_ids.add(identity)
        require(asset.get("mime") == "image/png" and text(asset.get("data"), 750000), "Bilder müssen als begrenzte PNG-Dateien vorliegen.")
        try: data = base64.b64decode(asset["data"], validate=True)
        except (ValueError, TypeError): raise DashboardError(422, "Ungültiges Bild.")
        require(24 <= len(data) <= 512 * 1024 and data.startswith(b"\x89PNG\r\n\x1a\n") and data[12:16] == b"IHDR", "Ungültiges PNG-Bild.")
        require(0 < int.from_bytes(data[16:20], "big") <= 1600 and 0 < int.from_bytes(data[20:24], "big") <= 1600, "Bild zu groß.")
    pages = document.get("pages")
    require(isinstance(pages, list) and 1 <= len(pages) <= 20, "Ein Dashboard benötigt 1 bis 20 Seiten.")
    ids = set(); count = 0
    for page in pages:
        require(isinstance(page, dict)); identity = identifier(page.get("id")); require(identity not in ids); ids.add(identity)
        require(text(page.get("title")) and page["title"].strip())
        require(isinstance(page.get("components"), list)); count += len(page["components"]); require(count <= 200, "Maximal 200 Komponenten pro Dashboard.")
        for c in page["components"]:
            require(isinstance(c, dict)); identity = identifier(c.get("id")); require(identity not in ids); ids.add(identity)
            require(c.get("kind") in ("weather", "light", "climate", "scene", "switch", "value", "text", "image", "camera", "graph"))
            require(text(c.get("title")) and text(c.get("text"), 10000) and text(c.get("unit"), 32) and text(c.get("assetID"), 36))
            require(c.get("effect", "none") in ("none", "glow", "pulse") and type(c.get("animated", True)) is bool and c.get("cameraMode", "stream") in ("stream", "snapshots"))
            if "weather" in c:
                weather = c["weather"]
                require(isinstance(weather, dict) and weather.get("style") in ("minimal", "compact", "detail"))
                require(all(type(weather.get(key)) is bool for key in ("showCondition", "showHumidity", "showWind")))
            require("showTitle" not in c or type(c["showTitle"]) is bool)
            require(isinstance(c.get("layouts"), dict))
            for size, cols in (("desktop", 12), ("tablet", 8), ("mobile", 4)):
                f = c["layouts"].get(size, {})
                require(isinstance(f, dict) and number(f.get("x"), 0, cols-1) and number(f.get("y"), 0, 100) and number(f.get("width"), 1, cols) and number(f.get("height"), 2, 12))
                require(f["x"] + f["width"] <= cols, "Eine Komponente liegt außerhalb des Rasters.")
            b = c.get("binding", {})
            require(isinstance(b, dict) and b.get("source") in ("entity", "runtime"))
            require(all(text(b.get(k), 180) for k in ("entityID", "attribute", "programID", "blockID", "metric")))
            require(not b["entityID"] or ENTITY.fullmatch(b["entityID"]) is not None)
            area = b.get("areaID")
            if area is not None:
                require(c["kind"] == "light" and b["source"] == "entity" and text(area,180) and bool(area) and not b["entityID"] and not b["attribute"], "Ungültiges Bereichsziel.")
            linked = c.get("brightnessBinding")
            if linked is not None:
                require(c["kind"] == "light" and isinstance(linked, dict) and linked.get("source") == "runtime" and linked.get("metric") == "number")
                require(all(text(linked.get(k), 180) for k in ("entityID", "attribute", "programID", "blockID", "metric")))
                if complete: identifier(linked["programID"]); identifier(linked["blockID"])
            if complete:
                if c["kind"] == "image": require(c["assetID"] in asset_ids, c["title"] + ": Bild fehlt.")
                if c["kind"] not in ("image", "text"):
                    if b["source"] == "entity": require(bool(b["entityID"]) or bool(area), c["title"] + ": Entität fehlt.")
                    else:
                        identifier(b["programID"]); identifier(b["blockID"])
                        require(b["metric"] in ("signal", "number", "remaining"))
                if c["kind"] in ("scene", "climate", "weather"): require(b["source"] == "entity" and b["entityID"].startswith(c["kind"]+".") and not b["attribute"], "Ungültiges Ziel.")
                if c["kind"] == "camera": require(b["source"] == "entity" and b["entityID"].startswith("camera.") and not b["attribute"], c["title"] + ": Kamera-Entität fehlt.")
                if c["kind"] in ("light", "switch"):
                    domains = ("light",) if c["kind"] == "light" else ("light", "switch", "input_boolean")
                    require(b["source"] == "entity" and (b["entityID"].split(".")[0] in domains or bool(area)) and not b["attribute"], c["title"] + ": Ungültiges Schaltziel.")
    return document

class DashboardStore:
    """Short-lived connections run on worker threads, never the PLC event loop."""
    def __init__(self, path):
        self.path = Path(path) / "dashboards.sqlite"
        self.backups = Path(path) / "dashboard-backups"
        self.lock = threading.RLock()
        with self.connect() as db:
            db.executescript("""
              CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, document TEXT, revision TEXT, state_version INTEGER, published TEXT, created REAL, updated REAL);
              CREATE TABLE IF NOT EXISTS revisions(id TEXT, revision TEXT PRIMARY KEY, document TEXT, created REAL);
              CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY, digest TEXT, response TEXT, created REAL);
              CREATE TABLE IF NOT EXISTS actions(id TEXT PRIMARY KEY, digest TEXT, response TEXT, created REAL);
            """)
    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA journal_mode=WAL"); db.execute("PRAGMA synchronous=FULL")
            with db: yield db
        finally: db.close()
    @staticmethod
    def record(row):
        require(row is not None, "Dashboard nicht gefunden.", 404)
        return dict(id=row["id"], document=json.loads(row["document"]), revision=row["revision"], stateVersion=row["state_version"], publishedRevision=row["published"], created=row["created"], updated=row["updated"])
    def read(self, identity=None):
        with self.lock, self.connect() as db:
            if identity: return self.record(db.execute("SELECT * FROM documents WHERE id=?", (identifier(identity),)).fetchone())
            return [self.record(row) for row in db.execute("SELECT * FROM documents ORDER BY updated DESC")]
    def history(self, identity):
        with self.lock, self.connect() as db:
            return [dict(revision=r["revision"], document=json.loads(r["document"]), created=r["created"]) for r in db.execute("SELECT * FROM revisions WHERE id=? ORDER BY created DESC", (identifier(identity),))]
    def backup(self, db):
        self.backups.mkdir(exist_ok=True)
        # Replace the oldest complete backup only after writing a new snapshot.
        target = self.backups / (str(time.time_ns()) + ".sqlite")
        with sqlite3.connect(target) as output: db.backup(output)
        for old in sorted(self.backups.glob("*.sqlite"))[:-3]: old.unlink()
    def change(self, identity, operation, data):
        identifier(identity); require(isinstance(data, dict)); request_id = identifier(data.get("requestID"))
        digest = hashlib.sha256(canonical([identity, operation, data]).encode()).hexdigest()
        with self.lock, self.connect() as db:
            previous = db.execute("SELECT digest,response FROM requests WHERE id=?", (request_id,)).fetchone()
            if previous:
                require(previous[0] == digest, "Diese Auftragskennung gehört zu einer anderen Änderung.", 409)
                return json.loads(previous[1])
            old = db.execute("SELECT * FROM documents WHERE id=?", (identity,)).fetchone()
            require((old is None and data.get("expectedRevision") is None and data.get("expectedStateVersion") is None) or (old is not None and data.get("expectedRevision") == old["revision"] and type(data.get("expectedStateVersion")) is int and data["expectedStateVersion"] == old["state_version"]), "Die Serverfassung wurde geändert. Lade sie neu; dein lokaler Entwurf bleibt erhalten.", 409)
            require(old is not None or operation == "save", "Dashboard nicht gefunden.", 404)
            if old is None: require(db.execute("SELECT COUNT(*) FROM documents").fetchone()[0] < 50, "Maximal 50 Dashboards.")
            now = time.time(); document = None
            if operation == "save": document = validate(data.get("document")); require(document["id"] == identity)
            elif operation == "restore":
                row = db.execute("SELECT document FROM revisions WHERE id=? AND revision=?", (identity, identifier(data.get("revision")))).fetchone()
                require(row is not None, "Diese Version ist nicht mehr vorhanden.", 404); document = validate(json.loads(row[0]))
            elif operation == "publish": validate(json.loads(old["document"]), complete=True)
            else: require(operation == "unpublish")
            self.backup(db)
            with db:
                if document is not None:
                    revision = str(uuid.uuid4()); encoded = canonical(document)
                    db.execute("INSERT INTO revisions VALUES(?,?,?,?)", (identity, revision, encoded, now))
                    db.execute("INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,?,?)", (identity, encoded, revision, old["state_version"]+1 if old else 1, old["published"] if old else None, old["created"] if old else now, now))
                else: db.execute("UPDATE documents SET published=?,state_version=state_version+1,updated=? WHERE id=?", (old["revision"] if operation == "publish" else None, now, identity))
                result = self.record(db.execute("SELECT * FROM documents WHERE id=?", (identity,)).fetchone())
                db.execute("INSERT INTO requests VALUES(?,?,?,?)", (request_id, digest, canonical(result), now))
                db.execute("DELETE FROM requests WHERE id NOT IN (SELECT id FROM requests ORDER BY created DESC LIMIT 100)")
                db.execute("DELETE FROM revisions WHERE id=? AND revision NOT IN (SELECT revision FROM revisions WHERE id=? ORDER BY created DESC LIMIT 20) AND revision != COALESCE(?, '')", (identity, identity, result["publishedRevision"]))
            return result
    def published(self, identity):
        with self.lock, self.connect() as db:
            row = db.execute("SELECT r.document,r.revision FROM documents d JOIN revisions r ON r.revision=d.published WHERE d.id=?", (identifier(identity),)).fetchone()
            require(row is not None, "Dieses Dashboard ist nicht veröffentlicht.", 404)
            return dict(id=identity, revision=row["revision"], document=json.loads(row["document"]))
    def action_claim(self, request_id, digest):
        with self.lock, self.connect() as db:
            old = db.execute("SELECT digest,response FROM actions WHERE id=?", (request_id,)).fetchone()
            if old:
                require(old[0] == digest, "Auftragskennung bereits verwendet.", 409)
                return json.loads(old[1])
            response = {"status": "unconfirmed", "message": "Aufruf bereits angenommen. Eine Bestätigung liegt noch nicht vor; Gerätezustand prüfen."}
            db.execute("INSERT INTO actions VALUES(?,?,?,?)", (request_id, digest, canonical(response), time.time()))
            db.execute("DELETE FROM actions WHERE id NOT IN (SELECT id FROM actions ORDER BY created DESC LIMIT 1000)")
            return None
    def action_finish(self, request_id, result):
        with self.lock, self.connect() as db: db.execute("UPDATE actions SET response=? WHERE id=?", (canonical(result), request_id))

class UnavailableDashboardStore:
    def __getattr__(self, name):
        raise DashboardError(503, "Der Dashboard-Speicher konnte nicht geöffnet werden. Die Datei bleibt erhalten. Bitte die Runtime-Protokolle und Sicherung prüfen. Automationsfunktionen bleiben verfügbar.")

class DashboardService:
    def __init__(self, runtime, path):
        self.runtime = runtime
        try: self.store = DashboardStore(path)
        except (sqlite3.Error, OSError): self.store = UnavailableDashboardStore()
        self.recent = deque(); self.action_lock = asyncio.Lock(); self.camera_count = 0
    async def call(self, function, *args): return await asyncio.to_thread(function, *args)
    def routes(self, app):
        app.router.add_get("/api/v1/dashboards", self.list_documents)
        app.router.add_post("/api/v1/dashboards/preview", self.preview)
        app.router.add_get("/api/v1/dashboards/{id}", self.get_document)
        app.router.add_put("/api/v1/dashboards/{id}", self.save)
        app.router.add_get("/api/v1/dashboards/{id}/revisions", self.revisions)
        for operation in ("publish", "unpublish", "restore"): app.router.add_post("/api/v1/dashboards/{id}/"+operation, self.change)
        prefix = "/api/v1/dashboard-display"
        app.router.add_get(prefix+"/status", self.display_status)
        app.router.add_get(prefix+"/published", self.list_published)
        app.router.add_get(prefix+"/published/{id}", self.get_published)
        app.router.add_get(prefix+"/published/{id}/values", self.live_values)
        app.router.add_post(prefix+"/published/{id}/actions", self.action)
        app.router.add_get(prefix+"/published/{id}/camera/{component}", self.camera)
    async def display_status(self, request):
        return web.json_response({"serverID": self.runtime.server_id, "version": self.runtime.version, "protocolVersion": 1, "connected": self.runtime.ha.connected})
    async def list_documents(self, request):
        records = await self.call(self.store.read)
        return web.json_response({"dashboards": [dict(id=r["id"],title=r["document"]["title"],publishedRevision=r["publishedRevision"],updated=r["updated"]) for r in records]})
    async def get_document(self, request): return web.json_response(await self.call(self.store.read, request.match_info["id"]))
    async def save(self, request): return web.json_response(await self.call(self.store.change, request.match_info["id"], "save", await request.json()))
    async def change(self, request):
        data = await request.json()
        async with self.action_lock:
            return web.json_response(await self.call(self.store.change, request.match_info["id"], request.path.rsplit("/", 1)[1], data))
    async def revisions(self, request):
        entries = await self.call(self.store.history, request.match_info["id"])
        return web.json_response({"revisions": [dict(revision=r["revision"],title=r["document"]["title"],created=r["created"]) for r in entries]})
    async def preview(self, request):
        document = await self.call(validate, await request.json())
        await self.refresh_areas(document)
        values = self.values(document)
        cameras = [c for p in document["pages"] for c in p["components"] if c["kind"] == "camera"][:4]
        # Preview sends image bytes through the authenticated Mac API. No HA credential reaches HTML.
        async def snapshot(c):
            if not values[c["id"]]["known"]: return
            try:
                data, mime = await self.camera_image(c["binding"]["entityID"])
                values[c["id"]]["image"] = "data:" + mime + ";base64," + base64.b64encode(data).decode()
            except (DashboardError, ClientError, TimeoutError):
                values[c["id"]].update(known=False, reason="Kamerabild nicht verfügbar")
        await asyncio.gather(*(snapshot(c) for c in cameras))
        return web.json_response({"values": values, "connected": self.runtime.ha.connected})
    async def list_published(self, request):
        records = await self.call(self.store.read); items = []
        for record in records:
            if record["publishedRevision"]:
                published = await self.call(self.store.published, record["id"])
                items.append(dict(id=record["id"], title=published["document"]["title"], pages=len(published["document"]["pages"])))
        return web.json_response({"dashboards": items})
    async def get_published(self, request): return web.json_response(await self.call(self.store.published, request.match_info["id"]))
    async def live_values(self, request):
        published = await self.call(self.store.published, request.match_info["id"])
        await self.refresh_areas(published["document"])
        return web.json_response({"revision": published["revision"], "values": self.values(published["document"]), "connected": self.runtime.ha.connected})
    async def refresh_areas(self, document):
        if not any(c["binding"].get("areaID") for p in document["pages"] for c in p["components"]): return
        if not hasattr(self, "area_lock"):
            self.area_lock = asyncio.Lock(); self.area_members = {}; self.area_at = 0
        async with self.area_lock:
            if not self.runtime.ha.connected: self.area_members = {}; self.area_at = 0; return
            if time.monotonic()-self.area_at < 10: return
            self.area_at = time.monotonic()
            try: self.area_members = await self.runtime.ha.area_lights()
            except Exception: self.area_members = {}

    def values(self, document):
        result = {}
        for page in document["pages"]:
            for c in page["components"]:
                b = c["binding"]; value = None; extra = {}; reason = "Wert nicht verfügbar"
                if not self.runtime.ha.connected: reason = "Home Assistant nicht verbunden"
                elif b.get("areaID"):
                    members = getattr(self, "area_members", {}).get(b["areaID"], [])
                    states = [self.runtime.ha.states.get(entity) for entity in members]
                    if members and all(state in ("on", "off") for state in states): value = "on" if "on" in states else "off"
                    else: reason = "Bereich leer oder Leuchten nicht verfügbar"
                elif b["source"] == "entity" and b["attribute"] in ("access_token", "entity_picture", "token", "password"):
                    reason = "Geschütztes Attribut"
                elif b["source"] == "entity":
                    state = self.runtime.ha.states.get(b["entityID"])
                    if state not in (None, "unknown", "unavailable"):
                        value = self.runtime.ha.states.get(b["entityID"] + ("#"+b["attribute"] if b["attribute"] else ""))
                        if c["kind"] == "weather":
                            for attribute in ("temperature", "humidity", "wind_speed"):
                                candidate = self.runtime.ha.states.get(b["entityID"]+"#"+attribute)
                                try:
                                    numeric = float(candidate) if type(candidate) in (int, float, str) else float("nan")
                                    if math.isfinite(numeric): extra[attribute] = numeric
                                except (ValueError, OverflowError): pass
                            for attribute in ("temperature_unit", "wind_speed_unit"):
                                candidate = self.runtime.ha.states.get(b["entityID"]+"#"+attribute)
                                if isinstance(candidate, str) and len(candidate) <= 16: extra[attribute] = candidate
                        if c["kind"] == "climate":
                            for source, target in (("current_temperature", "temperature"), ("temperature", "targetTemperature"), ("min_temp", "minTemperature"), ("max_temp", "maxTemperature"), ("target_temp_step", "temperatureStep")):
                                candidate = self.runtime.ha.states.get(b["entityID"]+"#"+source)
                                try:
                                    numeric = float(candidate) if type(candidate) in (int, float, str) else float("nan")
                                    if math.isfinite(numeric): extra[target] = numeric
                                except (ValueError, OverflowError): pass
                        brightness = self.runtime.ha.states.get(b["entityID"]+"#brightness")
                        if brightness is not None:
                            try: extra["brightness"] = max(1, min(100, round(float(brightness)/255*100)))
                            except (ValueError, OverflowError): pass
                    elif state == "unknown": reason = "Zustand unbekannt"
                    elif state == "unavailable": reason = "Entität nicht verfügbar"
                    else: reason = "Entität nicht gefunden"
                else:
                    snapshot = next((v for k, v in self.runtime.snapshots.items() if k.lower() == b["programID"].lower()), None)
                    if any(k.lower() == b["programID"].lower() for k in self.runtime.running) and snapshot and time.time()-snapshot.get("observedAt", 0) <= 3:
                        field = {"signal":"signals", "number":"analogSignals", "remaining":"remaining"}.get(b["metric"], "signals")
                        value = next((v for k, v in snapshot.get(field, {}).items() if k.lower() == b["blockID"].lower()), None)
                    else: reason = "Automation nicht aktiv oder Wert veraltet"
                linked = c.get("brightnessBinding")
                if linked:
                    extra["linkedBrightness"] = self.linked_brightness(linked)
                if isinstance(value, float) and not math.isfinite(value): value = None
                known = value is not None and value not in ("unknown", "unavailable")
                result[c["id"]] = dict(known=known, value=value if known else None, observedAt=time.time(), reason="" if known else reason, **extra)
        return result
    def linked_brightness(self, binding):
        program, block = binding["programID"].lower(), binding["blockID"].lower()
        snapshot = next((v for k, v in self.runtime.snapshots.items() if k.lower() == program), None)
        if not self.runtime.ha.connected or not any(k.lower() == program for k in self.runtime.running) or not snapshot or time.time()-snapshot.get("observedAt", 0) > 3: return None
        value = next((v for k, v in snapshot.get("analogSignals", {}).items() if k.lower() == block), None)
        return round(value) if type(value) in (int, float) and math.isfinite(value) and 1 <= value <= 100 else None

    def camera_url(self, entity, stream=False):
        require(isinstance(entity, str) and ENTITY.fullmatch(entity) and entity.startswith("camera."))
        base = self.runtime.ha.base.rstrip("/")
        if not base.endswith("/api"): base += "/api"
        return base + ("/camera_proxy_stream/" if stream else "/camera_proxy/") + entity
    async def camera_image(self, entity):
        require(self.runtime.ha.connected and self.runtime.ha.session is not None, "Kamera nicht verbunden.", 503)
        require(self.camera_count < 4, "Maximal vier gleichzeitige Kamerabilder.", 429)
        self.camera_count += 1
        try:
            async with self.runtime.ha.session.get(self.camera_url(entity), params={"width": 960}, headers={"Authorization": "Bearer " + self.runtime.ha.token}, allow_redirects=False, timeout=ClientTimeout(total=6)) as upstream:
                require(upstream.status == 200 and upstream.content_type in ("image/jpeg", "image/png"), "Kamerabild nicht verfügbar.", 502)
                data = bytearray()
                async for chunk in upstream.content.iter_chunked(65536):
                    data.extend(chunk); require(len(data) <= 1024*1024, "Kamerabild zu groß.", 502)
                return bytes(data), upstream.content_type
        finally: self.camera_count -= 1
    async def camera(self, request):
        published = await self.call(self.store.published, request.match_info["id"])
        require(request.query.get("revision") == published["revision"], "Dashboard wurde geändert.", 409)
        c = next((c for p in published["document"]["pages"] for c in p["components"] if c["id"] == request.match_info["component"]), None)
        require(c is not None and c["kind"] == "camera", "Kamera nicht gefunden.", 404)
        headers = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"}
        if c.get("cameraMode") == "snapshots":
            data, mime = await self.camera_image(c["binding"]["entityID"])
            return web.Response(body=data, content_type=mime, headers=headers)
        require(self.runtime.ha.connected and self.runtime.ha.session is not None, "Kamera nicht verbunden.", 503)
        require(self.camera_count < 4, "Maximal vier gleichzeitige Kameras.", 429)
        self.camera_count += 1
        response = None
        try:
            # Renew every 45 seconds to recheck HA identity and publication; close on disconnect.
            async with self.runtime.ha.session.get(self.camera_url(c["binding"]["entityID"], True), headers={"Authorization": "Bearer " + self.runtime.ha.token}, allow_redirects=False, timeout=ClientTimeout(total=45, sock_read=12)) as upstream:
                require(upstream.status == 200 and upstream.content_type == "multipart/x-mixed-replace", "Dieser Kamerastream ist nicht verfügbar. Versuche den Einzelbild-Modus.", 502)
                headers["Content-Type"] = upstream.headers["Content-Type"]
                response = web.StreamResponse(headers=headers); await response.prepare(request)
                checked = time.monotonic()
                async for chunk in upstream.content.iter_chunked(65536):
                    if time.monotonic() - checked > 2:
                        current = await self.call(self.store.published, published["id"])
                        if current["revision"] != published["revision"]: break
                        checked = time.monotonic()
                    await response.write(chunk)
        except (ClientError, TimeoutError, ConnectionError, DashboardError):
            if response is None: raise DashboardError(502, "Kamerastream nicht verfügbar.")
        finally: self.camera_count -= 1
        if response is not None:
            try: await response.write_eof()
            except ConnectionError: pass
        return response
    async def action(self, request):
        data = await request.json(); require(isinstance(data, dict)); request_id = identifier(data.get("requestID"))
        async with self.action_lock:
            published = await self.call(self.store.published, request.match_info["id"])
            require(data.get("revision") == published["revision"], "Dashboard wurde geändert. Bitte neu laden.", 409)
            c = next((c for p in published["document"]["pages"] for c in p["components"] if c["id"] == data.get("componentID")), None)
            require(c is not None and c["kind"] in ("light", "switch", "scene", "climate"), "Diese Komponente kann nicht schalten.", 403)
            await self.refresh_areas(published["document"])
            current = self.values(published["document"])[c["id"]]
            if c["kind"] == "climate":
                temperature = data.get("temperature")
                low, high = current.get("minTemperature"), current.get("maxTemperature")
                require(type(temperature) in (int, float) and math.isfinite(temperature) and low is not None and high is not None and low <= temperature <= high, "Temperatur liegt außerhalb der Gerätegrenzen.")
                require("on" not in data and "brightness" not in data)
            else:
                require(type(data.get("on")) is bool)
                require(c["kind"] != "scene" or data["on"], "Eine Szene kann nur aktiviert werden.")
                require("temperature" not in data)
            require("brightness" not in data or (c["kind"] == "light" and number(data["brightness"], 1, 100) and data["on"]))
            require(self.values(published["document"])[c["id"]]["known"], "Kein aktueller Gerätezustand. Bitte Verbindung prüfen.", 409)
            digest = hashlib.sha256(canonical([published["id"], data]).encode()).hexdigest()
            # Claim before sending; a repeated request, even after a crash, never calls HA again.
            now = time.monotonic()
            while self.recent and now-self.recent[0] > 1: self.recent.popleft()
            require(len(self.recent) < 5, "Zu viele Bedienaktionen. Bitte kurz warten.", 429)
            previous = await self.call(self.store.action_claim, request_id, digest)
            if previous: return web.json_response(previous)
            self.recent.append(now)
            if c.get("brightnessBinding") and data.get("on"):
                linked = self.linked_brightness(c["brightnessBinding"])
                if linked is None:
                    result = {"status":"unconfirmed", "message":"Verknüpfter Helligkeitswert fehlt oder ist veraltet. Kein Aufruf gesendet."}
                    await self.call(self.store.action_finish, request_id, result)
                    return web.json_response(result)
                data = dict(data, brightness=linked)
            entity = c["binding"]["entityID"]; domain = "light" if c["binding"].get("areaID") else entity.split(".")[0]
            target = {"area_id": c["binding"]["areaID"]} if c["binding"].get("areaID") else {"entity_id": entity}
            if c["kind"] == "climate":
                configuration = {"action": "climate.set_temperature", "target": target, "data": {"temperature": data["temperature"]}}
            else:
                configuration = {"action": domain + (".turn_on" if data["on"] else ".turn_off"), "target": target, "data": {"brightness_pct": data["brightness"]} if "brightness" in data else {}}
            try:
                await self.runtime.ha.action(configuration)
                result = {"status":"confirmed", "message":"Von Home Assistant bestätigt · Gerätezustand separat angezeigt."}
            except Exception:
                result = {"status":"unconfirmed", "message":"Aufruf nicht bestätigt. Gerätezustand prüfen; keine automatische Wiederholung."}
            await self.call(self.store.action_finish, request_id, result)
            return web.json_response(result)
