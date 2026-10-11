"""Read-only Modbus TCP, bounded discovery and declarative device profiles.
No write function codes, automatic network scans or executable profile content.
"""
import asyncio
import contextlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import struct
import time
import uuid
from aiohttp import web, ClientSession, ClientTimeout, ClientError

class ModbusError(ValueError): pass
class ModbusException(ModbusError):
    def __init__(self, code):
        self.code = code
        super().__init__('Modbus-Ausnahme '+str(code))

def require(ok, message='Ungültige Modbus-Konfiguration.'):
    if not ok: raise ModbusError(message)

def integer(v, low, high): return type(v) is int and low <= v <= high

def local_host(value):
    ip = ipaddress.IPv4Address(value)
    require(any(ip in ipaddress.ip_network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')), 'Bitte eine private IPv4-Adresse verwenden.')
    return str(ip)

# Private host networks come from the Supervisor, not the add-on's Docker subnet.
def supervisor_networks(data):
    networks=[]
    docker=data.get('docker',{}).get('address')
    docker=ipaddress.ip_network(docker,strict=False) if docker else None
    for interface in data.get('interfaces',[]):
        if not interface.get('enabled') or not interface.get('connected'): continue
        if interface.get('type') not in ('ethernet','wireless','vlan'): continue
        ipv4=interface.get('ipv4') or {}
        addresses=ipv4.get('address',ipv4.get('ip_address',[]))
        if isinstance(addresses,str): addresses=[addresses]
        for address in addresses:
            try:
                net=ipaddress.ip_interface(address).network
                local_host(str(net.network_address));local_host(str(net.broadcast_address))
            except ValueError: continue
            if docker and net.overlaps(docker): continue
            if net not in networks: networks.append(net)
    require(networks,'Kein privates IPv4-Netz erkannt. Bitte die erweiterte Suche verwenden.')
    require(sum(n.num_addresses for n in networks)<=4096,'Erkannte Netze sind zu groß (maximal 4096 Adressen). Bitte einen Bereich in der erweiterten Suche wählen.')
    return list(ipaddress.collapse_addresses(networks))

async def discover_networks():
    token=os.environ.get('SUPERVISOR_TOKEN')
    require(token,'Automatische Netzerkennung benötigt die Home-Assistant-Runtime. Bitte die erweiterte Suche verwenden.')
    try:
        async with ClientSession(timeout=ClientTimeout(total=5)) as session:
            async with session.get('http://supervisor/network/info',headers={'Authorization':'Bearer '+token},allow_redirects=False) as response:
                require(response.status==200,'Netzerkennung nicht verfügbar. Runtime aktualisieren oder erweiterte Suche verwenden.')
                body=await response.json()
                require(body.get('result')=='ok','Home Assistant konnte die Netze nicht ermitteln.')
                return supervisor_networks(body['data'])
    except (ClientError,asyncio.TimeoutError,KeyError) as e:
        raise ModbusError('Netzerkennung fehlgeschlagen. Bitte die erweiterte Suche verwenden.') from e

AUTO_UNITS = [1,255,0]+list(range(2,248))

TYPES = {'uint16':('>H',1), 'int16':('>h',1), 'uint32':('>I',2), 'int32':('>i',2), 'float32':('>f',2), 'uint64':('>Q',4), 'int64':('>q',4), 'float64':('>d',4), 'bool':('>H',1)}

def profile_checked(p):
    require(isinstance(p,dict) and p.get('schemaVersion') == 1)
    require(isinstance(p.get('id'),str) and re.fullmatch(r'[a-zA-Z0-9_-]{1,64}',p['id']))
    require(isinstance(p.get('name'),str) and 0 < len(p['name']) <= 120)
    require(isinstance(p.get('points'),list) and 0 < len(p['points']) <= 128)
    if 'match' in p:
        m=p['match'];require(isinstance(m,dict) and {'manufacturer','model'} <= set(m) <= {'manufacturer','model','version'} and all(isinstance(v,str) and 0<len(v)<=120 for v in m.values()))
    ids=set()
    for q in p['points']:
        require(isinstance(q,dict) and isinstance(q.get('id'),str) and re.fullmatch(r'[a-zA-Z0-9_-]{1,80}',q['id']) and q['id'].lower().replace('-','_') not in ids);ids.add(q['id'].lower().replace('-','_'))
        require(isinstance(q.get('name'),str) and 0 < len(q['name']) <= 120)
        require(q.get('type') in TYPES and type(q.get('function')) is int and q.get('function') in (1,2,3,4))
        require(integer(q.get('address'),0,65535) and q['address']+TYPES[q['type']][1] <= 65536)
        require(q['function'] not in (1,2) or (q['type']=='bool' and 'bit' not in q))
        require(q.get('order','ABCD') in ('ABCD','BADC','CDAB','DCBA'))
        require(isinstance(q.get('unit',''),str) and len(q.get('unit','')) <= 32)
        for key,default in [('scale',1),('offset',0)]:
            v=q.get(key,default); require(type(v) in (int,float) and math.isfinite(v) and abs(v)<=1e12)
        require('bit' not in q or (q['type']=='bool' and integer(q['bit'],0,15)))
        require('sfAddress' not in q or integer(q['sfAddress'],0,65535))
        require('invalid' not in q or (isinstance(q['invalid'],list) and len(q['invalid'])<=8 and all(type(v) in (int,float) and math.isfinite(v) for v in q['invalid'])))
    return p

class TCP:
    def __init__(self,host,port=502,unit=1): self.host=host;self.port=port;self.unit=unit;self.reader=None;self.writer=None;self.transaction=0
    async def close(self):
        if self.writer:
            self.writer.close()
            with contextlib.suppress(Exception): await asyncio.wait_for(self.writer.wait_closed(),1)
        self.writer=None;self.reader=None
    async def request(self,fc,payload):
        require(fc in (1,2,3,4,43), 'Nur lesende Modbus-Funktionen erlaubt.')
        try:
            async def exchange():
                if self.writer is None: self.reader,self.writer=await asyncio.open_connection(self.host,self.port)
                self.transaction=(self.transaction+1)%65536
                self.writer.write(struct.pack('>HHHBB',self.transaction,0,len(payload)+2,self.unit,fc)+payload);await self.writer.drain()
                tid,protocol,length,unit=struct.unpack('>HHHB',await self.reader.readexactly(7))
                require(tid==self.transaction and protocol==0 and unit==self.unit and 2<=length<=254,'Ungültige Modbus-Antwort.')
                pdu=await self.reader.readexactly(length-1)
                if pdu[0]==fc|128:
                    require(len(pdu)==2)
                    raise ModbusException(pdu[1])
                require(pdu[0]==fc,'Unerwarteter Funktionscode.')
                return pdu[1:]
            return await asyncio.wait_for(exchange(),2)
        except BaseException:
            await self.close();raise
    async def read(self,fc,address,count):
        require(integer(address,0,65535) and integer(count,1,125) and address+count<=65536)
        data=await self.request(fc,struct.pack('>HH',address,count))
        size=(count+7)//8 if fc in (1,2) else count*2
        require(len(data)==size+1 and data[0]==size,'Ungültige Registerlänge.')
        if fc in (1,2): return [(data[1+i//8]>>(i%8))&1 for i in range(count)]
        return list(struct.unpack('>'+'H'*count,data[1:]))
    async def identify(self):
        data=await self.request(43,bytes([14,1,0]))
        require(len(data)>=6 and data[0]==14 and data[1]==1)
        result={};cursor=6
        for _ in range(data[5]):
            require(cursor+2<=len(data));key,size=data[cursor:cursor+2];cursor+=2
            require(cursor+size<=len(data));result[str(key)]=data[cursor:cursor+size].decode('utf-8','replace');cursor+=size
        return result

def decode(q,words,sf=None):
    raw=b''.join(struct.pack('>H',w) for w in words)
    order=q.get('order','ABCD')
    if order in ('CDAB','DCBA'): raw=b''.join(raw[i:i+2] for i in range(len(raw)-2,-1,-2))
    if order in ('BADC','DCBA'): raw=b''.join(raw[i:i+2][::-1] for i in range(0,len(raw),2))
    value=struct.unpack(TYPES[q['type']][0],raw)[0]
    require(math.isfinite(value) and value not in q.get('invalid',[]),'Messwert nicht verfügbar.')
    if q['type']=='bool': return bool(value & (1<<q['bit'])) if 'bit' in q else bool(value)
    if sf is not None:
        sf=struct.unpack('>h',struct.pack('>H',sf))[0];require(-10<=sf<=10,'Skalierungsfaktor nicht verfügbar.')
    result=value*q.get('scale',1)*(10**sf if sf is not None else 1)+q.get('offset',0)
    require(math.isfinite(result),'Messwert außerhalb des Zahlenbereichs.')
    return result

async def sunspec(client):
    base=None
    for candidate in (40000,0,50000):
        try:
            if await client.read(3,candidate,2)==[0x5375,0x6e53]:base=candidate;break
        except (ModbusError,OSError,asyncio.IncompleteReadError,asyncio.TimeoutError): pass
    if base is None:return None
    address=base+2;models=[];points=[];identity={};occurrences={}
    for _ in range(64):
        mid,length=await client.read(3,address,2)
        if mid==65535: break
        require(1<=length<=2048 and address+2+length<=65535,'Ungültige SunSpec-Modellkette.')
        path=Path(__file__).with_name('sunspec')/('model_%s.json'%mid)
        models.append(dict(id=mid,address=address,length=length,supported=path.exists()))
        if mid==1 and length>=64:
            words=await client.read(3,address+2,64)
            raw=b''.join(struct.pack('>H',w) for w in words)
            identity={key:raw[a:b].decode('utf-8','replace').strip('\x00 ') for key,a,b in [('manufacturer',0,32),('model',32,64),('version',80,96),('serial',96,128)]}
        elif path.exists():
            definitions=json.loads(path.read_text())['group']['points'];offset=0;offsets={}
            for d in definitions: offsets[d['name']]=offset;offset+=d['size']
            require(offset<=length+2,'SunSpec-Modell ist kürzer als seine Definition.')
            occurrence=occurrences.get(mid,0);occurrences[mid]=occurrence+1
            for d in definitions:
                dt={'enum16':'uint16','bitfield16':'uint16','bitfield32':'uint32','acc32':'uint32'}.get(d['type'],d['type'])
                if dt not in TYPES or d['name'] in ('ID','L'):continue
                if len(points)>=128:break
                q=dict(id=f'm{mid}_{occurrence}_{d["name"]}',name=d.get('label',d['name']),type=dt,function=3,address=address+offsets[d['name']],unit=d.get('units',''))
                if d.get('sf') in offsets:q['sfAddress']=address+offsets[d['sf']]
                invalid={'int16':-32768,'uint16':65535,'int32':-2147483648,'uint32':4294967295}
                if dt in invalid:q['invalid']=[0 if d['type']=='acc32' else invalid[dt]]
                points.append(q)
        address+=length+2
    else: raise ModbusError('Zu viele SunSpec-Modelle.')
    return dict(identity=identity,models=models,profile=dict(schemaVersion=1,id='sunspec',name='SunSpec · '+identity.get('model','Gerät'),points=points))

class ModbusService:
    def __init__(self,path):
        self.db=sqlite3.connect(Path(path)/'modbus.sqlite')
        self.db.execute('CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL)');self.db.commit()
        self.devices=self.get('devices',[]);self.profiles=self.get('profiles',[]);self.samples={};self.tasks={};self.scan_task=None;self.scan=None
    def get(self,key,default):
        row=self.db.execute('SELECT value FROM config WHERE key=?',(key,)).fetchone();return json.loads(row[0]) if row else default
    def save(self,key,value):
        self.db.execute('INSERT OR REPLACE INTO config VALUES (?,?)',(key,json.dumps(value,allow_nan=False)));self.db.commit()
    async def start(self):
        for d in self.devices:self.tasks[d['id']]=asyncio.create_task(self.poll(d))
    async def close(self):
        tasks=list(self.tasks.values())+([self.scan_task] if self.scan_task else [])
        for t in tasks:t.cancel()
        await asyncio.gather(*tasks,return_exceptions=True);self.db.close()
    @staticmethod
    def key(device,point):return 'nodivra_modbus.'+device+'_'+point.lower().replace('-','_')
    def values(self):
        now=time.monotonic();out={}
        for d in self.devices:
            for p in d['profile']['points']:
                s=self.samples.get(self.key(d['id'],p['id']))
                if s and s['quality']=='valid' and now-s['_at']<=max(5,d['interval']*3,len(d['profile']['points'])*.2+d['interval']):
                    v=s['value'];out[self.key(d['id'],p['id'])]=('on' if v else 'off') if type(v) is bool else str(v)
        return out
    def points(self):
        valid=self.values();out=[]
        for d in self.devices:
            for p in d['profile']['points']:
                key=self.key(d['id'],p['id']);s=self.samples.get(key,{})
                out.append(dict(id=key,name=p['name'],device=d['name'],unit=p.get('unit',''),kind='digital' if p['type']=='bool' else 'analog',quality='valid' if key in valid else s.get('quality','waiting') if s.get('quality')!='valid' else 'stale',value=s.get('value'),updated=s.get('updated'),error=s.get('error'),address=p['address']))
        return out
    async def poll(self,d):
        client=TCP(d['host'],d['port'],d['unit'])
        try:
            while True:
                failed=False;scale_cache={}
                for p in d['profile']['points']:
                    key=self.key(d['id'],p['id'])
                    try:
                        words=await client.read(p['function'],p['address'],TYPES[p['type']][1])
                        sf=None
                        if 'sfAddress' in p:
                            if p['sfAddress'] not in scale_cache:scale_cache[p['sfAddress']]=(await client.read(3,p['sfAddress'],1))[0]
                            sf=scale_cache[p['sfAddress']]
                        self.samples[key]=dict(value=decode(p,words,sf),quality='valid',updated=time.time(),_at=time.monotonic())
                    except (OSError,asyncio.IncompleteReadError,asyncio.TimeoutError) as e:
                        failed=True
                        for q in d['profile']['points']:self.samples[self.key(d['id'],q['id'])]=dict(quality='unavailable',error=str(e)[:160] or 'Gerät antwortet nicht.')
                        break
                    except ModbusError as e:
                        failed=True;self.samples[key]=dict(quality='unavailable',error=str(e)[:160])
                    await asyncio.sleep(.05)
                await asyncio.sleep(max(d['interval'],5 if failed else 0))
        finally:await client.close()
    async def inspect_unit(self,host,port,unit):
        c=TCP(host,port,unit)
        identity={};responded=False;sun=None
        try:
            try: identity=await c.identify();responded=True
            except ModbusException as e:
                # Gateways report these when no downstream unit is reachable.
                if e.code in (10,11): return None
                responded=True
            except (ModbusError,OSError,asyncio.IncompleteReadError,asyncio.TimeoutError): pass
            if not responded:
                try: await c.read(3,0,1);responded=True
                except ModbusException as e: responded=e.code not in (10,11)
                except (ModbusError,OSError,asyncio.IncompleteReadError,asyncio.TimeoutError): pass
            if not responded: return None
            try: sun=await sunspec(c)
            except (ModbusError,OSError,asyncio.IncompleteReadError,asyncio.TimeoutError): pass
            return dict(host=host,port=port,unit=unit,identity=identity,sunspec=sun)
        finally: await c.close()

    async def run_scan(self,hosts,port,units):
        # Bounded workers; units are sequential per host to protect small PLCs.
        sem=asyncio.Semaphore(4)
        async def probe(host):
            async with sem:
                writer=None
                try:
                    _,writer=await asyncio.wait_for(asyncio.open_connection(host,port),1)
                except (OSError,asyncio.TimeoutError):
                    self.scan['completed']+=len(units);return
                finally:
                    if writer:
                        writer.close()
                        with contextlib.suppress(Exception): await asyncio.wait_for(writer.wait_closed(),1)
                for unit in units:
                    try:
                        result=await asyncio.wait_for(self.inspect_unit(host,port,unit),20)
                        if result:self.scan['devices'].append(result)
                    except (ModbusError,OSError,asyncio.IncompleteReadError,asyncio.TimeoutError): pass
                    self.scan['completed']+=1
                    await asyncio.sleep(.05)
        workers=[asyncio.create_task(probe(h)) for h in hosts]
        try:
            await asyncio.gather(*workers)
            self.scan['status']='complete'
        except asyncio.CancelledError:
            self.scan['status']='cancelled';raise
        except Exception:
            self.scan['status']='failed';self.scan['error']='Suche fehlgeschlagen. Bereits gefundene Geräte bleiben verfügbar.'
        finally:
            for task in workers:
                if not task.done():task.cancel()
            await asyncio.gather(*workers,return_exceptions=True)
    def routes(self,app):
        app.router.add_get('/api/v1/modbus',self.state)
        app.router.add_post('/api/v1/modbus/scan',self.begin_scan)
        app.router.add_delete('/api/v1/modbus/scan',self.cancel_scan)
        app.router.add_post('/api/v1/modbus/profiles',self.import_profile)
        app.router.add_post('/api/v1/modbus/devices',self.add_device)
        app.router.add_delete('/api/v1/modbus/devices/{id}',self.delete_device)
    async def state(self,r):return web.json_response(dict(devices=self.devices,profiles=self.profiles,points=self.points(),scan=self.scan))
    async def begin_scan(self,r):
        require(not self.scan_task or self.scan_task.done(),'Eine Suche läuft bereits.')
        data=await r.json()
        automatic=data.get('automatic',False)
        require(type(automatic) is bool)
        if automatic:
            networks=await discover_networks()
            # Net detection awaits IO; a second request may have started a scan.
            require(not self.scan_task or self.scan_task.done(),'Eine Suche läuft bereits.')
        else:
            network=ipaddress.ip_network(data['network'],strict=False)
            require(network.version==4 and network.num_addresses<=256,'Maximal ein /24-Netz pro manueller Suche.')
            networks=[network]
        hosts=list(dict.fromkeys(local_host(str(h)) for n in networks for h in n.hosts()))
        units=data.get('units','auto' if automatic else [1]);port=data.get('port',502)
        if units=='auto':units=AUTO_UNITS
        require(integer(port,1,65535) and isinstance(units,list) and 1<=len(units)<=256 and all(integer(u,0,255) for u in units))
        units=list(dict.fromkeys(units))
        self.scan=dict(status='running',completed=0,total=len(hosts)*len(units),devices=[],networks=[str(n) for n in networks],unitCount=len(units))
        self.scan_task=asyncio.create_task(self.run_scan(hosts,port,units));return web.json_response(self.scan)
    async def cancel_scan(self,r):
        if self.scan_task and not self.scan_task.done():self.scan_task.cancel();await asyncio.gather(self.scan_task,return_exceptions=True)
        return web.json_response({'ok':True})
    async def import_profile(self,r):
        p=profile_checked(await r.json());require(len(self.profiles)<100 or any(x['id']==p['id'] for x in self.profiles))
        self.profiles=[x for x in self.profiles if x['id']!=p['id']]+[p];self.save('profiles',self.profiles);return web.json_response({'ok':True})
    async def add_device(self,r):
        d=await r.json();d['host']=local_host(d['host']);require(integer(d.get('port'),1,65535) and integer(d.get('unit'),0,255))
        require(isinstance(d.get('name'),str) and 0<len(d['name'])<=120 and integer(d.get('interval'),1,3600))
        p=profile_checked(d['profile']);require(len(self.devices)<32,'Maximal 32 Geräte.')
        require(not any((x['host'],x['port'],x['unit'])==(d['host'],d['port'],d['unit']) for x in self.devices),'Gerät bereits vorhanden.')
        d={k:d[k] for k in ('host','port','unit','name','interval')};d['profile']=p;d['id']=uuid.uuid4().hex
        self.devices.append(d);self.save('devices',self.devices);self.tasks[d['id']]=asyncio.create_task(self.poll(d));return web.json_response(d)
    async def delete_device(self,r):
        identity=r.match_info['id'];task=self.tasks.pop(identity,None)
        if task:task.cancel();await asyncio.gather(task,return_exceptions=True)
        self.devices=[d for d in self.devices if d['id']!=identity];self.save('devices',self.devices)
        self.samples={k:v for k,v in self.samples.items() if not k.startswith('nodivra_modbus.'+identity+'_')}
        return web.json_response({'ok':True})
