"""Standalone browser boundary: no real HA, no exposed Runtime credentials."""
import sys
import time
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock
from aiohttp.test_utils import TestClient, TestServer
from aiohttp import web

ROOT=Path(__file__).resolve().parents[2]
GATEWAY=ROOT/'Dashboards/server'
if not GATEWAY.exists(): GATEWAY=Path(__file__).resolve().parents[1]/'nodivra_dashboards/server'
sys.path.insert(0,str(GATEWAY))
from gateway import DashboardGateway
from browser_access import BrowserAccess

class BrowserAccessTests(unittest.TestCase):
    def test_single_use_expiry_persistence_and_revocation(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'sessions.json'; access=BrowserAccess(path)
            code=access.issue('admin'); token=access.redeem(code)
            self.assertEqual(access.user(token),'admin');self.assertIsNone(access.redeem(code))
            self.assertNotIn(token,path.read_text());self.assertEqual(BrowserAccess(path).user(token),'admin')
            access.sessions[access.digest(token)]['expires']=time.time()-1
            self.assertIsNone(access.user(token))
            code=access.issue('admin');access.codes[access.digest(code)]['expires']=time.time()-1
            self.assertIsNone(access.redeem(code))
            token=access.redeem(access.issue('admin'));access.revoke()
            self.assertIsNone(BrowserAccess(path).user(token))
    def test_rate_limit_and_pending_bound(self):
        access=BrowserAccess()
        for i in range(100):access.issue(str(i))
        self.assertLessEqual(len(access.codes),16)
        code=access.issue('admin')
        for _ in range(10):self.assertIsNone(access.redeem('invalid'))
        self.assertIsNone(access.redeem(code))

class BrowserGatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.gateway=DashboardGateway('http://unused','a'*64,'server',standalone_mode='http',standalone_host='127.0.0.1')
        async def check(req):
            if req.get('browser_user',req.headers.get('X-Remote-User-Id'))!='admin':raise web.HTTPForbidden()
            return {'serverID':'server','protocolVersion':1,'connected':True}
        self.gateway.check=AsyncMock(side_effect=check)
        self.client=TestClient(TestServer(self.gateway.app(standalone=True)));await self.client.start_server()
        self.headers={'X-Nodivra-CSRF':self.gateway.csrf}
    async def asyncTearDown(self):await self.client.close()
    async def login(self):
        code=self.gateway.browsers.issue('admin')
        response=await self.client.post('/api/browser/login',json={'code':code},headers=self.headers)
        token=response.cookies[BrowserAccess.cookie].value
        return response, {'Cookie':BrowserAccess.cookie+'='+token}
    async def test_anonymous_and_forged_headers_never_read_data(self):
        response=await self.client.get('/api/published',headers={'X-Remote-User-Id':'admin','X-Forwarded-For':'172.30.32.2'})
        self.assertEqual(response.status,401);self.gateway.check.assert_not_awaited()
        self.assertEqual((await self.client.get('/',headers={'Host':'evil.example'})).status,403)
        self.assertEqual((await self.client.post('/api/browser/login',json={'code':'0'*10})).status,403)
    async def test_pair_cookie_csrf_logout_and_no_credentials(self):
        response,cookie=await self.login()
        self.assertEqual(response.status,200)
        self.assertTrue(response.cookies[BrowserAccess.cookie]['httponly'])
        self.assertEqual(response.cookies[BrowserAccess.cookie]['samesite'],'Strict')
        page=await self.client.get('/',headers=cookie);text=await page.text()
        self.assertEqual(page.status,200);self.assertNotIn('a'*64,text);self.assertIn('browser-logout',text)
        self.assertEqual((await self.client.post('/api/browser/logout',json={},headers=cookie)).status,403)
        self.assertEqual((await self.client.post('/api/browser/logout',json={},headers=cookie|self.headers)).status,200)
        self.assertEqual((await self.client.get('/api/status',headers=cookie)).status,401)
    async def test_revoked_ha_user_cannot_resume(self):
        _,cookie=await self.login()
        self.gateway.check.side_effect=web.HTTPForbidden()
        self.assertEqual((await self.client.get('/',headers=cookie)).status,403)
    async def test_cannot_pair_from_standalone_port(self):
        _,cookie=await self.login()
        self.assertEqual((await self.client.post('/api/browser/pair',json={},headers=cookie|self.headers)).status,404)
    async def test_disabled_listener_rejects_all_access(self):
        self.gateway.standalone_mode='disabled'
        self.assertEqual((await self.client.get('/')).status,403)
