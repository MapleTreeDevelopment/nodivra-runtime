"""Read-only block diagnostics and transport acknowledgements, against fake HA."""
import asyncio
import unittest

import test_runtime as fixture
from test_runtime import package


class DiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = fixture.RuntimeTests.asyncSetUp
    asyncTearDown = fixture.RuntimeTests.asyncTearDown
    request = fixture.RuntimeTests.request
    upload = fixture.RuntimeTests.upload
    enable = fixture.RuntimeTests.enable
    state = fixture.RuntimeTests.state

    async def test_observation_never_claims_a_device_acknowledgement(self):
        p = package('light.turn_on'); r = await self.upload(p); await self.enable(r)
        await self.state('on')
        live = await self.request('GET', 'live/' + r['id'])
        key = p['graph']['blocks'][-1]['id'].upper()
        self.assertEqual(live['actions'][key]['status'], 'observed')
        self.assertIn('diagnostics', live)
        self.assertEqual(self.calls, [])
        events = (await self.request('GET', 'events'))['events']
        self.assertFalse(any(e['kind'] == 'action_sent' for e in events))

    async def test_sent_then_confirmed_status_and_events_reference_the_block(self):
        p = package('light.turn_on'); r = await self.upload(p); await self.enable(r, 'execute')
        sent, release = asyncio.Event(), asyncio.Event()
        original = self.runtime.ha.action
        async def delayed_confirmation(configuration, on_sent=None):
            await original(configuration, on_sent=on_sent)
            sent.set()
            await release.wait()
        self.runtime.ha.action = delayed_confirmation
        await self.state('on')
        await asyncio.wait_for(sent.wait(), 2)
        key = p['graph']['blocks'][-1]['id'].upper()
        live = await self.request('GET', 'live/' + r['id'])
        self.assertEqual(live['actions'][key]['status'], 'sent')
        release.set(); await asyncio.sleep(.3)
        live = await self.request('GET', 'live/' + r['id'])
        self.assertEqual(live['actions'][key]['status'], 'confirmed')
        self.assertIn('Gerätezustand nicht geprüft', live['actions'][key]['message'])
        events = (await self.request('GET', 'events'))['events']
        action_events = [e for e in reversed(events) if e['blockID'] == key]
        self.assertEqual([e['kind'] for e in action_events], ['action_sent', 'action'])
        self.assertTrue(all(e['automationID'] == r['id'] for e in action_events))

    async def test_rejected_action_is_a_persistent_block_event_not_a_success(self):
        p = package('light.turn_on'); r = await self.upload(p); await self.enable(r, 'execute')
        self.reject_actions = True
        await self.state('on'); await asyncio.sleep(.2)
        events = (await self.request('GET', 'events'))['events']
        failed = [e for e in events if e['kind'] == 'action_failed']
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0]['blockID'], p['graph']['blocks'][-1]['id'].upper())
        self.assertFalse(any(e['kind'] == 'action' for e in events))
        self.assertFalse(self.runtime.record(r['id'])['enabled'])
        await self.request('GET', 'live/' + r['id'], expected=409)
