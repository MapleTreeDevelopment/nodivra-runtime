"""Hard process failures against a loopback HA fixture; never uses a real HA server.

Unlike the in-process API tests, these start server.py and the compiled engine in
their own process group, SIGKILL both, and reopen the same SQLite database/WAL.
They test process-crash recovery, not host power-loss or storage durability.
"""
import asyncio
import contextlib
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import sys
import tempfile
import time
import unittest
import uuid

from aiohttp import ClientError, ClientSession, ClientTimeout, web, WSMsgType
from test_runtime import ENGINE, KEY, block, package, server


def program(blocks, connections):
    return dict(protocolVersion=5, timeZone='Europe/Berlin', graph=dict(
        formatVersion=6, id=str(uuid.uuid4()), title='Isolierter Ausfalltest',
        blocks=blocks, wires=[dict(id=str(uuid.uuid4()), source=a['id'],
                                  target=b['id'], input=pin)
                              for a, b, pin in connections]))


@unittest.skipUnless(os.name == 'posix', 'Process-group SIGKILL requires POSIX')
class CrashRecoveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='nodivra-crash-test-')
        self.addCleanup(self.directory.cleanup)
        self.process = None
        self.logs = []
        self.current = 'off'
        self.sockets = []
        self.calls = []
        self.hold_ack = False
        self.hold_snapshot = False
        self.pending_snapshots = []
        self.guard_at_call = []
        self.guarded_identity = None

        async def websocket(request):
            ws = web.WebSocketResponse()
            await ws.prepare(request)
            await ws.send_json({'type': 'auth_required'})
            auth = await ws.receive_json()
            if auth.get('access_token') != 'fixture-ha-token':
                await ws.close()
                return ws
            await ws.send_json({'type': 'auth_ok', 'ha_version': 'crash-fixture'})
            self.sockets.append(ws)
            async for message in ws:
                if message.type != WSMsgType.TEXT:
                    break
                data = json.loads(message.data)
                result = None
                if data['type'] == 'get_states':
                    if self.hold_snapshot:
                        self.pending_snapshots.append((ws, data['id']))
                        continue
                    result = self.states()
                elif data['type'] == 'get_services':
                    result = {'light': {'turn_on': {}, 'turn_off': {}}}
                elif data['type'] == 'call_service':
                    # Read through an independent connection, before acknowledging
                    # receipt: this must already have been durably committed.
                    if self.guarded_identity:
                        self.guard_at_call.append(self.saved(self.guarded_identity)['blocked'])
                    self.calls.append(data)
                    if self.hold_ack:
                        continue
                await ws.send_json(dict(id=data['id'], type='result', success=True, result=result))
            return ws

        ha = web.Application()
        ha.router.add_get('/api/websocket', websocket)
        self.ha_runner = web.AppRunner(ha, access_log=None)
        await self.ha_runner.setup()
        self.addAsyncCleanup(self.ha_runner.cleanup)
        site = web.TCPSite(self.ha_runner, '127.0.0.1', 0)
        await site.start()
        self.ha_port = site._server.sockets[0].getsockname()[1]
        self.client = ClientSession(headers={'Authorization': 'Bearer ' + KEY},
                                    timeout=ClientTimeout(total=3))
        self.addAsyncCleanup(self.client.close)
        self.addAsyncCleanup(self.stop_process)
        await self.start_process()

    def states(self):
        return [{'entity_id': 'binary_sensor.test', 'state': self.current}]

    async def start_process(self, connected=True):
        self.assertIsNone(self.process)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            self.port = listener.getsockname()[1]
        # Do not inherit Supervisor credentials, /data or runtime endpoint options.
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('NODIVRA_', 'SUPERVISOR_'))}
        env.update(NODIVRA_DATA=self.directory.name, NODIVRA_ACCESS_KEY=KEY,
                   NODIVRA_ENGINE=str(Path(ENGINE).resolve()),
                   NODIVRA_HA_BASE=f'http://127.0.0.1:{self.ha_port}/api',
                   NODIVRA_HA_TOKEN='fixture-ha-token', NODIVRA_HOST='127.0.0.1',
                   NODIVRA_PORT=str(self.port), PYTHONDONTWRITEBYTECODE='1')
        log = Path(self.directory.name) / f'process-{len(self.logs)}.log'
        self.logs.append(log)
        with log.open('wb') as stream:
            self.process = await asyncio.create_subprocess_exec(
                sys.executable, str(Path(server.__file__).resolve()), env=env,
                cwd=self.directory.name, start_new_session=True,
                stdout=stream, stderr=stream)

        async def ready():
            if self.process.returncode is not None:
                self.fail(f'Runtime exited: {log.read_text()}')
            try:
                state = await self.request('GET', 'status')
                return state['engineReady'] and (not connected or state['homeAssistantConnected'])
            except (ClientError, TimeoutError):
                return False
        await self.until(ready, 'runtime startup')

    async def stop_process(self):
        if self.process is None:
            return
        process, self.process = self.process, None
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        await asyncio.wait_for(process.wait(), 5)

    async def crash(self):
        process = self.process
        await self.stop_process()
        self.assertEqual(process.returncode, -signal.SIGKILL)
        # The abrupt path must not have had an opportunity to call Runtime.close.
        with sqlite3.connect(Path(self.directory.name) / 'runtime.sqlite') as db:
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')

    async def request(self, method, path, data=None, expected=200):
        async with self.client.request(method, f'http://127.0.0.1:{self.port}/api/v1/{path}', json=data) as response:
            body = await response.json()
            self.assertEqual(response.status, expected, body)
            return body

    async def until(self, predicate, description, timeout=8):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            value = await predicate()
            if value:
                return value
            await asyncio.sleep(.04)
        self.fail(f'Timed out: {description}\n' + '\n'.join(p.read_text() for p in self.logs))

    async def upload(self, p, retained=True, automatic=True):
        record = await self.request('PUT', 'automations/' + p['graph']['id'],
                                    dict(package=p, expectedRevision=None, requestID=str(uuid.uuid4())))
        return await self.request('POST', 'automations/' + record['id'] + '/recovery',
                                  dict(retained=retained, automatic=automatic, reset=False,
                                       expectedRevision=record['revision'], expectedStateVersion=record['stateVersion']))

    async def set_enabled(self, record, enabled=True, mode='observe', expected=200):
        return await self.request('POST', 'automations/' + record['id'] + '/state',
                                  dict(enabled=enabled, mode=mode, expectedRevision=record['revision']), expected)

    async def record(self, identity):
        return await self.request('GET', 'automations/' + identity)

    async def wait_running(self, identity):
        async def running():
            record = await self.record(identity)
            return record if record['enabled'] else None
        return await self.until(running, 'automatic restart')

    def saved(self, identity):
        with sqlite3.connect(f'file:{Path(self.directory.name) / "runtime.sqlite"}?mode=ro', uri=True) as db:
            db.row_factory = sqlite3.Row
            return dict(db.execute('SELECT * FROM program_recovery WHERE id=?', (identity,)).fetchone())

    async def wait_saved(self, identity, after=0):
        async def saved():
            row = self.saved(identity)
            return row if row['checkpoint'] and row['captured'] > after and not row['blocked'] else None
        return await self.until(saved, 'settled checkpoint')

    async def virtual(self, record, source, value):
        await self.request('POST', f"automations/{record['id']}/inputs/{source['id']}",
                           dict(expectedRevision=record['revision'], value=value))

    async def state(self, value):
        previous, self.current = self.current, value
        for ws in self.sockets:
            if not ws.closed:
                await ws.send_json(dict(id=1, type='event', event={'data': {
                    'entity_id': 'binary_sensor.test', 'old_state': {'state': previous},
                    'new_state': {'state': value}}}))

    async def wait_calls(self, count):
        async def calls():
            return len(self.calls) >= count
        await self.until(calls, f'{count} fixture action(s)')
        self.assertEqual(len(self.calls), count)

    async def test_running_timer_survives_repeated_sigkill_without_counting_downtime(self):
        source = block('digitalInput')
        timer = block('offDelay', {'duration': 8})
        output = block('digitalOutput')
        r = await self.upload(program([source, timer, output], [(source, timer, 0), (timer, output, 0)]))
        await self.set_enabled(r)
        await self.virtual(r, source, True)
        await asyncio.sleep(.2)
        await self.virtual(r, source, False)
        await self.wait_saved(r['id'], time.time())
        server_id = (await self.request('GET', 'status'))['serverID']
        for _ in range(2):
            await self.crash()
            row = self.saved(r['id'])
            checkpoint = json.loads(row['checkpoint'])['engine']
            # Swift UUID-keyed dictionaries encode as alternating key/value pairs.
            deadlines = dict(zip(checkpoint['deadlines'][::2], checkpoint['deadlines'][1::2]))
            remaining = deadlines[timer['id'].upper()] - checkpoint['time']
            self.assertGreater(remaining, 2)
            await asyncio.sleep(1.4)
            await self.start_process()
            resumed = await self.wait_running(r['id'])
            live = await self.request('GET', 'live/' + r['id'])
            self.assertAlmostEqual(live['remaining'][timer['id'].upper()], remaining, delta=.8)
            self.assertTrue(live['signals'][output['id'].upper()])
            self.assertEqual(resumed['revision'], r['revision'])
            self.assertEqual(resumed['mode'], 'observe')
            self.assertEqual((await self.request('GET', 'status'))['serverID'], server_id)
        async def expired():
            live = await self.request('GET', 'live/' + r['id'])
            return not live['signals'][output['id'].upper()]
        await self.until(expired, 'resumed off-delay expiry', timeout=10)
        self.assertEqual(self.calls, [])

    async def test_merkers_counter_relay_and_virtual_values_survive_without_new_edge(self):
        i, reset, ai = block('digitalInput'), block('digitalInput'), block('analogInput')
        m, am, rs = block('marker'), block('analogMarker'), block('latch')
        counter = block('function', {'function': 'counter'})
        r = await self.upload(program([i, reset, ai, m, am, rs, counter], [
            (i, m, 0), (i, counter, 0), (i, rs, 0), (reset, rs, 1), (ai, am, 0)]))
        await self.set_enabled(r)
        await self.virtual(r, i, True)
        await self.virtual(r, ai, 37.5)
        await self.wait_saved(r['id'], time.time())
        await self.crash()
        await self.start_process()
        await self.wait_running(r['id'])
        live = await self.request('GET', 'live/' + r['id'])
        self.assertTrue(live['signals'][m['id'].upper()])
        self.assertTrue(live['signals'][rs['id'].upper()])
        self.assertEqual(live['analogSignals'][am['id'].upper()], 37.5)
        self.assertEqual(live['analogSignals'][counter['id'].upper()], 1)
        values = (await self.request('GET', 'automations/' + r['id'] + '/inputs'))['values']
        self.assertEqual(values, {i['id']: True, reset['id']: False, ai['id']: 37.5})
        await self.virtual(r, i, False)
        await self.virtual(r, reset, True)
        await asyncio.sleep(.2)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertFalse(live['signals'][rs['id'].upper()])
        await self.virtual(r, i, True)
        await asyncio.sleep(.2)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertEqual(live['analogSignals'][counter['id'].upper()], 2)
        self.assertEqual(self.calls, [])

    async def test_unacknowledged_side_effect_stays_blocked_and_does_not_block_other_programs(self):
        r = await self.upload(package('light.turn_on'))
        independent = await self.upload(package())
        await self.set_enabled(r, mode='execute')
        await self.set_enabled(independent)
        self.guarded_identity = r['id']
        self.hold_ack = True
        await self.state('on')
        await self.wait_calls(1)
        self.assertEqual(self.guard_at_call, [1])
        await self.wait_saved(independent['id'], time.time())
        await self.crash()  # HA received the call but never acknowledged it.
        self.assertEqual(self.saved(r['id'])['blocked'], 1)
        self.hold_ack = False
        for _ in range(2):
            await self.start_process()
            await self.wait_running(independent['id'])
            await asyncio.sleep(1.2)
            record = await self.record(r['id'])
            self.assertFalse(record['enabled'])
            self.assertTrue(record['recovery']['blocked'])
            self.assertFalse(record['recovery']['pending'])
            await self.set_enabled(record, mode='execute', expected=409)
            self.assertEqual(len(self.calls), 1)
            await self.crash()

    async def test_confirmed_action_is_not_replayed_after_crash(self):
        r = await self.upload(package('light.turn_on'))
        await self.set_enabled(r, mode='execute')
        self.guarded_identity = r['id']
        await self.state('on')
        await self.wait_calls(1)
        await self.wait_saved(r['id'], time.time())
        await self.crash()
        self.assertEqual(self.saved(r['id'])['blocked'], 0)
        await self.start_process()
        resumed = await self.wait_running(r['id'])
        self.assertEqual(resumed['mode'], 'execute')
        await asyncio.sleep(.4)
        self.assertEqual(len(self.calls), 1)
        await self.state('off')
        await asyncio.sleep(.2)
        await self.state('on')
        await self.wait_calls(2)
        self.assertEqual(self.guard_at_call, [1, 1])

    async def test_fresh_snapshot_required_and_offline_change_does_not_replay(self):
        r = await self.upload(package('light.turn_on'))
        await self.set_enabled(r, mode='execute')
        await self.crash()
        self.current = 'on'
        self.hold_snapshot = True
        await self.start_process(connected=False)
        await asyncio.sleep(1.2)
        record = await self.record(r['id'])
        self.assertFalse(record['enabled'])
        self.assertTrue(record['recovery']['pending'])
        self.assertFalse((await self.request('GET', 'status'))['homeAssistantConnected'])
        self.assertEqual(self.calls, [])
        self.hold_snapshot = False
        for ws, request_id in self.pending_snapshots:
            await ws.send_json(dict(id=request_id, type='result', success=True, result=self.states()))
        await self.wait_running(r['id'])
        await asyncio.sleep(.3)
        self.assertEqual(self.calls, [])
        await self.state('off')
        await asyncio.sleep(.2)
        await self.state('on')
        await self.wait_calls(1)

    async def test_crash_does_not_enable_manual_paused_or_default_programs(self):
        default = await self.upload(package(), retained=False, automatic=False)
        manual = await self.upload(package(), automatic=False)
        paused = await self.upload(package())
        automatic = await self.upload(package())
        for r in (default, manual, paused, automatic):
            await self.set_enabled(r)
        await self.set_enabled(paused, enabled=False)
        await self.crash()
        await self.start_process()
        await self.wait_running(automatic['id'])
        await asyncio.sleep(1.2)
        for r in (default, manual, paused):
            record = await self.record(r['id'])
            self.assertFalse(record['enabled'])
            self.assertFalse(record['recovery']['pending'])
        self.assertEqual(self.calls, [])

    async def test_wait_block_resumes_once_after_crash(self):
        p = package('light.turn_on', delay=True)
        wait = p['graph']['blocks'][1]
        wait['options']['configuration']['delay'] = {'seconds': 4}
        r = await self.upload(p)
        await self.set_enabled(r, mode='execute')
        await self.state('on')
        await self.wait_saved(r['id'], time.time())
        self.assertEqual(self.calls, [])
        await self.crash()
        await asyncio.sleep(1.4)
        await self.start_process()
        await self.wait_running(r['id'])
        live = await self.request('GET', 'live/' + r['id'])
        self.assertGreater(live['remaining'][wait['id'].upper()], 1.5)
        await self.wait_calls(1)
        await self.wait_saved(r['id'], time.time())
        await self.crash()
        await self.start_process()
        await self.wait_running(r['id'])
        await asyncio.sleep(.4)
        self.assertEqual(len(self.calls), 1)
