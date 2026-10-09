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
        self.auth_users = [{"id": "fixture-admin", "is_active": True, "group_ids": ["system-admin"]}]
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
                if data['type']=='config/auth/list': result=self.auth_users
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

    async def test_ingress_role_check_uses_current_ha_user_permissions(self):
        self.assertTrue(await self.runtime.ha.is_admin('fixture-admin'))
        self.assertFalse(await self.runtime.ha.is_admin('someone-else'))
        self.auth_users[0]['group_ids'] = ['system-users']
        self.assertFalse(await self.runtime.ha.is_admin('fixture-admin'))
        self.assertFalse(await self.runtime.ha.is_admin(''))

    async def test_unconfigured_runtime_rejects_api_but_keeps_health(self):
        self.runtime.key = ''
        async with self.client.get(f'http://127.0.0.1:{self.port}/api/v1/status', headers={'Authorization':'Bearer '}) as response:
            self.assertEqual(response.status, 401)
        async with self.client.get(f'http://127.0.0.1:{self.port}/health') as response:
            self.assertEqual(response.status, 200)

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

    def plc_package(self, analog=False, entity=''):
        source = block('analogInput' if analog else 'digitalInput', {'minimum': -10, 'maximum': 100, 'initial': 0} if analog else {}, entity=entity)
        marker = block('analogMarker' if analog else 'marker')
        contact = block('analogContact' if analog else 'markerContact', {'markerID': marker['id']})
        output = block('analogOutput' if analog else 'digitalOutput')
        pairs = [(source, marker), (contact, output)]
        wires = [dict(id=str(uuid.uuid4()), source=a['id'], target=b['id'], input=0) for a,b in pairs]
        return dict(protocolVersion=2, timeZone='Europe/Berlin', graph=dict(formatVersion=3, id=str(uuid.uuid4()), title='PLC', blocks=[source, marker, contact, output], wires=wires))

    async def test_plc_virtual_inputs_are_program_scoped_and_revision_checked(self):
        p = self.plc_package(); r = await self.upload(p); await self.enable(r)
        other = await self.upload(self.plc_package()); await self.enable(other)
        source, marker, contact, output = p['graph']['blocks']
        path = 'automations/' + r['id'] + '/inputs/' + source['id']
        await self.request('POST', path, dict(expectedRevision='stale', value=True), expected=409)
        await self.request('POST', path, dict(expectedRevision=r['revision'], value='on'), expected=422)
        values = await self.request('POST', path, dict(expectedRevision=r['revision'], value=True))
        self.assertIs(values['values'][source['id']], True)
        await asyncio.sleep(.35)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertIs(live['signals'][marker['id'].upper()], True)
        self.assertIs(live['signals'][contact['id'].upper()], True)
        self.assertIs(live['signals'][output['id'].upper()], True)
        other_inputs = await self.request('GET', 'automations/' + other['id'] + '/inputs')
        self.assertEqual(list(other_inputs['values'].values()), [False])
        self.assertEqual(self.calls, [])
        await self.request('POST', 'automations/' + r['id'] + '/inputs/' + marker['id'], dict(expectedRevision=r['revision'], value=True), expected=422)
        await self.request('POST', 'automations/' + r['id'] + '/state', dict(enabled=False, mode='observe', expectedRevision=r['revision']))
        await self.request('POST', path, dict(expectedRevision=r['revision'], value=True), expected=409)
        await self.enable(r)
        self.assertIs((await self.request('GET', 'automations/' + r['id'] + '/inputs'))['values'][source['id']], False)

    async def test_plc_analog_control_checks_bounds_and_types(self):
        p = self.plc_package(analog=True); r = await self.upload(p); await self.enable(r)
        source, marker, contact, output = p['graph']['blocks']
        path = 'automations/' + r['id'] + '/inputs/' + source['id']
        for value in [-11, 101, True, '25', None]:
            await self.request('POST', path, dict(expectedRevision=r['revision'], value=value), expected=422)
        await self.request('POST', path, dict(expectedRevision=r['revision'], value=23.5))
        await asyncio.sleep(.35)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertEqual(live['analogSignals'][output['id'].upper()], 23.5)
        self.assertNotIn(output['id'].upper(), live['signals'])
        self.assertEqual(self.calls, [])

    async def test_plc_attributes_updated_atomically_and_unavailable_clears_them(self):
        p = self.plc_package(analog=True, entity='climate.test')
        source, marker, contact, output = p['graph']['blocks']
        source['options']['attribute'] = 'current_temperature'
        r = await self.upload(p); await self.enable(r)
        self.runtime.ha.apply_state({'entity_id': 'climate.test', 'new_state': {'state': 'heat', 'attributes': {'current_temperature': 24.5}}})
        await asyncio.sleep(.35)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertEqual(live['analogSignals'][output['id'].upper()], 24.5)
        self.runtime.ha.apply_state({'entity_id': 'climate.test', 'new_state': {'state': 'unavailable', 'attributes': {'current_temperature': 24.5}}})
        await asyncio.sleep(.35)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertNotIn(output['id'].upper(), live['analogSignals'])
        self.assertNotIn('climate.test#current_temperature', self.runtime.ha.states)
        await self.request('POST', 'automations/' + r['id'] + '/inputs/' + source['id'], dict(expectedRevision=r['revision'], value=25), expected=422)

    async def test_plc_scan_uses_one_process_image_not_one_cycle_per_event(self):
        p = self.plc_package(entity='binary_sensor.test'); r = await self.upload(p); await self.enable(r)
        self.runtime.ticker.cancel()
        with __import__('contextlib').suppress(asyncio.CancelledError):
            await self.runtime.ticker
        await asyncio.gather(*self.runtime.tasks.values(), return_exceptions=True)
        source, marker, contact, output = p['graph']['blocks']
        before = self.runtime.snapshots[r['id']]['cycle']
        for value in ['on', 'off', 'on']:
            self.runtime.ha.apply_state({'entity_id': 'binary_sensor.test', 'new_state': {'state': value}})
        await self.runtime.step(r['id'])
        first = self.runtime.snapshots[r['id']]
        self.assertEqual(first['cycle'], before + 1)
        self.assertIs(first['signals'][source['id'].upper()], True)
        self.assertIs(first['signals'][output['id'].upper()], False)
        await self.runtime.step(r['id'])
        self.assertIs(self.runtime.snapshots[r['id']]['signals'][output['id'].upper()], True)

    async def test_plc_observe_mode_never_sends_real_output(self):
        p = self.plc_package(); p['graph']['blocks'][-1]['entityID'] = 'light.test'
        r = await self.upload(p); await self.enable(r)
        source = p['graph']['blocks'][0]
        await self.request('POST', 'automations/' + r['id'] + '/inputs/' + source['id'], dict(expectedRevision=r['revision'], value=True))
        await asyncio.sleep(.4)
        self.assertEqual(self.calls, [])
        self.assertTrue(any(e['kind'] == 'observe' for e in (await self.request('GET', 'events'))['events']))

    async def test_plc_internal_only_program_survives_ha_disconnect(self):
        p = self.plc_package(); r = await self.upload(p); await self.enable(r)
        for ws in self.sockets:
            await ws.close()
        await asyncio.sleep(.25)
        self.assertTrue(self.runtime.record(r['id'])['enabled'])
        await self.request('GET', 'automations/' + r['id'] + '/inputs')

    async def test_extended_counter_outputs_and_five_gate_ports(self):
        source = block('digitalInput')
        counter = block('function', {'function': 'counter', 'on': 1, 'off': 0})
        gate = block('and', {'inputCount': 5})
        digital = block('digitalOutput')
        analog = block('analogOutput')
        wires = [dict(id=str(uuid.uuid4()), source=a['id'], target=b['id'], input=pin, output=output)
                 for a,b,pin,output in [(source,counter,0,0),(counter,gate,4,0),(gate,digital,0,4),(counter,analog,0,1)]]
        p = dict(protocolVersion=3, timeZone='UTC', graph=dict(formatVersion=4, id=str(uuid.uuid4()), title='Extended PLC', blocks=[source,counter,gate,digital,analog], wires=wires))
        r = await self.upload(p); await self.enable(r)
        await self.request('POST', 'automations/' + r['id'] + '/inputs/' + source['id'], dict(expectedRevision=r['revision'], value=True))
        await asyncio.sleep(.3)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertTrue(live['signals'][digital['id'].upper()])
        self.assertEqual(live['analogSignals'][analog['id'].upper()], 1)
        self.assertEqual(self.calls, [])
        self.assertEqual((await self.request('GET', 'automations/' + r['id']))['package']['graph']['wires'][-2]['output'], 4)

    async def test_eight_visual_q_aliases_preserve_metadata_on_protocol_three(self):
        source = block('digitalInput')
        gate = block('and', {'inputCount': 5})
        gate['outputPortCount'] = 8
        outputs = [block('digitalOutput') for _ in range(8)]
        wires = [dict(id=str(uuid.uuid4()), source=source['id'], target=gate['id'], input=0, output=0)]
        wires += [dict(id=str(uuid.uuid4()), source=gate['id'], target=target['id'], input=0, output=0, displayOutput=i) for i,target in enumerate(outputs)]
        p = dict(protocolVersion=3, timeZone='UTC', graph=dict(formatVersion=4, id=str(uuid.uuid4()), title='Visual Q aliases', blocks=[source,gate]+outputs, wires=wires))
        r = await self.upload(p)
        saved = await self.request('GET', 'automations/' + r['id'])
        self.assertEqual(saved['package'], p)
        await self.enable(r)
        await self.request('POST', 'automations/' + r['id'] + '/inputs/' + source['id'], dict(expectedRevision=r['revision'], value=True))
        await asyncio.sleep(.3)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertTrue(all(live['signals'][target['id'].upper()] for target in outputs))
        self.assertEqual(self.calls, [])

    async def test_extended_function_timer_reports_real_remaining(self):
        source = block('digitalInput')
        timer = block('function', {'function': 'retentiveOnDelay', 'duration': 2})
        p = dict(protocolVersion=3, timeZone='UTC', graph=dict(formatVersion=4, id=str(uuid.uuid4()), title='Timer', blocks=[source,timer], wires=[dict(id=str(uuid.uuid4()), source=source['id'], target=timer['id'], input=0)]))
        r = await self.upload(p); await self.enable(r)
        await self.request('POST', 'automations/' + r['id'] + '/inputs/' + source['id'], dict(expectedRevision=r['revision'], value=True))
        await asyncio.sleep(.3)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertGreater(live['remaining'][timer['id'].upper()], 1)
        self.assertLess(live['remaining'][timer['id'].upper()], 2)
        self.assertFalse(live['signals'][timer['id'].upper()])
        self.assertEqual(self.calls, [])

    async def test_variable_time_transfers_and_reports_captured_countdown(self):
        trigger = block('digitalInput')
        condition = block('digitalInput')
        select = block('function', {'function': 'valueSelect', 'inputCount': 2, 'value1': 2, 'defaultValue': 5})
        timer = block('offDelay', {'durationSource': 'input'})
        wires = [dict(id=str(uuid.uuid4()), source=a['id'], target=b['id'], input=pin)
                 for a,b,pin in [(condition,select,0),(select,timer,2),(trigger,timer,0)]]
        p = dict(protocolVersion=4, timeZone='UTC', graph=dict(formatVersion=5, id=str(uuid.uuid4()), title='Variable time', blocks=[trigger,condition,select,timer], wires=wires))
        r = await self.upload(p)
        self.assertFalse(r['enabled'])
        self.assertEqual((await self.request('GET', 'automations/' + r['id']))['package'], p)
        await self.enable(r)
        async def set_input(b, value):
            await self.request('POST', 'automations/' + r['id'] + '/inputs/' + b['id'], dict(expectedRevision=r['revision'], value=value))
            await asyncio.sleep(.25)
        await set_input(condition, True)
        await set_input(trigger, True)
        await set_input(trigger, False)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertTrue(live['signals'][timer['id'].upper()])
        self.assertGreater(live['remaining'][timer['id'].upper()], 1)
        self.assertLessEqual(live['remaining'][timer['id'].upper()], 2)
        await set_input(condition, False)
        changed = await self.request('GET', 'live/' + r['id'])
        self.assertEqual(changed['analogSignals'][select['id'].upper()], 5)
        self.assertLess(changed['remaining'][timer['id'].upper()], live['remaining'][timer['id'].upper()])
        self.assertEqual(self.calls, [])

    async def test_invalid_dynamic_time_pauses_without_device_calls(self):
        trigger = block('digitalInput')
        value = block('analogInput', {'initial': 0})
        timer = block('pulse', {'durationSource': 'input'})
        wires = [dict(id=str(uuid.uuid4()), source=a['id'], target=timer['id'], input=pin) for a,pin in [(trigger,0),(value,2)]]
        p = dict(protocolVersion=4, timeZone='UTC', graph=dict(formatVersion=5, id=str(uuid.uuid4()), title='Invalid T', blocks=[trigger,value,timer], wires=wires))
        r = await self.upload(p); await self.enable(r)
        await self.request('POST', 'automations/' + r['id'] + '/inputs/' + trigger['id'], dict(expectedRevision=r['revision'], value=True))
        await asyncio.sleep(.3)
        saved = await self.request('GET', 'automations/' + r['id'])
        self.assertFalse(saved['enabled'])
        self.assertIn('T benötigt', saved['error'])
        self.assertEqual(self.calls, [])

    async def test_linked_parameters_transfer_and_execute_only_against_fixture(self):
        control = block('digitalInput')
        value = block('analogInput', {'initial': 25, 'maximum': 100})
        path = [{'key': {'_0': 'data'}}, {'key': {'_0': 'brightness_pct'}}]
        action = block('haAction', {'configuration': {'action': 'light.turn_on', 'target': {'area_id': ['fixture_kitchen']}, 'data': {'brightness_pct': 100}}, 'parameterBindings': [{'path': path, 'type': 'analog', 'label': 'Helligkeit', 'minimum': 0, 'maximum': 100}]})
        wires = [dict(id=str(uuid.uuid4()), source=a['id'], target=action['id'], input=pin) for a,pin in [(control,0),(value,1)]]
        p = dict(protocolVersion=5, timeZone='UTC', graph=dict(formatVersion=6, id=str(uuid.uuid4()), title='Linked parameters fixture', blocks=[control,value,action], wires=wires))
        r = await self.upload(p)
        self.assertFalse(r['enabled'])
        self.assertEqual((await self.request('GET', 'automations/' + r['id']))['package'], p)
        await self.enable(r, 'execute')
        self.assertEqual(self.calls, [])
        async def set_input(b, v):
            await self.request('POST', 'automations/' + r['id'] + '/inputs/' + b['id'], dict(expectedRevision=r['revision'], value=v))
            await asyncio.sleep(.3)
        await set_input(value, 75)
        self.assertEqual(self.calls, [])
        await set_input(control, True)
        self.assertEqual(self.calls[-1]['service'], 'turn_on')
        self.assertEqual(self.calls[-1]['service_data']['brightness_pct'], 75)
        self.assertEqual(self.calls[-1]['target'], {'area_id': ['fixture_kitchen']})
        await set_input(value, 40)
        self.assertEqual(self.calls[-1]['service_data']['brightness_pct'], 40)
        await set_input(control, False)
        self.assertEqual(self.calls[-1]['service'], 'turn_off')
        count = len(self.calls)
        await set_input(value, 10)
        self.assertEqual(len(self.calls), count)

    async def test_authentication_and_no_browser_origin(self):
        async with ClientSession() as client:
            async with client.get(f'http://127.0.0.1:{self.port}/api/v1/status') as response: self.assertEqual(response.status,401)
        async with self.client.get(f'http://127.0.0.1:{self.port}/api/v1/status',headers={'Origin':'http://untrusted.test'}) as response: self.assertEqual(response.status,403)
        self.assertEqual((await self.request('GET','status'))['protocolVersion'],5)

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


    async def test_dashboard_timestamps_distinguish_observing_starting_and_execution(self):
        r = await self.upload(package(service='light.turn_on'))
        self.assertIsNotNone(r['created']); self.assertIsNone(r['lastExecuted'])
        created, updated = r['created'], r['updated']
        await self.enable(r, 'observe')
        await self.state('on')
        current = self.runtime.record(r['id'])
        self.assertIsNotNone(current['lastStarted']); self.assertIsNotNone(current['lastObserved'])
        self.assertIsNone(current['lastExecuted']); self.assertEqual(self.calls, [])
        await self.request('POST', 'automations/'+r['id']+'/state', dict(enabled=False, mode='observe', expectedRevision=r['revision']))
        await self.state('off'); await self.enable(r, 'execute'); await self.state('on')
        current = self.runtime.record(r['id'])
        self.assertIsNotNone(current['lastExecuted']); self.assertEqual(current['created'], created); self.assertEqual(current['updated'], updated)
        self.assertEqual(len(self.calls), 1)
        summary = self.runtime.dashboard()
        self.assertNotIn('package', summary['automations'][0]); self.assertEqual(summary['automations'][0]['title'], 'Integrationstest')
        executed = current['lastExecuted']
        self.runtime.db.execute('DELETE FROM events'); self.runtime.db.commit()
        p = current['package']; p['graph']['title'] = 'Neue Fassung'
        changed = await self.upload(p, expected=r['revision'])
        self.assertEqual(changed['created'], created); self.assertEqual(changed['lastExecuted'], executed)
        self.assertGreater(changed['updated'], updated)
        recovery = server.Runtime(self.directory.name, KEY, ENGINE, 'http://unused/api', '')
        self.assertEqual(recovery.record(r['id'])['lastExecuted'], executed)
        self.assertEqual(recovery.record(r['id'])['created'], created)
        recovery.db.close()

    async def test_failed_device_action_does_not_claim_execution(self):
        r = await self.upload(package(service='light.turn_on')); await self.enable(r, 'execute')
        self.reject_actions = True
        await self.state('on')
        self.assertFalse(self.runtime.record(r['id'])['enabled'])
        self.assertIsNone(self.runtime.record(r['id'])['lastExecuted'])

    async def test_stale_state_version_cannot_restart_a_changed_program(self):
        r = await self.upload(package())
        active = await self.enable(r)
        self.assertGreater(active['stateVersion'], r['stateVersion'])
        await self.request('POST', 'automations/'+r['id']+'/state', dict(enabled=False, expectedRevision=r['revision'], expectedStateVersion=r['stateVersion']), expected=409)
        self.assertTrue(self.runtime.record(r['id'])['enabled'])
        paused = await self.request('POST', 'automations/'+r['id']+'/state', dict(enabled=False, expectedRevision=r['revision'], expectedStateVersion=active['stateVersion']))
        self.assertGreater(paused['stateVersion'], active['stateVersion'])
        await self.request('POST', 'automations/'+r['id']+'/state', dict(enabled=True, mode='observe', expectedRevision=r['revision'], expectedStateVersion=active['stateVersion']), expected=409)
        self.assertFalse(self.runtime.record(r['id'])['enabled'])

    async def test_legacy_database_migration_is_backed_up_and_keeps_unknown_creation(self):
        r = await self.upload(package())
        self.runtime.db.execute('DROP TABLE program_metadata'); self.runtime.db.commit()
        before = set(self.runtime.backup_path.glob('*.sqlite'))
        migrated = server.Runtime(self.directory.name, KEY, ENGINE, 'http://unused/api', '')
        self.assertIsNone(migrated.record(r['id'])['created'])
        self.assertEqual(migrated.record(r['id'])['updated'], r['updated'])
        after = set(migrated.backup_path.glob('*.sqlite'))
        self.assertEqual(len(after-before), 1)
        import sqlite3
        with sqlite3.connect(next(iter(after-before))) as backup:
            self.assertEqual(backup.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            self.assertEqual(backup.execute('SELECT revision FROM programs').fetchone()[0], r['revision'])
            self.assertIsNone(backup.execute("SELECT name FROM sqlite_master WHERE name='program_metadata'").fetchone())
        migrated.db.close()

if __name__=='__main__': unittest.main(verbosity=2)
