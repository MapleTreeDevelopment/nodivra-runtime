"""Dashboard publication, conflict recovery and media isolation. No live Home Assistant."""
import asyncio
import copy
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock
import uuid
from aiohttp import web, ClientSession
from aiohttp.test_utils import TestClient, TestServer
sys.path.insert(0, str(Path(__file__).parents[1] / 'server'))
from dashboards import DashboardStore, DashboardService, DashboardError, validate
from configuration import RuntimeConfiguration

def uid(): return str(uuid.uuid4())
def component(kind='light', entity='light.kitchen'):
    return dict(id=uid(),kind=kind,title='Küche',text='',unit='',assetID='',effect='none',animated=True,cameraMode='stream',binding=dict(source='entity',entityID=entity,attribute='',programID='',blockID='',metric='signal'),layouts={size:dict(x=0,y=0,width=4,height=5) for size in ('desktop','tablet','mobile')})
def document(*components):
    return dict(schemaVersion=1,id=uid(),title='Mein Zuhause',theme=dict(accent='#007AFF',appearance='system',font='system',fontSize=15,spacing=12,radius=18),pages=[dict(id=uid(),title='Übersicht',components=list(components))],assets=[])
def request(record=None, **fields):
    return dict(requestID=uid(),expectedRevision=record['revision'] if record else None,expectedStateVersion=record['stateVersion'] if record else None,**fields)

class StoreTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(); self.store=DashboardStore(self.directory.name)
        self.doc=document(component())
    def tearDown(self): self.directory.cleanup()
    def save(self): return self.store.change(self.doc['id'],'save',request(document=self.doc))
    def test_corrupt_dashboard_storage_does_not_prevent_runtime_construction(self):
        import server
        with tempfile.TemporaryDirectory() as folder:
            damaged=Path(folder)/'dashboards.sqlite';original=b'not a database';damaged.write_bytes(original)
            runtime=server.Runtime(folder,'fixture-key-'+'a'*40,'unused-engine','http://127.0.0.1:1/api','fixture-token')
            self.assertEqual(runtime.records(),[])
            with self.assertRaises(DashboardError) as error:runtime.dashboards.store.read()
            self.assertEqual(error.exception.status,503)
            self.assertEqual(damaged.read_bytes(),original)
    def test_draft_publication_restore_and_new_client_are_independent(self):
        original=self.save(); published=self.store.change(self.doc['id'],'publish',request(original))
        self.doc['title']='Änderung'
        changed=self.store.change(self.doc['id'],'save',request(published,document=self.doc))
        self.assertEqual(self.store.published(self.doc['id'])['document']['title'],'Mein Zuhause')
        restored=self.store.change(self.doc['id'],'restore',request(changed,revision=original['revision']))
        self.assertNotEqual(restored['revision'],original['revision'])
        self.assertEqual(restored['document']['title'],'Mein Zuhause')
        self.assertEqual(DashboardStore(self.directory.name).read(self.doc['id']),restored)
        unpublished=self.store.change(self.doc['id'],'unpublish',request(restored))
        self.assertIsNone(unpublished['publishedRevision'])
        with self.assertRaises(DashboardError): self.store.published(self.doc['id'])
        self.assertEqual(len(list(self.store.backups.glob('*.sqlite'))),3)
    def test_ambiguous_save_is_idempotent_and_reused_id_cannot_change_payload(self):
        payload=request(document=self.doc)
        one=self.store.change(self.doc['id'],'save',payload)
        self.assertEqual(self.store.change(self.doc['id'],'save',payload),one)
        self.assertEqual(len(self.store.history(self.doc['id'])),1)
        payload=copy.deepcopy(payload); payload['document']['title']='Different'
        with self.assertRaises(DashboardError) as ctx:self.store.change(self.doc['id'],'save',payload)
        self.assertEqual(ctx.exception.status,409)
    def test_two_macs_cannot_overwrite_each_other(self):
        record=self.save()
        def change(title):
            doc=copy.deepcopy(self.doc);doc['title']=title
            try:return self.store.change(doc['id'],'save',request(record,document=doc))
            except DashboardError as e:return e.status
        with ThreadPoolExecutor(2) as pool: results=list(pool.map(change,['Mac A','Mac B']))
        self.assertEqual(sum(r==409 for r in results),1)
        self.assertEqual(len(self.store.history(self.doc['id'])),2)
    def test_invalid_media_targets_layouts_effects_and_assets_are_rejected(self):
        for field,value in [('kind','iframe'),('effect','url(https://bad)'),('cameraMode','raw')]:
            doc=copy.deepcopy(self.doc);doc['pages'][0]['components'][0][field]=value
            with self.assertRaises(DashboardError):validate(doc)
        for entity in ['camera../secret','http://secret','light.kitchen']:
            with self.assertRaises(DashboardError):validate(document(component('camera',entity)),complete=True)
        doc=document(component('camera','camera.entrance'));validate(doc,complete=True)
        doc['pages'][0]['components'][0]['layouts']['mobile']['x']=3
        with self.assertRaises(DashboardError):validate(doc)
        self.doc['assets']=[dict(id=uid(),mime='image/svg+xml',data='PHN2Zz4=')]
        with self.assertRaises(DashboardError):validate(self.doc)
    def test_empty_targets_can_be_saved_but_not_published(self):
        self.doc=document(component('camera',''));record=self.save()
        with self.assertRaises(DashboardError):self.store.change(self.doc['id'],'publish',request(record))
        self.assertIsNone(self.store.read(self.doc['id'])['publishedRevision'])

class ServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.ha=SimpleNamespace(connected=True,states={'light.kitchen':'on','light.kitchen#brightness':'128','sensor.temperature':'21.5','camera.entrance':'idle','camera.entrance#access_token':'secret-camera-token'},is_admin=AsyncMock(return_value=True),action=AsyncMock(),base='http://not-used/api',token='never-in-browser',session=None)
        self.runtime=SimpleNamespace(ha=self.ha,snapshots={},running={})
        self.service=DashboardService(self.runtime,self.directory.name);self.runtime.dashboards=self.service
        self.doc=document(component(),component('camera','camera.entrance'),component('graph','sensor.temperature'))
        self.record=self.service.store.change(self.doc['id'],'save',request(document=self.doc))
        self.record=self.service.store.change(self.doc['id'],'publish',request(self.record))
        self.config=RuntimeConfiguration(self.runtime,'supervisor-secret');app=self.config.app()
        @web.middleware
        async def peer(req,handler):return await handler(req.clone(remote='172.30.32.2'))
        app.middlewares.insert(0,peer);self.client=TestClient(TestServer(app));await self.client.start_server()
        self.path='/dashboards/api/published/'+self.doc['id'];self.headers={'X-Nodivra-CSRF':self.config.csrf}
    async def asyncTearDown(self):
        await self.client.close()
        if self.ha.session:await self.ha.session.close()
        self.directory.cleanup()
    async def test_auth_csrf_current_publication_and_safe_actions(self):
        self.assertEqual((await self.client.get(self.path)).status,200)
        c=self.doc['pages'][0]['components'][0];payload=dict(componentID=c['id'],revision=self.record['revision'],requestID=uid(),on=True,brightness=30,entityID='light.other')
        self.assertEqual((await self.client.post(self.path+'/actions',json=payload)).status,403)
        result=await self.client.post(self.path+'/actions',json=payload,headers=self.headers)
        self.assertEqual((await result.json())['status'],'confirmed')
        self.ha.action.assert_awaited_once_with({'action':'light.turn_on','target':{'entity_id':'light.kitchen'},'data':{'brightness_pct':30}})
        await self.client.post(self.path+'/actions',json=payload,headers=self.headers);self.ha.action.assert_awaited_once()
        payload['requestID']=uid();payload['revision']='stale'
        self.assertEqual((await self.client.post(self.path+'/actions',json=payload,headers=self.headers)).status,409)
        self.ha.is_admin.return_value=False
        for path in [self.path,self.path+'/values','/dashboards/']:
            self.assertEqual((await self.client.get(path)).status,403)
    async def test_area_target_resolves_lights_and_uses_fixed_area(self):
        c=component('light','');c['binding']['areaID']='kitchen';doc=document(c)
        self.ha.area_lights=AsyncMock(return_value={'kitchen':['light.kitchen']})
        record=self.service.store.change(doc['id'],'save',request(document=doc))
        record=self.service.store.change(doc['id'],'publish',request(record))
        path='/dashboards/api/published/'+doc['id']+'/actions'
        payload=dict(componentID=c['id'],revision=record['revision'],requestID=uid(),on=False,areaID='forged')
        self.assertEqual((await self.client.post(path,json=payload,headers=self.headers)).status,200)
        self.ha.action.assert_awaited_once_with({'action':'light.turn_off','target':{'area_id':'kitchen'},'data':{}})
        self.ha.states['light.kitchen']='unavailable';payload['requestID']=uid()
        self.assertEqual((await self.client.post(path,json=payload,headers=self.headers)).status,409)
        self.ha.action.assert_awaited_once()

    async def test_scene_and_climate_actions_validate_fixed_targets_and_bounds(self):
        scene, climate = component('scene','scene.relax'), component('climate','climate.kitchen')
        doc = document(scene, climate)
        self.ha.states.update({'scene.relax':'2026-01-01', 'climate.kitchen':'heat', 'climate.kitchen#current_temperature':'21.5', 'climate.kitchen#temperature':'22', 'climate.kitchen#min_temp':'7', 'climate.kitchen#max_temp':'30'})
        record = self.service.store.change(doc['id'],'save',request(document=doc))
        record = self.service.store.change(doc['id'],'publish',request(record))
        path='/dashboards/api/published/'+doc['id']+'/actions'
        def payload(c, **extra): return dict(componentID=c['id'],revision=record['revision'],requestID=uid(),**extra)
        self.assertEqual((await self.client.post(path,json=payload(climate,temperature=31),headers=self.headers)).status,422)
        self.assertEqual((await self.client.post(path,json=payload(scene,on=False),headers=self.headers)).status,422)
        self.ha.action.assert_not_awaited()
        self.assertEqual((await self.client.post(path,json=payload(climate,temperature=23.5),headers=self.headers)).status,200)
        self.ha.action.assert_awaited_with({'action':'climate.set_temperature','target':{'entity_id':'climate.kitchen'},'data':{'temperature':23.5}})
        self.assertEqual((await self.client.post(path,json=payload(scene,on=True),headers=self.headers)).status,200)
        self.ha.action.assert_awaited_with({'action':'scene.turn_on','target':{'entity_id':'scene.relax'},'data':{}})

    async def test_linked_brightness_uses_fresh_runtime_value_and_rejects_stale(self):
        c = component(); program, block = uid(), uid()
        c['brightnessBinding']=dict(source='runtime',entityID='',attribute='',programID=program,blockID=block,metric='number')
        doc=document(c)
        record=self.service.store.change(doc['id'],'save',request(document=doc))
        record=self.service.store.change(doc['id'],'publish',request(record))
        self.runtime.running[program]=True
        self.runtime.snapshots[program]={'observedAt':time.time(),'analogSignals':{block:30}}
        path='/dashboards/api/published/'+doc['id']+'/actions'
        payload=dict(componentID=c['id'],revision=record['revision'],requestID=uid(),on=True)
        await self.client.post(path,json=payload,headers=self.headers)
        self.ha.action.assert_awaited_once_with({'action':'light.turn_on','target':{'entity_id':'light.kitchen'},'data':{'brightness_pct':30}})
        self.runtime.snapshots[program]['observedAt']-=10
        payload['requestID']=uid()
        response=await self.client.post(path,json=payload,headers=self.headers)
        self.assertEqual((await response.json())['status'],'unconfirmed')
        self.ha.action.assert_awaited_once()

    async def test_uncertain_action_is_never_resent(self):
        self.ha.action.side_effect=TimeoutError()
        payload=dict(componentID=self.doc['pages'][0]['components'][0]['id'],revision=self.record['revision'],requestID=uid(),on=False)
        for _ in range(2):
            result=await (await self.client.post(self.path+'/actions',json=payload,headers=self.headers)).json()
            self.assertEqual(result['status'],'unconfirmed')
        self.ha.action.assert_awaited_once()
    async def test_unknown_stale_and_secret_values_never_become_valid(self):
        graph=self.doc['pages'][0]['components'][2]
        values=self.service.values(self.doc);self.assertTrue(values[graph['id']]['known'])
        self.ha.states['sensor.temperature']='unavailable'
        self.assertEqual(self.service.values(self.doc)[graph['id']]['reason'],'Entität nicht verfügbar')
        graph['binding']['entityID']='camera.entrance';graph['binding']['attribute']='access_token'
        self.assertNotIn('secret-camera-token',str(self.service.values(self.doc)))
        program,block=uid(),uid();graph['binding'].update(source='runtime',programID=program,blockID=block,metric='number')
        self.runtime.running[program.upper()]=True;self.runtime.snapshots[program.upper()]={'observedAt':time.time(),'analogSignals':{block.upper():42}}
        self.assertEqual(self.service.values(self.doc)[graph['id']]['value'],42)
        self.runtime.snapshots[program.upper()]['observedAt']-=10
        self.assertFalse(self.service.values(self.doc)[graph['id']]['known'])
    async def test_camera_fixed_target_auth_and_no_redirect_or_credentials_leak(self):
        seen=[]
        async def image(req):
            seen.append((req.path,req.headers.get('Authorization')))
            return web.Response(body=b'fake-jpeg-fixture',content_type='image/jpeg')
        upstream=web.Application();upstream.router.add_get('/api/camera_proxy/camera.entrance',image)
        async with TestServer(upstream) as ha:
            self.ha.base=str(ha.make_url('/api'));self.ha.session=ClientSession()
            data,mime=await self.service.camera_image('camera.entrance')
            self.assertEqual(data,b'fake-jpeg-fixture');self.assertEqual(mime,'image/jpeg')
            self.assertEqual(seen,[('/api/camera_proxy/camera.entrance','Bearer never-in-browser')])
            with self.assertRaises(DashboardError):await self.service.camera_image('https://evil/path')
            self.assertEqual(self.service.camera_count,0)
        c=self.doc['pages'][0]['components'][1]
        response=await self.client.get(self.path+'/camera/'+c['id']+'?revision=stale')
        self.assertEqual(response.status,409)
    async def test_shared_renderer_and_page_do_not_expose_keys(self):
        response=await self.client.get('/dashboards/');html=await response.text()
        self.assertEqual(response.status,200)
        for secret in ['never-in-browser','supervisor-secret','secret-camera-token']:self.assertNotIn(secret,html)
        self.assertIn("img-src 'self' data:",response.headers['Content-Security-Policy'])
        root=Path(__file__).parents[2]
        for name in ['renderer.css','renderer.js']:
            self.assertEqual((root/'Sources/NodivraDashboard/Resources'/name).read_bytes(),(root/'Runtime/server/dashboard_web'/name).read_bytes())
    async def test_unpublish_invalidates_values_media_and_actions(self):
        self.service.store.change(self.doc['id'],'unpublish',request(self.record))
        self.assertEqual((await self.client.get(self.path+'/values')).status,404)
        camera=self.doc['pages'][0]['components'][1]
        self.assertEqual((await self.client.get(self.path+'/camera/'+camera['id']+'?revision='+self.record['revision'])).status,404)
    async def test_camera_stream_relays_only_configured_camera_and_releases_slot(self):
        seen=[]
        async def stream(req):
            seen.append((req.path,req.headers.get('Authorization')))
            response=web.StreamResponse(headers={'Content-Type':'multipart/x-mixed-replace; boundary=frame'})
            await response.prepare(req)
            await response.write(b'--frame\r\nContent-Type: image/jpeg\r\nContent-Length: 4\r\n\r\ntest\r\n--frame--\r\n')
            await response.write_eof();return response
        upstream=web.Application();upstream.router.add_get('/api/camera_proxy_stream/camera.entrance',stream)
        async with TestServer(upstream) as ha:
            self.ha.base=str(ha.make_url('/api'));self.ha.session=ClientSession()
            camera=self.doc['pages'][0]['components'][1]
            result=await self.client.get(self.path+'/camera/'+camera['id']+'?revision='+self.record['revision']+'&entity=light.other')
            self.assertEqual(result.status,200);self.assertIn(b'\r\ntest\r\n',await result.read())
            self.assertEqual(seen,[('/api/camera_proxy_stream/camera.entrance','Bearer never-in-browser')])
            self.assertEqual(result.headers['Cache-Control'],'no-store')
            self.assertEqual(self.service.camera_count,0)
    async def test_camera_refuses_redirect_and_limits_parallel_streams(self):
        async def image(req):return web.Response(status=302,headers={'Location':'http://127.0.0.1:1/private'})
        upstream=web.Application();upstream.router.add_get('/api/camera_proxy/camera.entrance',image)
        async with TestServer(upstream) as ha:
            self.ha.base=str(ha.make_url('/api'));self.ha.session=ClientSession()
            with self.assertRaises(DashboardError):await self.service.camera_image('camera.entrance')
            self.assertEqual(self.service.camera_count,0)
            self.service.camera_count=4
            with self.assertRaises(DashboardError) as context:await self.service.camera_image('camera.entrance')
            self.assertEqual(context.exception.status,429)
    async def test_listing_and_history_do_not_repeat_large_assets(self):
        app=web.Application()
        self.service.routes(app)
        async with TestClient(TestServer(app)) as client:
            result=await (await client.get('/api/v1/dashboards')).json()
            self.assertEqual(result['dashboards'][0]['title'],'Mein Zuhause')
            self.assertNotIn('document',result['dashboards'][0])
            result=await (await client.get('/api/v1/dashboards/'+self.doc['id']+'/revisions')).json()
            self.assertEqual(result['revisions'][0]['revision'],self.record['revision'])
            self.assertNotIn('document',result['revisions'][0])
