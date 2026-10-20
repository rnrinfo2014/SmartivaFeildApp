"""Real PostgreSQL integration suite. Uses only the explicitly supplied disposable DB."""
import hashlib
import os
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, func
from sqlalchemy.orm import Session
from app import models as m
from app.config import Settings
from app.main import create_app
from app.manage import SERVER_TABLES

URL=os.getenv('SMARTIVA_TEST_DATABASE_URL')
def uid(): return str(uuid4())

@unittest.skipUnless(URL,'Set SMARTIVA_TEST_DATABASE_URL to a disposable PostgreSQL database')
class SyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine=create_engine(URL,pool_pre_ping=True)
        if cls.engine.dialect.name!='postgresql': raise RuntimeError('PostgreSQL required')
        m.Base.metadata.create_all(cls.engine,tables=SERVER_TABLES)
    @classmethod
    def tearDownClass(cls): cls.engine.dispose()
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.token='test-'+uid();self.other='test-'+uid();self.internal='internal-only-'+uid()
        self.user=uid();self.device=uid();self.otheruser=uid()
        with Session(self.engine) as db,db.begin():
            db.add_all([m.Technician(id=self.user,name=uid(),can_create_sites=True),m.Technician(id=self.otheruser,name=uid(),can_create_sites=False)])
            db.flush()
            db.add_all([m.DeviceAccess(id=self.device,technician_id=self.user,label='test',token_hash=hashlib.sha256(self.token.encode()).hexdigest()),m.DeviceAccess(id=uid(),technician_id=self.otheruser,label='other',token_hash=hashlib.sha256(self.other.encode()).hexdigest())])
        config=Settings(api_token=self.internal,database_url=URL,audio_storage_path=self.tmp.name)
        self.client=TestClient(create_app(config));self.client.__enter__()
        self.headers={'Authorization':f'Bearer {self.token}'}
        self.site=uid()
    def tearDown(self): self.client.__exit__(None,None,None);self.tmp.cleanup()
    def mutation(self,table='sites',id=None,version=0,operation='create',payload=None):
        return dict(operation_id=uid(),site_id=self.site,entity_type=table,entity_id=id or self.site,operation=operation,base_version=version,payload=payload or {'name':'Yogasree Textiles'})
    def push(self,body,headers=None): return self.client.post('/api/v1/sync/push',json=body,headers=headers or self.headers)
    def create_site(self):
        response=self.push(self.mutation());self.assertEqual(response.status_code,200,response.text);return response.json()['record']
    def test_device_can_request_text_and_audio_ai_for_its_site(self):
        from app.ai.contracts import ExtractedData
        class Provider:
            audio_seen = False
            async def transcribe(provider, audio, mime, language):
                provider.audio_seen = True
                return 'Dahua 16 channel NVR one, 32 channel NVR one'
            async def extract(provider, text, context):
                return ExtractedData.model_validate({'assets':[
                    {'ref':'nvr16','asset_type':'NVR','brand':'Dahua','channel_capacity':16},
                    {'ref':'nvr32','asset_type':'NVR','brand':'Dahua','channel_capacity':32}]})
        provider = Provider()
        self.client.app.state.provider = provider
        self.create_site()
        endpoint = '/api/v1/ai/site-briefing'
        response = self.client.post(endpoint, headers=self.headers,
            json={'site_id':self.site,'text':'Dahua 16 channel NVR one, 32 channel NVR one'})
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(response.json()['site_id'],self.site)
        self.assertEqual([a['channel_capacity'] for a in response.json()['extracted_data']['assets']],[16,32])
        self.assertTrue(response.json()['next_question_tamil'])
        import json
        response = self.client.post(endpoint, headers=self.headers,
            files={'audio':('briefing.m4a',b'transport-only-audio','audio/mp4')},
            data={'metadata':json.dumps({'site_id':self.site,'language':'ta'})})
        self.assertEqual(response.status_code,200,response.text)
        self.assertTrue(provider.audio_seen)
        # Authorization must run before a provider receives a private briefing.
        self.assertEqual(self.client.post(endpoint,headers={'Authorization':f'Bearer {self.other}'},
            json={'site_id':self.site,'text':'private briefing'}).status_code,403)
        self.assertEqual(self.client.post(endpoint,headers=self.headers,
            json={'text':'missing site'}).status_code,422)

    def test_readiness_checks_keys_database_schema_and_audio_storage(self):
        from pydantic import SecretStr
        self.assertEqual(self.client.get('/healthz').status_code,200)
        response = self.client.get('/readyz')
        self.assertEqual(response.status_code,503)
        self.assertEqual(response.json(),{'status':'not_ready'})
        config = self.client.app.state.settings
        config.gemini_api_key = SecretStr('test-only-not-a-real-key')
        config.groq_api_key = SecretStr('test-only-not-a-real-key')
        self.assertEqual(self.client.get('/readyz').json(),{'status':'ready'})
        blocked = Path(self.tmp.name)/'file-not-directory'
        blocked.write_text('not a directory')
        config.audio_storage_path = str(blocked)
        self.assertEqual(self.client.get('/readyz').status_code,503)
        config.audio_storage_path = self.tmp.name
        config.ai_provider = 'groq'
        config.gemini_api_key = None
        self.assertEqual(self.client.get('/readyz').status_code,200)

    def test_receipt_replay_and_changed_request_rejected(self):
        body=self.mutation();first=self.push(body);again=self.push(body)
        self.assertEqual(first.status_code,200,first.text);self.assertEqual(first.json(),again.json())
        body['payload']['name']='Modified';self.assertEqual(self.push(body).status_code,409)
        with Session(self.engine) as db:
            self.assertEqual(db.get(m.Site,self.site).version,1)
            self.assertEqual(db.get(m.SiteSyncHead,self.site).revision,1)
    def test_concurrent_updates_conflict_and_conflict_receipt_stable(self):
        self.create_site()
        bodies=[self.mutation(version=1,operation='update',payload={'name':name}) for name in ['A','B']]
        with ThreadPoolExecutor(2) as pool: responses=list(pool.map(self.push,bodies))
        self.assertEqual(sorted(r.status_code for r in responses),[200,409])
        loser=next(i for i,r in enumerate(responses) if r.status_code==409)
        self.assertEqual(self.push(bodies[loser]).json(),responses[loser].json())
        self.assertEqual(responses[loser].json()['current']['version'],2)
    def test_auth_scope_readonly_and_revocation(self):
        self.create_site()
        for token,status in [(self.internal,401),(self.other,403)]:
            response=self.client.get(f'/api/v1/sites/{self.site}/changes',headers={'Authorization':f'Bearer {token}'})
            self.assertEqual(response.status_code,status,response.text)
        self.assertEqual(self.client.get('/api/v1/sync/me').status_code,401)
        with Session(self.engine) as db,db.begin(): db.add(m.SiteGrant(site_id=self.site,technician_id=self.otheruser,can_write=False))
        other={'Authorization':f'Bearer {self.other}'}
        self.assertEqual(self.client.get(f'/api/v1/sites/{self.site}/changes',headers=other).status_code,200)
        self.assertEqual(self.push(self.mutation(version=1,operation='update'),other).status_code,403)
        with Session(self.engine) as db,db.begin(): db.get(m.DeviceAccess,self.device).revoked=True
        self.assertEqual(self.client.get('/api/v1/sync/me',headers=self.headers).status_code,401)
    def test_pagination_watermark_and_cascaded_tombstones(self):
        self.create_site();floor=uid();zone=uid();asset=uid();camera=uid()
        for table,id,payload in [('floors',floor,{'name':'Ground','level':0}),('floors_and_zones',zone,{'floor_id':floor,'zone_name':'Office'}),('assets',asset,{'asset_type':'NVR','zone_id':zone,'channel_capacity':64}),('cameras',camera,{'nvr_id':asset,'status':'unknown','camera_type':'IP','channel_no':1})]:
            r=self.push(self.mutation(table,id,payload=payload));self.assertEqual(r.status_code,200,r.text)
        first=self.client.get(f'/api/v1/sites/{self.site}/changes?limit=2',headers=self.headers).json()
        self.assertEqual(first['cursor'],2);self.assertEqual(first['through'],5)
        deleted=self.push(self.mutation('floors',floor,1,'delete',{}));self.assertEqual(deleted.status_code,200,deleted.text)
        frozen=self.client.get(f'/api/v1/sites/{self.site}/changes?after=2&through=5',headers=self.headers).json()
        self.assertEqual(frozen['cursor'],5);self.assertFalse(frozen['has_more'])
        page=self.client.get(f'/api/v1/sites/{self.site}/changes?after=5',headers=self.headers).json()
        self.assertEqual({c['entity_type'] for c in page['changes']},{'floors','floors_and_zones','assets','cameras'})
        self.assertTrue(all(c['record']['deleted_at'] for c in page['changes']))
        r=self.push(self.mutation('cameras',uid(),payload={'nvr_id':asset,'status':'unknown'}));self.assertEqual(r.status_code,409,r.text)
    def test_voice_durable_hash_idempotency_and_transcript(self):
        self.create_site();voice=uid();data=b'fake audio bytes for transport tests';digest=hashlib.sha256(data).hexdigest()
        path=f'/api/v1/sites/{self.site}/voice/{voice}'
        headers={**self.headers,'Content-Type':'audio/mp4','X-Audio-SHA256':digest}
        response=self.client.put(path,content=data,headers=headers);self.assertEqual(response.status_code,200,response.text)
        record=response.json()['record'];self.assertNotIn('local_file_ref',record)
        self.assertEqual(self.client.put(path,content=data,headers=headers).json(),response.json())
        self.assertEqual(self.client.get(path,headers=self.headers).content,data)
        self.assertEqual((Path(self.tmp.name)/record['object_key']).read_bytes(),data)
        mismatch=self.client.put(path,content=b'wrong',headers=headers);self.assertEqual(mismatch.status_code,422)
        r=self.push(self.mutation('voice_notes',voice,1,'update',{**record,'transcript':'Ground floor-la NVR irukku','processing_status':'complete'}))
        self.assertEqual(r.status_code,200,r.text);self.assertEqual(r.json()['record']['version'],2)
        with Session(self.engine) as db:self.assertEqual(db.get(m.SiteSyncHead,self.site).revision,3)
    def test_cross_site_credentials_and_invalid_topology_rejected(self):
        self.create_site()
        self.assertEqual(self.push(self.mutation('assets',uid(),payload={'asset_type':'NVR','password':'must-not-store'})).status_code,422)
        self.assertEqual(self.push(self.mutation('assets',uid(),payload={'asset_type':'NVR','extra':{'username':'admin'}})).status_code,422)
        self.assertEqual(self.push(self.mutation('assets',uid(),payload={'asset_type':'NVR','zone_id':uid()})).status_code,409)
        self.assertEqual(self.push(self.mutation(payload={'name':'Yogasree','gps_lat':99})).status_code,409) # Existing id cannot be recreated.
    def test_recorder_role_and_capacity_cannot_invalidate_existing_cameras(self):
        self.create_site();nvr=uid();camera=uid()
        self.assertEqual(self.push(self.mutation('assets',nvr,payload={'asset_type':'NVR','channel_capacity':64})).status_code,200)
        self.assertEqual(self.push(self.mutation('cameras',camera,payload={'nvr_id':nvr,'channel_no':42})).status_code,200)
        for payload in [{'asset_type':'Router'},{'channel_capacity':32}]:
            response=self.push(self.mutation('assets',nvr,1,'update',payload))
            self.assertEqual(response.status_code,422,response.text)
        with Session(self.engine) as db:self.assertEqual(db.get(m.Asset,nvr).version,1)
    def test_observation_boolean_and_timestamp(self):
        self.create_site()
        r=self.push(self.mutation('observations',uid(),payload={'kind':'camera_count','payload':{'count':42},'confirmed':True,'observed_at':'2026-10-20T12:00:00Z'}))
        self.assertEqual(r.status_code,200,r.text);self.assertIs(r.json()['record']['confirmed'],True)

if __name__=='__main__':unittest.main()
