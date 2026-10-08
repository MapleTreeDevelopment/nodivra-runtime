"""HTTP + WebSocket + real compiled Swift engine; no actual home devices."""
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch
import uuid
from aiohttp import web, ClientSession, WSMsgType

spec = importlib.util.spec_from_file_location('runtime_server', Path(__file__).parents[1] / 'nodivra_runtime/server/server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
KEY = 'test-fixture-runtime-access-key-0123456789'
ENGINE = os.environ.get('NODIVRA_TEST_ENGINE', '/private/tmp/nodivra-runtime-build/debug/NodivraEngine')

def block(kind, options=None, entity=''):
    return dict(id=str(uuid.uuid4()), kind=kind, title=kind, entityID=entity, x=0, y=0, options=options or {})

def package(service='nodivra.log', delay=False):
    source = block('state', entity='binary_sensor.test')
    action = block('haAction', {'configuration': {'action': service, 'data': {'message': 'Test'} if service == 'nodivra.log' else {}, **({'target': {'entity_id': 'light.test'}} if service != 'nodivra.log' else {})}, 'actionBehavior': 'rising'})
    blocks = [source, action]
    if delay:
        blocks.insert(1, block('haAction', {'configuration': {'delay': {'seconds': 0.3}}}))
    wires = [dict(id=str(uuid.uuid4()), source=a['id'], target=b['id'], input=0) for a,b in zip(blocks,blocks[1:])]
    return dict(protocolVersion=1,timeZone='Europe/Berlin',graph=dict(formatVersion=2,id=str(uuid.uuid4()),title='Integrationstest',blocks=blocks,wires=wires))

class EngineTests(unittest.IsolatedAsyncioTestCase):
    async def test_timeout_stops_engine_and_rejects_further_requests(self):
        engine = server.Engine('unused')
        process = Mock(returncode=None)
        process.stdin.drain = AsyncMock()
        cancelled = asyncio.Event()
        async def stalled_read():
            try:
                await asyncio.Future()
            finally:
                cancelled.set()
        process.stdout.readline = stalled_read
        process.wait = AsyncMock(return_value=0)
        process.terminate.side_effect = lambda: setattr(process, 'returncode', 0)
        engine.process = process
        real_wait_for = asyncio.wait_for
        async def short_timeout(awaitable, timeout):
            return await real_wait_for(awaitable, 0.01 if timeout == 5 else timeout)
        with patch.object(server.asyncio, 'wait_for', side_effect=short_timeout):
            with self.assertRaisesRegex(RuntimeError, 'antwortet nicht'):
                await engine.call(command='validate')
        self.assertTrue(cancelled.is_set())
        process.terminate.assert_called_once()
        process.wait.assert_awaited_once()
        with self.assertRaisesRegex(RuntimeError, 'nicht verfügbar'):
            await engine.call(command='validate')
        process.stdin.write.assert_called_once()

    async def test_shutdown_kills_engine_if_termination_times_out(self):
        engine = server.Engine('unused')
        process = Mock(returncode=None)
        process.wait = AsyncMock(side_effect=[asyncio.TimeoutError(), 0])
        engine.process = process
        await engine.close()
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.await_count, 2)

class RuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='nodivra-runtime-test-')
        self.sockets = []
        self.calls = []
        self.current = 'off'
        self.reject_actions = False
        async def ws_handler(request):
            ws = web.WebSocketResponse()
            await ws.prepare(request)
            await ws.send_json({'type':'auth_required'})
            auth = await ws.receive_json()
            if auth.get('access_token') != 'fixture-ha-token':
                await ws.send_json({'type':'auth_invalid'}); return ws
            await ws.send_json({'type':'auth_ok','ha_version':'fixture'})
            self.sockets.append(ws)
            async for message in ws:
                if message.type != WSMsgType.TEXT: break
                data=json.loads(message.data)
                result=None
                if data['type']=='get_states': result=[{'entity_id':'binary_sensor.test','state':self.current}]
                if data['type']=='get_services': result={'light':{'turn_on':{},'turn_off':{}}}
                if data['type']=='call_service': self.calls.append(data)
                await ws.send_json({'id':data['id'],'type':'result','success':not(self.reject_actions and data['type']=='call_service'),'result':result})
            return ws
        ha=web.Application();ha.router.add_get('/api/websocket',ws_handler)
        self.ha_runner=web.AppRunner(ha);await self.ha_runner.setup()
        site=web.TCPSite(self.ha_runner,'127.0.0.1',0);await site.start()
        self.ha_port=site._server.sockets[0].getsockname()[1]
        self.runtime=server.Runtime(self.directory.name,KEY,ENGINE,f'http://127.0.0.1:{self.ha_port}/api','fixture-ha-token')
        self.runner=web.AppRunner(self.runtime.app());await self.runner.setup()
        site=web.TCPSite(self.runner,'127.0.0.1',0);await site.start()
        self.port=site._server.sockets[0].getsockname()[1]
        self.client=ClientSession(headers={'Authorization':'Bearer '+KEY})
        for _ in range(100):
            if self.runtime.ha.connected: break
            await asyncio.sleep(.02)
        self.assertTrue(self.runtime.ha.connected)

    async def asyncTearDown(self):
        await self.client.close();await self.runner.cleanup();await self.ha_runner.cleanup();self.directory.cleanup()

    async def request(self, method, path, data=None, expected=200):
        async with self.client.request(method,f'http://127.0.0.1:{self.port}/api/v1/'+path,json=data) as response:
            body=await response.json();self.assertEqual(response.status,expected,body);return body

    async def upload(self,p,expected=None,request_id=None):
        return await self.request('PUT','automations/'+p['graph']['id'],dict(package=p,expectedRevision=expected,requestID=request_id or str(uuid.uuid4())))

    async def enable(self,r,mode='observe'):
        return await self.request('POST','automations/'+r['id']+'/state',dict(enabled=True,mode=mode,expectedRevision=r['revision']))

    async def state(self,state):
        before=self.current;self.current=state
        for ws in self.sockets:
            if not ws.closed: await ws.send_json({'id':1,'type':'event','event':{'data':{'entity_id':'binary_sensor.test','old_state':{'state':before},'new_state':{'state':state}}}})
        await asyncio.sleep(.15)

    async def test_authentication_and_no_browser_origin(self):
        async with ClientSession() as client:
            async with client.get(f'http://127.0.0.1:{self.port}/api/v1/status') as response: self.assertEqual(response.status,401)
        async with self.client.get(f'http://127.0.0.1:{self.port}/api/v1/status',headers={'Origin':'http://untrusted.test'}) as response: self.assertEqual(response.status,403)
        self.assertEqual((await self.request('GET','status'))['protocolVersion'],1)

    async def test_transfer_disabled_idempotent_and_conflict(self):
        p=package();request_id=str(uuid.uuid4());r=await self.upload(p,request_id=request_id)
        self.assertFalse(r['enabled']);self.assertEqual((await self.upload(p,request_id=request_id))['revision'],r['revision'])
        p['graph']['title']='Verändert'
        await self.request('PUT','automations/'+r['id'],dict(package=p,expectedRevision=None,requestID=str(uuid.uuid4())),expected=409)
        self.assertEqual(len(self.runtime.records()),1)

    async def test_observe_real_inputs_without_device_actions(self):
        r=await self.upload(package('light.turn_on'));await self.enable(r)
        await self.state('on');await asyncio.sleep(.2)
        self.assertEqual(self.calls,[])
        events=(await self.request('GET','events'))['events']
        self.assertTrue(any(e['kind']=='observe' for e in events))

    async def test_execute_calls_only_fixture_and_completes(self):
        r=await self.upload(package('light.turn_on'));await self.enable(r,'execute')
        await self.state('on');await asyncio.sleep(.2)
        self.assertEqual(len(self.calls),1);self.assertEqual(self.calls[0]['target'],{'entity_id':'light.test'})
        await self.state('on');self.assertEqual(len(self.calls),1)

    async def test_delay_is_visible_and_log_runs_afterwards(self):
        p=package(delay=True);r=await self.upload(p);await self.enable(r)
        await self.state('on')
        live=await self.request('GET','live/'+r['id'])
        self.assertGreater(live['remaining'][p['graph']['blocks'][1]['id'].upper()],0)
        await asyncio.sleep(.4)
        self.assertTrue(any(e['kind']=='log' for e in (await self.request('GET','events'))['events']))
        self.assertEqual(self.calls,[])

    async def test_failed_service_pauses_without_retry(self):
        self.reject_actions=True
        r=await self.upload(package('light.turn_on'));await self.enable(r,'execute');await self.state('on');await asyncio.sleep(.2)
        current=await self.request('GET','automations/'+r['id'])
        self.assertFalse(current['enabled']);self.assertIsNotNone(current['error']);self.assertEqual(len(self.calls),1)
        await self.state('off');await self.state('on');self.assertEqual(len(self.calls),1)

    async def test_short_pulse_is_not_lost_between_scheduler_ticks(self):
        r=await self.upload(package('light.turn_on'));await self.enable(r,'execute')
        for value in ('on','off'):
            for ws in self.sockets:
                if not ws.closed:
                    await ws.send_json({'id':1,'type':'event','event':{'data':{'entity_id':'binary_sensor.test','new_state':{'state':value}}}})
        await asyncio.sleep(.35)
        self.assertEqual(len(self.calls),1)
        self.assertTrue((await self.request('GET','automations/'+r['id']))['enabled'])

    async def test_disconnect_pauses_and_clears_live_values(self):
        r=await self.upload(package('light.turn_on'));await self.enable(r,'execute')
        for ws in self.sockets:
            await ws.close()
        for _ in range(50):
            if not self.runtime.record(r['id'])['enabled']: break
            await asyncio.sleep(.02)
        self.assertFalse((await self.request('GET','automations/'+r['id']))['enabled'])
        await self.request('GET','live/'+r['id'],expected=409)
        self.assertEqual(self.calls,[])

    async def test_health_reports_failed_engine(self):
        await self.runtime.engine.close()
        async with self.client.get(f'http://127.0.0.1:{self.port}/health') as response:
            self.assertEqual(response.status,503)

    async def test_revision_restore_and_sqlite_backup(self):
        p=package();r=await self.upload(p)
        p2=json.loads(json.dumps(p));p2['graph']['title']='Fassung zwei'
        r2=await self.upload(p2,r['revision'])
        revisions=(await self.request('GET','automations/'+r['id']+'/revisions'))['revisions']
        self.assertEqual(len(revisions),2)
        restored=await self.upload(p,r2['revision'])
        self.assertEqual(restored['revision'],r['revision']);self.assertFalse(restored['enabled'])
        backups=list((Path(self.directory.name)/'backups').glob('*.sqlite'));self.assertEqual(len(backups),3)
        import sqlite3
        with sqlite3.connect(sorted(backups)[-1]) as db:
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0],'ok')
            self.assertEqual(json.loads(db.execute('SELECT package FROM programs').fetchone()[0])['graph']['title'],'Fassung zwei')

    async def test_restart_marks_enabled_programs_paused(self):
        r=await self.upload(package());await self.enable(r)
        # Open the persisted store as startup recovery would; no second process started.
        recovery=server.Runtime(self.directory.name,KEY,ENGINE,f'http://127.0.0.1:{self.ha_port}/api','fixture-ha-token')
        self.assertFalse(recovery.record(r['id'])['enabled']);self.assertIn('neu gestartet',recovery.record(r['id'])['error']);recovery.db.close()

    async def test_unsupported_graph_never_saved(self):
        p=package();p['graph']['blocks'][1]['options']['configuration']={'action':'light.turn_on','data':{'value':'{{ trigger.id }}'}}
        check=await self.request('POST','validate',p);self.assertFalse(check['valid'])
        await self.request('PUT','automations/'+p['graph']['id'],dict(package=p,expectedRevision=None,requestID=str(uuid.uuid4())),expected=422)
        self.assertEqual(self.runtime.records(),[])

if __name__=='__main__': unittest.main(verbosity=2)
