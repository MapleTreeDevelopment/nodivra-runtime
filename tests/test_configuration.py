"""Ingress access, key setup and ambiguous-write recovery using local fixtures only."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock
import hashlib
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

spec = importlib.util.spec_from_file_location('configuration', Path(__file__).parents[1] / 'nodivra_runtime/server/configuration.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
KEY = 'a' * 64

class ConfigurationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.runtime = SimpleNamespace(key='', ha=SimpleNamespace(connected=True, is_admin=AsyncMock(return_value=True)), dashboard=lambda: {'version': '0.6.1', 'automations': []}, change_state=AsyncMock(return_value=web.json_response({'package': {'private': 'not-for-browser'}})))
        self.config = module.RuntimeConfiguration(self.runtime, 'fixture-supervisor-token')
        self.options = {'access_key': 'short', 'other': 'preserved'}
        self.writes = 0
        self.lost = self.reject = False
        async def supervisor(method, path, data=None):
            if method == 'GET':
                return {'options': self.options.copy(), 'version': '0.6.1', 'version_latest': '0.6.2', 'update_available': True}
            self.writes += 1
            if not self.reject:
                if 'options' in data: self.options = data['options'].copy()
            if self.lost or self.reject: raise TimeoutError()
            return {}
        self.config.call = AsyncMock(side_effect=supervisor)
        app = self.config.app()
        @web.middleware
        async def peer(request, handler):
            return await handler(request.clone(remote='172.30.32.2'))
        app.middlewares.insert(0, peer)
        self.client = TestClient(TestServer(app)); await self.client.start_server()
        self.headers = {'X-Nodivra-CSRF': self.config.csrf}
    async def asyncTearDown(self): await self.client.close()
    def payload(self, confirmed=False):
        return {'key': KEY, 'revision': hashlib.sha256(self.options['access_key'].encode()).hexdigest(), 'confirmReplacement': confirmed}
    async def test_page_never_embeds_key_and_disables_cache(self):
        response = await self.client.get('/')
        self.assertEqual(response.status, 200)
        text = await response.text()
        self.assertIn('Schlüssel generieren', text); self.assertNotIn(KEY, text)
        self.assertEqual(response.headers['Cache-Control'], 'no-store')
        self.assertIn("frame-ancestors 'self'", response.headers['Content-Security-Policy'])
    async def test_generator_is_random_and_does_not_change_configuration(self):
        first = await (await self.client.post('/generate', json={}, headers=self.headers)).json()
        second = await (await self.client.post('/generate', json={}, headers=self.headers)).json()
        self.assertEqual(len(first['key']), 64); self.assertNotEqual(first, second)
        self.assertEqual(self.writes, 0); self.assertEqual(self.runtime.key, '')
    async def test_bad_csrf_and_non_json_are_rejected(self):
        self.assertEqual((await self.client.post('/generate', json={})).status, 403)
        self.assertEqual((await self.client.post('/apply', data='{}', headers=self.headers)).status, 403)
        self.assertEqual(self.writes, 0)
    async def test_direct_and_forged_forwarded_requests_denied(self):
        async with TestClient(TestServer(self.config.app())) as client:
            for path in ['/', '/status', '/dashboard']:
                self.assertEqual((await client.get(path, headers={'X-Forwarded-For': '172.30.32.2'})).status, 403)
    async def test_save_preserves_options_and_reads_back_before_activating(self):
        response = await self.client.post('/apply', json=self.payload(), headers=self.headers)
        self.assertEqual(response.status, 200); self.assertEqual(self.writes, 1)
        self.assertEqual(self.options['other'], 'preserved'); self.assertEqual(self.runtime.key, KEY)
        self.assertEqual(self.options['access_key'], KEY)
    async def test_lost_write_response_reconciles_without_retry(self):
        self.lost = True
        self.assertEqual((await self.client.post('/apply', json=self.payload(), headers=self.headers)).status, 200)
        self.assertEqual(self.writes, 1); self.assertEqual(self.runtime.key, KEY)
    async def test_failed_write_does_not_activate_unsaved_key(self):
        self.reject = True
        self.assertEqual((await self.client.post('/apply', json=self.payload(), headers=self.headers)).status, 503)
        self.assertEqual(self.runtime.key, ''); self.assertEqual(self.options['access_key'], 'short')
    async def test_replacement_needs_confirmation_and_fresh_revision(self):
        self.options['access_key'] = 'b' * 64
        self.assertEqual((await self.client.post('/apply', json=self.payload(), headers=self.headers)).status, 409)
        stale = self.payload(True); stale['revision'] = 'stale'
        self.assertEqual((await self.client.post('/apply', json=stale, headers=self.headers)).status, 409)
        self.assertEqual(self.writes, 0)
        self.assertEqual((await self.client.post('/apply', json=self.payload(True), headers=self.headers)).status, 200)
    async def test_secret_reference_is_not_overwritten(self):
        self.options['access_key'] = '!secret nodivra_key'
        self.assertEqual((await self.client.post('/apply', json=self.payload(True), headers=self.headers)).status, 409)
        self.assertEqual(self.writes, 0)

    async def test_non_admin_cannot_read_generate_or_replace_keys(self):
        self.runtime.ha.is_admin.return_value = False
        for path in ['/status', '/dashboard', '/generate', '/apply', '/automations/00000000-0000-0000-0000-000000000001/state']:
            response = await (self.client.get(path) if path in ['/status', '/dashboard'] else self.client.post(path, json=self.payload(), headers=self.headers))
            self.assertEqual(response.status, 403)
        self.assertEqual(self.writes, 0)

    async def test_dashboard_only_returns_public_addon_information(self):
        self.options['access_key'] = KEY
        result = await (await self.client.get('/dashboard')).json()
        self.assertNotIn(KEY, str(result)); self.assertNotIn('options', result['addon'])
        self.assertEqual(result['addon']['latestVersion'], '0.6.2')
        self.assertEqual(result['automations'], [])

    async def test_browser_activation_requires_explicit_execution_and_fresh_state(self):
        path = '/automations/00000000-0000-0000-0000-000000000001/state'
        data = {'enabled': True, 'mode': 'execute', 'expectedRevision': 'fixture', 'expectedStateVersion': 0}
        self.assertEqual((await self.client.post(path, json=data, headers=self.headers)).status, 409)
        self.runtime.change_state.assert_not_awaited()
        data['confirmExecution'] = True
        response = await self.client.post(path, json=data, headers=self.headers)
        self.assertEqual(await response.json(), {'updated': True})
        self.runtime.change_state.assert_awaited_once()
        del data['expectedStateVersion']
        self.assertEqual((await self.client.post(path, json=data, headers=self.headers)).status, 422)
        self.assertEqual((await self.client.post(path, json={}, headers={})).status, 403)

    async def test_dashboard_remains_readable_if_supervisor_info_fails(self):
        self.config.call.side_effect = TimeoutError()
        response = await self.client.get('/dashboard')
        self.assertEqual(response.status, 200)
        result = await response.json()
        self.assertIsNone(result['addon']); self.assertEqual(result['version'], '0.6.1')
