"""Isolated two-service contract: credentials, CSRF, identity and lost replies."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

ROOT = Path(__file__).resolve().parents[2]
SERVER = Path(__file__).resolve().parents[1] / 'server'
if not SERVER.exists(): SERVER = Path(__file__).resolve().parents[1] / 'nodivra_runtime/server'
sys.path.insert(0, str(SERVER))
from server import Runtime
from dashboard_access import display_key
GATEWAY = ROOT / 'Dashboards/server/gateway.py'
if not GATEWAY.exists(): GATEWAY = Path(__file__).resolve().parents[1] / 'nodivra_dashboards/server/gateway.py'
spec = importlib.util.spec_from_file_location('dashboard_gateway', GATEWAY)
gateway = importlib.util.module_from_spec(spec); spec.loader.exec_module(gateway)
KEY = 'fixture-runtime-key-' + 'a' * 40


class DisplayAccessTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.runtime = Runtime(self.directory.name, KEY, 'unused', 'http://127.0.0.1:1', '')
        self.runtime.start = AsyncMock(); self.runtime.close = AsyncMock()
        self.runtime.ha.is_admin = AsyncMock(return_value=True)
        self.client = TestClient(TestServer(self.runtime.app())); await self.client.start_server()
        self.headers = {'Authorization':'Bearer '+display_key(KEY), 'X-Nodivra-HA-User':'fixture-admin'}

    async def asyncTearDown(self):
        await self.client.close(); self.runtime.db.close(); self.directory.cleanup()

    async def test_display_key_can_only_read_published_resources(self):
        response = await self.client.get('/api/v1/dashboard-display/published', headers=self.headers)
        self.assertEqual(response.status, 200)
        self.assertEqual(await response.json(), {'dashboards':[]})
        for path in ['/api/v1/dashboard-connection','/api/v1/dashboards','/api/v1/automations','/api/v1/status']:
            self.assertEqual((await self.client.get(path, headers=self.headers)).status, 401)

    async def test_missing_user_non_admin_and_browser_origin_denied(self):
        self.runtime.ha.is_admin.side_effect = lambda user: user == 'fixture-admin'
        path='/api/v1/dashboard-display/published'
        self.assertEqual((await self.client.get(path, headers={'Authorization':self.headers['Authorization']})).status,403)
        self.assertEqual((await self.client.get(path, headers=self.headers | {'X-Nodivra-HA-User':'other'})).status,403)
        self.assertEqual((await self.client.get(path, headers=self.headers | {'Origin':'https://untrusted.invalid'})).status,403)

    async def test_connection_is_stable_scoped_and_rotates_with_master(self):
        response = await self.client.get('/api/v1/dashboard-connection',headers={'Authorization':'Bearer '+KEY})
        data=await response.json()
        self.assertEqual(data['accessKey'], display_key(KEY)); self.assertNotEqual(data['accessKey'],KEY)
        self.assertEqual(response.headers['Cache-Control'],'no-store')
        self.runtime.key='new-runtime-key-'+'b'*40
        self.assertEqual((await self.client.get('/api/v1/dashboard-display/published',headers=self.headers)).status,401)


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls=[]; self.identity='fixture-server'; self.reject=False; self.fail=False; self.redirect=False
        async def upstream(request):
            self.calls.append((request.method,request.path,dict(request.headers)))
            if request.headers.get('Authorization') != 'Bearer '+display_key(KEY): return web.Response(status=401)
            if request.headers.get('X-Nodivra-HA-User') != 'fixture-admin': return web.Response(status=403)
            if self.reject: return web.Response(status=403)
            if request.path.endswith('/status'): return web.json_response({'serverID':self.identity,'protocolVersion':1,'connected':True})
            if self.redirect: return web.Response(status=302,headers={'Location':'http://untrusted.invalid/'})
            if self.fail: return web.Response(status=503,text='credential must not be echoed')
            if '/camera/' in request.path: return web.Response(body=b'fixture-jpeg',content_type='image/jpeg')
            if request.method=='POST': return web.json_response({'status':'confirmed'})
            return web.json_response({'dashboards':[]})
        app=web.Application();app.router.add_route('*','/{path:.*}',upstream)
        self.upstream=TestServer(app);await self.upstream.start_server()
        self.gateway=gateway.DashboardGateway(str(self.upstream.make_url('')).rstrip('/'),display_key(KEY),'fixture-server')
        app=self.gateway.app()
        @web.middleware
        async def peer(request, handler): return await handler(request.clone(remote='172.30.32.2'))
        app.middlewares.insert(0,peer)
        self.client=TestClient(TestServer(app));await self.client.start_server()
        self.headers={'X-Remote-User-Id':'fixture-admin','X-Nodivra-CSRF':self.gateway.csrf}

    async def asyncTearDown(self): await self.client.close();await self.upstream.close()

    async def test_html_contains_no_credential_and_reuses_renderer(self):
        response=await self.client.get('/'); text=await response.text()
        self.assertNotIn(KEY,text); self.assertNotIn(display_key(KEY),text)
        self.assertIn('Nodivra.boot',text);self.assertIn("frame-ancestors 'self'",response.headers['Content-Security-Policy'])

    async def test_direct_access_and_forged_proxy_header_denied(self):
        other = gateway.DashboardGateway(self.gateway.runtime_url, self.gateway.key, self.gateway.server_id)
        async with TestClient(TestServer(other.app())) as client:
            response=await client.get('/',headers={'X-Forwarded-For':'172.30.32.2'})
            self.assertEqual(response.status,403)

    async def test_published_data_forwards_only_scoped_identity(self):
        response=await self.client.get('/api/published',headers=self.headers|{'Authorization':'do-not-forward'})
        self.assertEqual(response.status,200)
        self.assertEqual(self.calls[-1][2]['Authorization'],'Bearer '+display_key(KEY))
        self.assertNotIn('X-Nodivra-CSRF',self.calls[-1][2])
        self.assertEqual((await self.client.get('/api/automations',headers=self.headers)).status,404)

    async def test_post_requires_csrf_and_admin(self):
        path='/api/published/fixture/actions'
        self.assertEqual((await self.client.post(path,json={},headers={'X-Remote-User-Id':'fixture-admin'})).status,403)
        self.assertEqual(self.calls,[])
        self.assertEqual((await self.client.post(path,json={},headers=self.headers|{'X-Remote-User-Id':'other'})).status,403)
        self.assertFalse(any(method=='POST' for method,_,_ in self.calls))

    async def test_wrong_server_blocks_actions_before_sending(self):
        self.identity='wrong-server'
        self.assertEqual((await self.client.post('/api/published/fixture/actions',json={},headers=self.headers)).status,409)
        self.assertFalse(any(method=='POST' for method,_,_ in self.calls))

    async def test_failed_action_is_not_retried_and_raw_error_is_not_exposed(self):
        self.fail=True
        response=await self.client.post('/api/published/fixture/actions',json={},headers=self.headers)
        self.assertEqual(response.status,503);self.assertNotIn('credential',await response.text())
        self.assertEqual(sum(method=='POST' for method,_,_ in self.calls),1)
        self.assertEqual(self.gateway.connections,0)

    async def test_redirect_not_followed_and_camera_stream_is_forwarded(self):
        self.redirect=True
        self.assertEqual((await self.client.get('/api/published',headers=self.headers)).status,502)
        self.redirect=False
        response=await self.client.get('/api/published/fixture/camera/camera?revision=fixture',headers=self.headers)
        self.assertEqual(await response.read(),b'fixture-jpeg')
        self.assertEqual(response.headers['Content-Type'],'image/jpeg')

    async def test_unconfigured_service_explains_setup_without_touching_runtime(self):
        self.gateway.key=''
        response=await self.client.get('/api/published',headers=self.headers)
        self.assertEqual(response.status,503);self.assertIn('Mac-App',await response.text());self.assertEqual(self.calls,[])
