"""Nodivra Runtime transport. Block semantics live in the shared Swift engine."""
from __future__ import annotations
import asyncio
import contextlib
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import sqlite3
import time
import uuid
from collections import deque
from aiohttp import web, ClientSession, ClientTimeout, WSMsgType

VERSION = "0.6.0"

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)

def problem(status, message):
    return web.Response(status=status, text=canonical({"error": message}), content_type="application/json")

class Engine:
    def __init__(self, executable):
        self.executable = executable
        self.process = None
        self.lock = asyncio.Lock()

    async def start(self):
        self.process = await asyncio.create_subprocess_exec(self.executable, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, limit=4 * 1024 * 1024)

    async def call(self, **request):
        async with self.lock:
            if not self.process or self.process.returncode is not None:
                raise RuntimeError("Die Ausführungsengine ist nicht verfügbar.")
            try:
                async def exchange():
                    self.process.stdin.write((canonical(request) + "\n").encode())
                    await self.process.stdin.drain()
                    result = json.loads(await self.process.stdout.readline())
                    if "error" in result:
                        raise ValueError(result["error"])
                    return result
                return await asyncio.wait_for(exchange(), timeout=5)
            except (asyncio.TimeoutError, json.JSONDecodeError, BrokenPipeError, ConnectionError) as error:
                await self.close()
                raise RuntimeError("Die Ausführungsengine antwortet nicht. Ausführung angehalten.") from error

    async def close(self):
        if self.process and self.process.returncode is None:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), 3)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()

class HomeAssistant:
    def __init__(self, base, token, on_disconnect):
        self.base, self.token = base.rstrip("/"), token
        self.on_disconnect = on_disconnect
        self.states = {}
        self.sequence = 0
        self.history = deque(maxlen=2000)
        self.connected = False
        self.services = {}
        self.version = ""
        self.ws = None
        self.waiting = {}
        self.serial = 10
        self.session = None
        self.task = None

    async def start(self):
        self.session = ClientSession(timeout=ClientTimeout(total=10))
        self.task = asyncio.create_task(self.listen())

    async def close(self):
        if self.task:
            self.task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.task
        if self.session:
            await self.session.close()

    async def listen(self):
        url = self.base.replace("http://", "ws://", 1).replace("https://", "wss://", 1) + "/websocket"
        while True:
            try:
                async with self.session.ws_connect(url, heartbeat=20, max_msg_size=16 * 1024 * 1024) as ws:
                    self.ws = ws
                    if (await ws.receive_json(timeout=10)).get("type") != "auth_required":
                        raise RuntimeError("HA-Authentifizierung nicht verfügbar")
                    await ws.send_json({"type": "auth", "access_token": self.token})
                    authenticated = await ws.receive_json(timeout=10)
                    self.version = authenticated.get("ha_version", "")
                    if authenticated.get("type") != "auth_ok":
                        raise RuntimeError("HA-Authentifizierung fehlgeschlagen")
                    # Subscribe before requesting the snapshot: no lost state changes.
                    await ws.send_json({"id": 1, "type": "subscribe_events", "event_type": "state_changed"})
                    await ws.send_json({"id": 2, "type": "get_states"})
                    await ws.send_json({"id": 3, "type": "get_services"})
                    subscribed = snapshot = services = False
                    buffered = []
                    async for msg in ws:
                        if msg.type != WSMsgType.TEXT:
                            break
                        data = json.loads(msg.data)
                        if data.get("type") == "result":
                            identity = data.get("id")
                            if identity in (1, 2, 3):
                                if not data.get("success"):
                                    raise RuntimeError("Home-Assistant-Abgleich fehlgeschlagen")
                                if identity == 1:
                                    subscribed = True
                                elif identity == 2:
                                    self.states = {}
                                    for state in data["result"]:
                                        self.states.update(self.flatten_state(state))
                                    for event in buffered:
                                        self.apply_state(event)
                                    buffered.clear()
                                    snapshot = True
                                else:
                                    self.services = data["result"]
                                    services = True
                                self.connected = subscribed and snapshot and services
                            else:
                                future = self.waiting.pop(identity, None)
                                if future and not future.done():
                                    future.set_result(data)
                        elif data.get("type") == "event":
                            event = data.get("event", {}).get("data", {})
                            if snapshot:
                                self.apply_state(event)
                            elif len(buffered) < 10000:
                                buffered.append(event)
                            else:
                                raise RuntimeError("Zu viele Zustandsänderungen beim Abgleich")
            except asyncio.CancelledError:
                raise
            except Exception:
                pass  # No raw response/URL/token in logs.
            finally:
                was_connected = self.connected
                self.connected = False
                self.ws = None
                self.states = {}
                for future in self.waiting.values():
                    if not future.done():
                        future.set_exception(RuntimeError("Home-Assistant-Verbindung unterbrochen"))
                self.waiting.clear()
                if was_connected:
                    await self.on_disconnect()
            await asyncio.sleep(5)

    @staticmethod
    def flatten_state(state):
        if not state:
            return {}
        entity, value = state["entity_id"], state["state"]
        result = {entity: value}
        if value not in ("unknown", "unavailable"):
            for name, attribute in state.get("attributes", {}).items():
                if isinstance(attribute, (str, int, float)) and not isinstance(attribute, bool):
                    result[entity + "#" + name] = str(attribute)
        return result

    def apply_state(self, event):
        entity = event.get("entity_id")
        if not entity:
            return
        state = event.get("new_state")
        current = self.flatten_state(dict(state, entity_id=entity)) if state else {}
        keys = {key for key in self.states if key == entity or key.startswith(entity + "#")} | set(current)
        # Atomic update: a PLC scan receives the complete process image.
        for key in sorted(keys):
            value = current.get(key)
            if self.states.get(key) != value:
                self.sequence += 1
                self.history.append((self.sequence, key, value))
            if value is None:
                self.states.pop(key, None)
            else:
                self.states[key] = value

    async def is_admin(self, user_id):
        if not user_id or not self.connected or not self.ws:
            return False
        self.serial += 1
        identity = self.serial
        future = asyncio.get_running_loop().create_future()
        self.waiting[identity] = future
        try:
            await self.ws.send_json({"id": identity, "type": "config/auth/list"})
            response = await asyncio.wait_for(future, 5)
            return response.get("success") is True and any(
                user.get("id") == user_id and user.get("is_active") is True and
                (user.get("is_owner") is True or "system-admin" in user.get("group_ids", []))
                for user in (response.get("result") or []))
        except Exception:
            return False
        finally:
            self.waiting.pop(identity, None)

    def supports(self, action):
        domain, service = action.split(".", 1)
        return service in self.services.get(domain, {})

    async def action(self, configuration):
        if not self.connected or not self.ws:
            raise RuntimeError("Home Assistant ist nicht verbunden")
        action = configuration.get("action", configuration.get("service", ""))
        if not self.supports(action):
            raise RuntimeError("Diese Aktion ist in Home Assistant nicht verfügbar")
        domain, service = action.split(".", 1)
        self.serial += 1
        identity = self.serial
        future = asyncio.get_running_loop().create_future()
        self.waiting[identity] = future
        try:
            request = {"id": identity, "type": "call_service", "domain": domain, "service": service, "service_data": configuration.get("data", {})}
            if "target" in configuration:
                request["target"] = configuration["target"]
            await self.ws.send_json(request)
            result = await asyncio.wait_for(future, 8)
            if not result.get("success"):
                raise RuntimeError("Home Assistant hat die Aktion abgelehnt")
        finally:
            self.waiting.pop(identity, None)

class Runtime:
    def __init__(self, path, key, engine_path, ha_base, ha_token):
        self.key = key if isinstance(key, str) and len(key) >= 32 else ""
        self.backup_path = Path(path) / "backups"
        path = Path(path)
        path.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path / "runtime.sqlite")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        # Additive migration: 0.5 can still open the original tables on rollback.
        tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "programs" in tables and "program_metadata" not in tables:
            self.backup()
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS programs(id TEXT PRIMARY KEY, revision TEXT NOT NULL, package TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, mode TEXT NOT NULL DEFAULT 'observe', error TEXT, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS revisions(id TEXT, revision TEXT, package TEXT, created REAL, PRIMARY KEY(id,revision));
        CREATE TABLE IF NOT EXISTS transfers(request_id TEXT PRIMARY KEY, digest TEXT, response TEXT);
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, automation_id TEXT, block_id TEXT, kind TEXT NOT NULL, message TEXT NOT NULL, created REAL NOT NULL);
        """)
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS program_metadata(id TEXT PRIMARY KEY, created REAL, last_started REAL, last_executed REAL, last_observed REAL, control_version INTEGER NOT NULL DEFAULT 0);
        INSERT OR IGNORE INTO program_metadata(id,last_started,last_executed,last_observed)
          SELECT p.id,
            (SELECT MAX(created) FROM events WHERE automation_id=p.id AND kind='started'),
            (SELECT MAX(created) FROM events WHERE automation_id=p.id AND kind='action'),
            (SELECT MAX(created) FROM events WHERE automation_id=p.id AND kind='observe')
          FROM programs p;
        UPDATE program_metadata SET control_version=control_version+1 WHERE id IN (SELECT id FROM programs WHERE enabled=1);
        """)
        if not self.db.execute("SELECT value FROM meta WHERE key='serverID'").fetchone():
            self.db.execute("INSERT INTO meta VALUES ('serverID',?)", (str(uuid.uuid4()),))
        self.server_id = self.db.execute("SELECT value FROM meta WHERE key='serverID'").fetchone()[0]
        self.db.execute("UPDATE programs SET enabled=0,error='Runtime neu gestartet. Bitte mit aktuellen Zuständen erneut aktivieren.' WHERE enabled=1")
        self.db.commit()
        self.engine = Engine(engine_path)
        self.ha = HomeAssistant(ha_base, ha_token, self.disconnected)
        self.locks = {}
        self.mutation = asyncio.Lock()
        self.started = time.time()
        self.closing = False
        self.cursors = {}
        self.input_states = {}
        self.virtual_values = {}
        self.inputs = {}
        self.running = {}
        self.snapshots = {}
        self.tasks = {}
        self.actions = deque()
        self.ticker = None

    def lock(self, identity):
        return self.locks.setdefault(identity, asyncio.Lock())

    def record(self, identity):
        row = self.db.execute("SELECT id,revision,package,enabled,mode,error,updated FROM programs WHERE id=?", (identity,)).fetchone()
        if not row:
            return None
        return dict(id=row[0], revision=row[1], package=json.loads(row[2]), enabled=bool(row[3]), mode=row[4], error=row[5], updated=row[6]) | self.metadata(identity)

    def records(self):
        return [self.record(r[0]) for r in self.db.execute("SELECT id FROM programs ORDER BY updated DESC").fetchall()]

    def metadata(self, identity):
        row = self.db.execute("SELECT created,last_started,last_executed,last_observed,control_version FROM program_metadata WHERE id=?", (identity,)).fetchone()
        return dict(created=row[0], lastStarted=row[1], lastExecuted=row[2], lastObserved=row[3], stateVersion=row[4]) if row else {}

    def dashboard(self):
        records = self.records()
        return {"version": VERSION, "protocolVersion": 5, "serverID": self.server_id,
                "homeAssistantVersion": self.ha.version, "homeAssistantConnected": self.ha.connected,
                "startedAt": self.started, "restartPolicy": "pause", "observedAt": time.time(),
                "engineReady": self.engine.process is not None and self.engine.process.returncode is None,
                "automations": [{k: v for k, v in record.items() if k != "package"} |
                                {"title": record["package"]["graph"]["title"],
                                 "blocks": len(record["package"]["graph"]["blocks"])} for record in records]}

    def event(self, identity, kind, message, block=None):
        now = time.time()
        self.db.execute("INSERT INTO events(automation_id,block_id,kind,message,created) VALUES(?,?,?,?,?)", (identity, block, kind, message[:2000], now))
        column = {"started": "last_started", "action": "last_executed", "observe": "last_observed"}.get(kind)
        if kind == "log":
            row = self.db.execute("SELECT mode FROM programs WHERE id=?", (identity,)).fetchone()
            column = "last_observed" if row and row[0] == "observe" else "last_executed"
        if column:
            self.db.execute("UPDATE program_metadata SET " + column + "=? WHERE id=?", (now, identity))
        self.db.execute("DELETE FROM events WHERE id <= (SELECT MAX(id)-1000 FROM events)")
        self.db.commit()

    def backup(self):
        self.backup_path.mkdir(exist_ok=True)
        destination = self.backup_path / (str(time.time_ns()) + ".sqlite")
        with sqlite3.connect(destination) as backup:
            self.db.backup(backup)
        for old in sorted(self.backup_path.glob("*.sqlite"))[:-10]:
            old.unlink()

    async def start(self, app):
        await self.engine.start()
        await self.ha.start()
        self.ticker = asyncio.create_task(self.tick())

    async def close(self, app):
        self.closing = True
        if self.ticker:
            self.ticker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.ticker
        await self.ha.close()
        for task in self.tasks.values():
            task.cancel()
        await asyncio.gather(*self.tasks.values(), return_exceptions=True)
        await self.engine.close()
        self.db.close()

    async def pause(self, identity, message):
        self.running.pop(identity, None)
        self.virtual_values.pop(identity, None)
        self.snapshots.pop(identity, None)
        self.db.execute("UPDATE programs SET enabled=0,error=? WHERE id=?", (message, identity))
        self.db.execute("UPDATE program_metadata SET control_version=control_version+1 WHERE id=?", (identity,))
        self.db.commit()
        with contextlib.suppress(Exception):
            await self.engine.call(op="drop", id=identity)
        self.event(identity, "paused", message)

    async def disconnected(self):
        if self.closing:
            return
        for identity in list(self.running):
            if self.record(identity)["package"].get("protocolVersion", 1) >= 2 and not any(not key.startswith("nodivra_input.") for key in self.inputs.get(identity, [])) and not (await self.validate(self.record(identity)["package"]))["deviceActions"]:
                continue
            # Do not wait on an action while the WebSocket receive loop is closing.
            asyncio.create_task(self.pause_locked(identity, "Home Assistant getrennt. Nach dem Abgleich erneut aktivieren."))

    async def pause_locked(self, identity, message):
        async with self.lock(identity):
            if identity in self.running:
                await self.pause(identity, message)

    async def tick(self):
        while True:
            for identity in list(self.running):
                if identity not in self.tasks or self.tasks[identity].done():
                    self.tasks[identity] = asyncio.create_task(self.step(identity))
            await asyncio.sleep(0.1)

    async def step(self, identity):
        async with self.lock(identity):
            start = self.running.get(identity)
            if start is None:
                return
            try:
                record = self.record(identity)
                cursor = self.cursors[identity]
                if self.ha.history and cursor < self.ha.history[0][0] - 1:
                    await self.pause(identity, "Zu viele Eingangsänderungen. Ereignispuffer voll; bitte erneut aktivieren.")
                    return
                relevant = [event for event in self.ha.history if event[0] > cursor and event[1] in self.inputs[identity]]
                self.cursors[identity] = self.ha.sequence
                if len(relevant) > 100:
                    await self.pause(identity, "Zu viele Eingangsänderungen in einem Ausführungsschritt.")
                    return
                frames = []
                for _, entity, value in relevant:
                    if value is None:
                        self.input_states[identity].pop(entity, None)
                    else:
                        self.input_states[identity][entity] = value
                    frames.append(dict(self.input_states[identity]))
                if not frames:
                    frames.append(self.input_states[identity])
                if record["package"].get("protocolVersion", 1) >= 2:
                    frames = [dict(self.ha.states) | self.virtual_values.get(identity, {})]
                for states in frames:
                    result = await self.engine.call(op="step", id=identity, now=time.monotonic()-start, date=time.time(), states=states)
                    self.snapshots[identity] = result | {"observedAt": time.time()}
                    if result.get("fault"):
                        await self.pause(identity, result["fault"])
                        return
                    await self.perform_commands(identity, record, result)
                    if identity not in self.running:
                        return
            except asyncio.CancelledError:
                raise
            except Exception:
                await self.pause(identity, "Ausführungsfehler. Automation pausiert; keine automatische Wiederholung.")

    async def perform_commands(self, identity, record, result):
        for command in result["commands"]:
            now = time.monotonic()
            while self.actions and now-self.actions[0] >= 60:
                self.actions.popleft()
            if len(self.actions) >= 120:
                await self.pause(identity, "Globale Schutzgrenze: höchstens 120 Aktionen pro Minute.")
                return
            self.actions.append(now)
            config = command["configuration"]
            action = config.get("action", config.get("service", ""))
            if action == "nodivra.log":
                self.event(identity, "log", config["data"]["message"], command["blockID"])
            elif record["mode"] == "observe":
                self.event(identity, "observe", "Würde ausführen: " + action, command["blockID"])
            else:
                try:
                    await self.ha.action(config)
                except Exception:
                    await self.engine.call(op="ack", id=identity, commandID=command["id"], success=False)
                    await self.pause(identity, "Aktion abgelehnt oder Ausgang unbekannt. Keine Wiederholung. Bitte Gerät und Verbindung prüfen.")
                    return
                self.event(identity, "action", "Home Assistant bestätigt: " + action, command["blockID"])
            await self.engine.call(op="ack", id=identity, commandID=command["id"], success=True)

    async def validate(self, package):
        result = await self.engine.call(op="validate", package=package)
        return result | {"valid": not result["issues"]}

    def app(self):
        @web.middleware
        async def boundary(request, handler):
            if request.path != "/health":
                supplied = request.headers.get("Authorization", "")
                if len(self.key) < 32 or not hmac.compare_digest(supplied.encode(), ("Bearer " + self.key).encode()):
                    return problem(401, "Runtime-Zugangsschlüssel fehlt oder ist ungültig.")
                if request.headers.get("Origin"):
                    return problem(403, "Browser-Zugriffe auf die Runtime-API sind nicht zugelassen.")
            try:
                return await handler(request)
            except web.HTTPException as error:
                return problem(error.status, "Anfrage konnte nicht verarbeitet werden.")
            except (ValueError, TypeError, KeyError):
                return problem(422, "Ungültige Anfrage oder ungültiges Programm.")
            except Exception:
                return problem(503, "Runtime vorübergehend nicht verfügbar. Schreibstatus vor einer Wiederholung prüfen.")
        app = web.Application(middlewares=[boundary], client_max_size=1024*1024)
        app.router.add_get("/health", self.health)
        app.router.add_get("/api/v1/status", self.status)
        app.router.add_get("/api/v1/automations", self.list_programs)
        app.router.add_post("/api/v1/validate", self.check)
        app.router.add_put("/api/v1/automations/{id}", self.transfer)
        app.router.add_get("/api/v1/automations/{id}", self.get_program)
        app.router.add_post("/api/v1/automations/{id}/state", self.set_state)
        app.router.add_get("/api/v1/automations/{id}/revisions", self.revisions)
        app.router.add_get("/api/v1/automations/{id}/inputs", self.get_inputs)
        app.router.add_post("/api/v1/automations/{id}/inputs/{block}", self.set_input)
        app.router.add_get("/api/v1/events", self.events)
        app.router.add_get("/api/v1/live/{id}", self.live)
        app.on_startup.append(self.start)
        app.on_cleanup.append(self.close)
        return app

    async def health(self, request):
        ready = self.engine.process is not None and self.engine.process.returncode is None
        return web.json_response({"service": "nodivra-runtime", "version": VERSION}, status=200 if ready else 503)

    async def status(self, request):
        return web.json_response({"version": VERSION, "protocolVersion": 5, "serverID": self.server_id, "homeAssistantConnected": self.ha.connected, "automations": len(self.records()), "running": len(self.running), "startedAt": self.started, "restartPolicy": "pause", "engineReady": self.engine.process is not None and self.engine.process.returncode is None})

    async def list_programs(self, request):
        return web.json_response({"automations": self.records()})

    async def get_program(self, request):
        record = self.record(request.match_info["id"])
        return web.json_response(record) if record else problem(404, "Automation nicht gefunden.")

    async def check(self, request):
        return web.json_response(await self.validate(await request.json()))

    async def transfer(self, request):
        identity = str(uuid.UUID(request.match_info["id"]))
        data = await request.json()
        package = data["package"]
        if str(uuid.UUID(package["graph"]["id"])) != identity:
            return problem(422, "Programmkennung stimmt nicht überein.")
        request_id = str(uuid.UUID(data["requestID"]))
        digest = hashlib.sha256(canonical(data).encode()).hexdigest()
        async with self.mutation, self.lock(identity):
            previous = self.db.execute("SELECT digest,response FROM transfers WHERE request_id=?", (request_id,)).fetchone()
            if previous:
                return web.json_response(json.loads(previous[1])) if previous[0] == digest else problem(409, "Anfragekennung wurde für andere Daten verwendet.")
            check = await self.validate(package)
            if not check["valid"]:
                return web.json_response(check, status=422)
            old = self.record(identity)
            if (old and old["revision"] != data.get("expectedRevision")) or (not old and data.get("expectedRevision") is not None):
                return problem(409, "Die Serverfassung wurde geändert. Zuerst neu laden und vergleichen.")
            if not old and len(self.records()) >= 100:
                return problem(409, "Die Runtime unterstützt höchstens 100 Programme.")
            text = canonical(package)
            revision = hashlib.sha256(text.encode()).hexdigest()
            self.backup()
            # The per-program lock waits for outstanding service acknowledgement.
            self.running.pop(identity, None)
            self.snapshots.pop(identity, None)
            await self.engine.call(op="drop", id=identity)
            with self.db:
                self.db.execute("INSERT OR REPLACE INTO revisions VALUES(?,?,?,?)", (identity, revision, text, time.time()))
                self.db.execute("INSERT OR REPLACE INTO programs VALUES(?,?,?,0,'observe',NULL,?)", (identity, revision, text, time.time()))
                self.db.execute("INSERT INTO program_metadata(id,created) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET control_version=control_version+1", (identity, time.time()))
                result = self.record(identity)
                self.db.execute("INSERT INTO transfers VALUES(?,?,?)", (request_id, digest, canonical(result)))
                # Bound historical storage while retaining the newest ten revisions per program.
                self.db.execute("DELETE FROM revisions WHERE id=? AND revision NOT IN (SELECT revision FROM revisions WHERE id=? ORDER BY created DESC LIMIT 10)", (identity, identity))
                self.db.execute("DELETE FROM transfers WHERE rowid NOT IN (SELECT rowid FROM transfers ORDER BY rowid DESC LIMIT 1000)")
            self.event(identity, "transfer", "Programm geprüft und deaktiviert gespeichert. Vorherige Fassungen bleiben gesichert.")
            return web.json_response(result)

    async def set_state(self, request):
        identity = request.match_info["id"]
        data = await request.json()
        return await self.change_state(identity, data)

    async def change_state(self, identity, data):
        if not isinstance(data, dict) or type(data.get("enabled")) is not bool or data.get("mode", "observe") not in ("observe", "execute"):
            return problem(422, "Ungültiger Ausführungsmodus.")
        async with self.lock(identity):
            record = self.record(identity)
            if not record:
                return problem(404, "Automation nicht gefunden.")
            if record["revision"] != data.get("expectedRevision"):
                return problem(409, "Die Serverfassung stimmt nicht mit der Vorschau überein.")
            if "expectedStateVersion" in data and (type(data["expectedStateVersion"]) is not int or data["expectedStateVersion"] != record["stateVersion"]):
                return problem(409, "Der Ausführungsstatus wurde geändert. Bitte neu laden und erneut auswählen.")
            if not data["enabled"]:
                if record["enabled"]:
                    await self.pause(identity, "Vom Nutzer pausiert.")
            else:
                mode = data.get("mode", "observe")
                if identity in self.running:
                    if record["mode"] != mode:
                        return problem(409, "Vor einem Moduswechsel zuerst pausieren.")
                    return web.json_response(record)
                check = await self.validate(record["package"])
                if not check["valid"]:
                    return web.json_response(check, status=422)
                if (check["deviceActions"] or any(not e.startswith(("nodivra_button.", "nodivra_input.")) for e in check["inputs"])) and not self.ha.connected:
                    return problem(409, "Zuerst Home Assistant verbinden. Die Automation bleibt deaktiviert.")
                if any(e.startswith("nodivra_button.") for e in check["inputs"]):
                    return problem(422, "Virtuelle Taster sind vorerst nur in der lokalen Simulation bedienbar. Für die Runtime eine reale Eingabe wählen.")
                if mode == "execute":
                    for b in record["package"]["graph"]["blocks"]:
                        config = b.get("options", {}).get("configuration", {})
                        action = config.get("action", config.get("service"))
                        if action and action != "nodivra.log" and not self.ha.supports(action):
                            return problem(422, "Eine verwendete Aktion ist in Home Assistant nicht verfügbar.")
                virtual = {}
                for b in record["package"]["graph"]["blocks"]:
                    if b["kind"] in ("digitalInput", "analogInput") and not b.get("entityID"):
                        value = b.get("options", {}).get("initial", False if b["kind"] == "digitalInput" else 0)
                        virtual[self.input_key(b)] = ("on" if value else "off") if b["kind"] == "digitalInput" else str(value)
                self.virtual_values[identity] = virtual
                snapshot = await self.engine.call(op="load", id=identity, package=record["package"], states=dict(self.ha.states) | virtual, date=time.time())
                self.snapshots[identity] = snapshot | {"observedAt": time.time()}
                self.cursors[identity] = self.ha.sequence
                self.input_states[identity] = dict(self.ha.states)
                self.inputs[identity] = set(check["inputs"])
                self.running[identity] = time.monotonic()
                self.db.execute("UPDATE programs SET enabled=1,mode=?,error=NULL WHERE id=?", (mode, identity))
                self.db.execute("UPDATE program_metadata SET control_version=control_version+1 WHERE id=?", (identity,))
                self.db.commit()
                self.event(identity, "started", "Beobachten gestartet. Geräteaktionen werden nur protokolliert." if mode == "observe" else "Ausführung gestartet. Geräteaktionen sind freigegeben.")
            return web.json_response(self.record(identity))

    @staticmethod
    def input_key(block):
        return "nodivra_input." + str(uuid.UUID(block["id"])).replace("-", "")

    def input_response(self, identity):
        values = {}
        for block in self.record(identity)["package"]["graph"]["blocks"]:
            raw = self.virtual_values.get(identity, {}).get(self.input_key(block))
            if raw is not None:
                values[str(uuid.UUID(block["id"]))] = raw == "on" if block["kind"] == "digitalInput" else float(raw)
        return web.json_response({"values": values})

    async def get_inputs(self, request):
        identity = request.match_info["id"]
        async with self.lock(identity):
            if identity not in self.running:
                return problem(409, "Das Programm läuft nicht. Eingänge werden beim Aktivieren initialisiert.")
            return self.input_response(identity)

    async def set_input(self, request):
        identity = request.match_info["id"]
        block_id = str(uuid.UUID(request.match_info["block"]))
        data = await request.json()
        async with self.lock(identity):
            record = self.record(identity)
            if not record or identity not in self.running:
                return problem(409, "Das Programm läuft nicht.")
            if data.get("expectedRevision") != record["revision"]:
                return problem(409, "Die Serverfassung wurde geändert. Zuerst neu laden.")
            block = next((b for b in record["package"]["graph"]["blocks"] if str(uuid.UUID(b["id"])) == block_id), None)
            if not block or block["kind"] not in ("digitalInput", "analogInput") or block.get("entityID"):
                return problem(422, "Nur virtuelle Eingänge dieses Programms sind bedienbar.")
            value = data.get("value")
            if block["kind"] == "digitalInput":
                if type(value) is not bool:
                    return problem(422, "Der Eingang benötigt Ein oder Aus.")
                raw = "on" if value else "off"
            else:
                options = block.get("options", {})
                if type(value) not in (float, int) or not math.isfinite(value) or not options.get("minimum", 0) <= value <= options.get("maximum", 100):
                    return problem(422, "Der Zahlenwert liegt außerhalb des erlaubten Bereichs.")
                raw = str(value)
            self.virtual_values[identity][self.input_key(block)] = raw
            self.event(identity, "input", "Virtuellen Eingang geändert: " + block["title"], block["id"])
            return self.input_response(identity)

    async def revisions(self, request):
        rows = self.db.execute("SELECT revision,package,created FROM revisions WHERE id=? ORDER BY created DESC", (request.match_info["id"],)).fetchall()
        return web.json_response({"revisions": [dict(revision=r[0], package=json.loads(r[1]), created=r[2]) for r in rows]})

    async def events(self, request):
        rows = self.db.execute("SELECT id,automation_id,block_id,kind,message,created FROM events ORDER BY id DESC LIMIT 100").fetchall()
        return web.json_response({"events": [dict(id=r[0], automationID=r[1], blockID=r[2], kind=r[3], message=r[4], created=r[5]) for r in rows]})

    async def live(self, request):
        identity = request.match_info["id"]
        if identity not in self.running or identity not in self.snapshots:
            return problem(409, "Die Automation läuft gerade nicht.")
        if time.time() - self.snapshots[identity]["observedAt"] > 3:
            return problem(409, "Kein aktueller Ausführungsstand. Live-Anzeige vorübergehend ausgesetzt.")
        return web.json_response(self.snapshots[identity] | {"revision": self.record(identity)["revision"]})

def main():
    path = os.environ.get("NODIVRA_DATA", "/data")
    options_path = Path(path) / "options.json"
    options = json.loads(options_path.read_text()) if options_path.exists() else {}
    key = options.get("access_key", os.environ.get("NODIVRA_ACCESS_KEY", ""))
    runtime = Runtime(path, key, os.environ.get("NODIVRA_ENGINE", "/usr/local/bin/NodivraEngine"), os.environ.get("NODIVRA_HA_BASE", "http://supervisor/core/api"), os.environ.get("SUPERVISOR_TOKEN", os.environ.get("NODIVRA_HA_TOKEN", "")))
    # Supervisor's WebSocket proxy is adjacent to /api, not inside it.
    if runtime.ha.base == "http://supervisor/core/api":
        runtime.ha.base = "http://supervisor/core"
    app = runtime.app()
    if os.environ.get("SUPERVISOR_TOKEN"):
        from configuration import RuntimeConfiguration
        configuration = RuntimeConfiguration(runtime, os.environ["SUPERVISOR_TOKEN"])
        async def ingress(app):
            runner = web.AppRunner(configuration.app(), access_log=None)
            await runner.setup()
            try:
                await web.TCPSite(runner, "0.0.0.0", 8099).start()
                yield
            finally:
                await runner.cleanup()
        app.cleanup_ctx.append(ingress)
    web.run_app(app, host=os.environ.get("NODIVRA_HOST", "0.0.0.0"), port=int(os.environ.get("NODIVRA_PORT", "8668")), access_log=None, print=lambda _: None)

if __name__ == "__main__":
    main()
