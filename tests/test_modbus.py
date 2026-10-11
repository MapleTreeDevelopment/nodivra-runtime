"""Isolated Modbus servers only; never discovers or controls real equipment."""
import asyncio, copy, json, struct, sys, tempfile, time, unittest
from pathlib import Path
from unittest.mock import patch
SERVER=Path(__file__).resolve().parents[1]/'server'
if not SERVER.exists(): SERVER=Path(__file__).resolve().parents[1]/'nodivra_runtime/server'
sys.path.insert(0,str(SERVER))
from modbus_service import TCP, ModbusService, ModbusError, decode, profile_checked, sunspec, local_host
from aiohttp.test_utils import TestClient, TestServer
from aiohttp import web

def profile(): return dict(schemaVersion=1,id='test',name='Testgerät',points=[dict(id='temperature',name='Temperatur',address=10,function=3,type='int16',scale=.1,unit='°C')])

class ProfileTests(unittest.TestCase):
    def test_decode_orders_bits_and_scale(self):
        p=profile()['points'][0];self.assertEqual(decode(p,[65526]),-1)
        self.assertEqual(decode(dict(type='uint32',order='CDAB'),[2,1]),65538)
        self.assertEqual(decode(dict(type='uint16',order='BADC'),[0x0102]),0x0201)
        self.assertTrue(decode(dict(type='bool',bit=4),[16]))
        self.assertFalse(decode(dict(type='bool',bit=3),[16]))
        self.assertEqual(decode(dict(type='int16'),[150],65535),15)
    def test_invalid_nan_scale_and_sentinel(self):
        for p,w,sf in [(dict(type='float32'),[0x7fc0,0],None),(dict(type='uint16',invalid=[65535]),[65535],None),(dict(type='int16'),[1],32768)]:
            with self.assertRaises(ModbusError):decode(p,w,sf)
    def test_profiles_reject_writes_bad_geometry_and_duplicate_ids(self):
        for key,value in [('function',6),('address',65536),('type','python'),('scale',float('inf')),('order','bad')]:
            p=profile();p['points'][0][key]=value
            with self.assertRaises(ModbusError):profile_checked(p)
        p=profile();p['points']*=2
        with self.assertRaises(ModbusError):profile_checked(p)
    def test_point_keys_are_engine_compatible_and_collisions_rejected(self):
        self.assertEqual(ModbusService.key('a','PV-Power'),'nodivra_modbus.a_pv_power')
        p=profile();p['points'][0]['id']='PV-Power';other=copy.deepcopy(p['points'][0]);other['id']='pv_power';p['points'].append(other)
        with self.assertRaises(ModbusError):profile_checked(p)

    def test_private_network_only(self):
        self.assertEqual(local_host('192.168.1.5'),'192.168.1.5')
        for v in ['8.8.8.8','127.0.0.1','169.254.169.254','example.com','224.0.0.1']:
            with self.assertRaises(ValueError):local_host(v)

class TCPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls=[];self.bad=False;self.disconnect=False;self.sockets=set();self.reg={10:215,40000:0x5375,40001:0x6e53,40002:1,40003:66,40070:103,40071:50,40122:65535,40123:0}
        raw=b'TestMaker'.ljust(32,b'\0')+b'TestModel'.ljust(32,b'\0')+bytes(68)
        for i,w in enumerate(struct.unpack('>'+'H'*66,raw)):self.reg[40004+i]=w
        # model 103 W at model offset 14; W_SF at 15.
        self.reg[40084]=1234;self.reg[40085]=65535
        self.server=await asyncio.start_server(self.serve,'127.0.0.1',0)
        self.port=self.server.sockets[0].getsockname()[1];self.client=TCP('127.0.0.1',self.port,1)
    async def asyncTearDown(self):
        await self.client.close();self.server.close();await self.server.wait_closed()
        for w in self.sockets.copy():w.close()
    async def serve(self,r,w):
        self.sockets.add(w)
        try:
            while True:
                tid,proto,n,unit=struct.unpack('>HHHB',await r.readexactly(7));p=await r.readexactly(n-1);fc=p[0];self.calls.append(fc)
                if self.disconnect:return
                if fc==43:
                    body=bytes([43,14,1,1,0,0,2,0,4])+b'Test'+bytes([1,5])+b'Model'
                elif fc in (3,4):
                    a,count=struct.unpack('>HH',p[1:]);body=bytes([fc,count*2])+b''.join(struct.pack('>H',self.reg.get(a+i,0)) for i in range(count))
                elif fc in (1,2):body=bytes([fc,1,1])
                else:body=bytes([fc|128,1])
                w.write(struct.pack('>HHHB',tid+int(self.bad),0,len(body)+1,unit)+body);await w.drain()
        except (asyncio.IncompleteReadError,ConnectionError):pass
        finally:self.sockets.discard(w);w.close()
    async def test_identification_and_strict_transaction(self):
        self.assertEqual((await self.client.identify())['0'],'Test')
        self.assertEqual(await self.client.read(3,10,1),[215])
        self.bad=True
        with self.assertRaises(ModbusError):await self.client.read(3,10,1)
    async def test_write_codes_never_sent(self):
        with self.assertRaises(ModbusError):await self.client.request(6,b'')
        self.assertEqual(self.calls,[])
    async def test_sunspec_chain_model_offsets_scale(self):
        result=await sunspec(self.client)
        self.assertEqual(result['identity']['manufacturer'],'TestMaker')
        p=profile_checked(result['profile']);w=next(x for x in p['points'] if x['id'].endswith('_W'))
        self.assertEqual(w['address'],40084);self.assertEqual(w['sfAddress'],40085)
        self.assertEqual(decode(w,await self.client.read(3,w['address'],1),(await self.client.read(3,w['sfAddress'],1))[0]),123.4)
    async def test_unknown_sunspec_models_not_guessed(self):
        self.reg[40070]=999
        r=await sunspec(self.client);self.assertFalse(r['models'][1]['supported']);self.assertEqual(r['profile']['points'],[])
    async def test_poll_stale_values_and_persistence(self):
        with tempfile.TemporaryDirectory() as path:
            service=ModbusService(path)
            d=dict(id='a',name='Test',host='127.0.0.1',port=self.port,unit=1,interval=1,profile=profile())
            service.devices=[d];service.save('devices',[d]);await service.start()
            for _ in range(30):
                if service.values():break
                await asyncio.sleep(.05)
            key='nodivra_modbus.a_temperature';self.assertEqual(service.values()[key],'21.5')
            service.samples[key]['_at']-=100;self.assertNotIn(key,service.values());self.assertEqual(service.points()[0]['quality'],'stale')
            await service.close();new=ModbusService(path);self.assertEqual(len(new.devices),1);self.assertEqual(new.values(),{});await new.close()
    async def test_peer_closes_connection_invalidates_values_without_killing_poll(self):
        with tempfile.TemporaryDirectory() as path:
            service=ModbusService(path)
            d=dict(id='a',name='Test',host='127.0.0.1',port=self.port,unit=1,interval=1,profile=profile())
            service.devices=[d];await service.start()
            for _ in range(30):
                if service.values():break
                await asyncio.sleep(.05)
            self.assertTrue(service.values());self.disconnect=True
            for _ in range(40):
                if not service.values():break
                await asyncio.sleep(.05)
            self.assertEqual(service.values(),{});self.assertFalse(service.tasks['a'].done())
            self.assertEqual(service.points()[0]['quality'],'unavailable');await service.close()

    async def test_scan_is_read_only_and_has_progress(self):
        with tempfile.TemporaryDirectory() as path:
            s=ModbusService(path);s.scan=dict(status='running',completed=0,total=1,devices=[])
            await s.run_scan(['127.0.0.1'],self.port,[1]);self.assertEqual(s.scan['status'],'complete');self.assertEqual(s.scan['completed'],1)
            self.assertEqual(len(s.scan['devices']),1);self.assertTrue(all(c in [1,2,3,4,43] for c in self.calls));await s.close()
    async def test_api_limits_and_import(self):
        with tempfile.TemporaryDirectory() as path:
            s=ModbusService(path)
            class Request:
                def __init__(self,data):self.data=data
                async def json(self):return self.data
            with self.assertRaises(ModbusError):await s.begin_scan(Request(dict(network='192.168.0.0/16')))
            with self.assertRaises(ModbusError):await s.begin_scan(Request(dict(network='8.8.8.8/32')))
            await s.import_profile(Request(profile()));self.assertEqual(len(s.profiles),1)
            await s.close()
