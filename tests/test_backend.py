import asyncio
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import httpx
from fastapi.testclient import TestClient
from pydantic import ValidationError
from app.ai.contracts import ExtractedData
from app.ai.probing import probe_site
from app.ai.providers import AIProvider, ProviderError
from app.config import Settings
from app.main import create_app

TOKEN = 'test-only-token-with-at-least-32-characters'
AUTH = {'Authorization': 'Bearer ' + TOKEN}

def settings(**kwargs):
    return Settings(_env_file=None, api_token=TOKEN, **kwargs)

def sample(**report):
    return ExtractedData.model_validate({
        'site':{'name':'Yogasree Textiles'},
        'assets':[{'ref':'nvr1','asset_type':'NVR','channel_capacity':64}],
        'inventory_reports':[{'nvr_id':'nvr1', 'brand_counts':{'Dahua':27, 'CP Plus':15},
                              'brand_breakdown_complete':True, **report}]})

class StubProvider:
    def __init__(self):
        self.context = None
        self.audio = None
    async def extract(self, text, context):
        self.context = context
        return sample()
    async def transcribe(self, audio, mime, language):
        self.audio = (audio, mime, language)
        return '64 channel NVR, 27 Dahua and 15 CP Plus cameras'

class ProbingTests(unittest.TestCase):
    def test_64_channels_42_cameras_no_invented_online_or_poe(self):
        data = sample()
        calculations, warnings, probes = probe_site(data)
        result = calculations[0]
        self.assertEqual((result.reported_total, result.free_channels), (42,22))
        self.assertIsNone(result.reported_active)
        self.assertEqual(result.poe_minimum_switches, {})
        self.assertEqual(data.cameras, [])
        self.assertIn('active_cameras', [p.code for p in probes])
        self.assertFalse(warnings)

    def test_conditional_poe_lower_bound(self):
        result = probe_site(sample(poe_camera_count=42))[0][0]
        self.assertEqual(result.poe_minimum_switches, {'8':6,'16':3,'24':2})

    def test_partial_brand_breakdown_is_not_total(self):
        data = sample()
        data.inventory_reports[0].brand_breakdown_complete = False
        self.assertIsNone(probe_site(data)[0][0].free_channels)

    def test_conflicting_brand_counts_suppress_free_channels(self):
        result, warnings, _ = probe_site(sample(reported_total=40))
        self.assertIsNone(result[0].free_channels)
        self.assertTrue(warnings)

    def test_camera_count_above_capacity_is_not_negative_free(self):
        data = sample(reported_total=70)
        data.inventory_reports[0].brand_breakdown_complete = False
        result, warnings, probes = probe_site(data)
        self.assertIsNone(result[0].free_channels)
        self.assertTrue(warnings)
        self.assertIn('capacity_exceeded', [p.code for p in probes])

    def test_multiple_recorders_not_combined(self):
        data = sample()
        raw = data.model_dump()
        raw['assets'].append({'ref':'nvr2','asset_type':'NVR','channel_capacity':16})
        raw['inventory_reports'].append({'nvr_id':'nvr2','reported_total':10})
        results = probe_site(ExtractedData.model_validate(raw))[0]
        self.assertEqual([r.free_channels for r in results], [22,6])

    def test_dangling_and_wrong_type_references_rejected(self):
        for value in ({'cameras':[{'ref':'c','nvr_id':'missing'}]},
                      {'assets':[{'ref':'sw','asset_type':'UPS'}], 'cameras':[{'ref':'c','switch_id':'sw'}]},
                      {'assets':[{'ref':'a','asset_type':'NVR'}], 'cameras':[{'ref':'c1','nvr_id':'a','channel_no':1},{'ref':'c2','nvr_id':'a','channel_no':1}]}):
            with self.assertRaises(ValidationError):
                ExtractedData.model_validate(value)

    def test_confirmed_port_and_ups_reports_do_not_repeat(self):
        data = ExtractedData.model_validate({'assets':[
            {'ref':'s','asset_type':'PoE_Switch','port_capacity':8,'poe_port_capacity':8},
            {'ref':'u','asset_type':'UPS'}],
            'switch_reports':[{'switch_id':'s','used_ports':5,'free_ports':3,'faulty_ports':0,'uplink_port':'8'}],
            'ups_reports':[{'ups_id':'u','capacity_va':1000,'tested_backup_minutes':30,'battery_install_year':2025}],
            'connectivity':[{'ref':'p','from_asset_id':'u','to_asset_id':'s','connection_type':'power'}]})
        codes = [p.code for p in probe_site(data)[2]]
        self.assertNotIn('port_status',codes)
        self.assertNotIn('ups_runtime',codes)
        self.assertNotIn('ups_mapping',codes)

class ApiTests(unittest.TestCase):
    def setUp(self):
        self.provider = StubProvider()
        self.client = self.enterContext(TestClient(create_app(settings(), self.provider)))

    def test_text_briefing(self):
        response = self.client.post('/api/v1/ai/site-briefing', headers=AUTH,
                                    json={'text':'64-channel NVR, 27 Dahua, 15 CP Plus cameras'})
        self.assertEqual(response.status_code,200, response.text)
        result = response.json()
        self.assertEqual(result['calculations'][0]['free_channels'],22)
        self.assertTrue(result['requires_confirmation'])
        self.assertTrue(result['next_question_tamil'])

    def test_auth_is_required(self):
        response = self.client.post('/api/v1/ai/site-briefing',json={'text':'hello'})
        self.assertEqual(response.status_code,401)

    def test_validation_does_not_echo_private_input(self):
        response = self.client.post('/api/v1/ai/site-briefing',headers=AUTH,json={'text':{'password':'secret'}})
        self.assertEqual(response.status_code,422)
        self.assertNotIn('secret',response.text)

    def test_audio_and_context(self):
        context = sample().model_dump(mode='json')
        response = self.client.post('/api/v1/ai/site-briefing', headers=AUTH,
            files={'audio':('briefing.wav',b'RIFF-test-audio','audio/wav')},
            data={'metadata':json.dumps({'language':'ta','context':context})})
        self.assertEqual(response.status_code,200, response.text)
        self.assertEqual(self.provider.audio[2], 'ta')
        self.assertEqual(self.provider.context.site.name,'Yogasree Textiles')

    def test_unsupported_and_empty_audio(self):
        for body, mime, expected in [(b'abc','application/pdf',415), (b'','audio/wav',422)]:
            response = self.client.post('/api/v1/ai/site-briefing', headers=AUTH,files={'audio':('x',body,mime)})
            self.assertEqual(response.status_code,expected)

    def test_size_limit_including_chunked(self):
        with TestClient(create_app(settings(max_request_bytes=1024),self.provider)) as client:
            response = client.post('/api/v1/ai/site-briefing',headers={**AUTH,'Content-Type':'application/json'},content=iter([b'x'*600,b'x'*600]))
            self.assertEqual(response.status_code,413)

    def test_audio_specific_limit(self):
        with TestClient(create_app(settings(max_audio_bytes=1024),self.provider)) as client:
            response = client.post('/api/v1/ai/site-briefing',headers=AUTH,
                files={'audio':('x.wav',b'x'*1025,'audio/wav')})
            self.assertEqual(response.status_code,413)

    def test_malformed_metadata_and_duplicate_file(self):
        response = self.client.post('/api/v1/ai/site-briefing',headers=AUTH,
            files={'audio':('x',b'abc','audio/wav')},data={'metadata':'bad-json'})
        self.assertEqual(response.status_code,422)
        response = self.client.post('/api/v1/ai/site-briefing',headers=AUTH,
            files=[('audio',('x',b'abc','audio/wav')),('audio',('y',b'abc','audio/wav'))])
        self.assertEqual(response.status_code,400)

    def test_safe_provider_failure(self):
        async def fail(*args):
            raise ProviderError('provider_rate_limited',503)
        self.provider.extract = fail
        response = self.client.post('/api/v1/ai/site-briefing',headers=AUTH,json={'text':'test'})
        self.assertEqual(response.status_code,503)
        self.assertEqual(response.json()['detail'],'provider_rate_limited')

    def test_whole_briefing_timeout(self):
        async def slow(*args):
            await asyncio.sleep(1)
        self.provider.extract = slow
        with TestClient(create_app(settings(briefing_timeout_seconds=.01),self.provider)) as client:
            response = client.post('/api/v1/ai/site-briefing',headers=AUTH,json={'text':'test'})
            self.assertEqual(response.status_code,504)

    def test_openapi_schemas_resolve(self):
        spec = self.client.get('/openapi.json').json()
        def walk(value):
            if isinstance(value,dict):
                if '$ref' in value:
                    target = spec
                    for part in value['$ref'][2:].split('/'):
                        target = target[part]
                for v in value.values():
                    walk(v)
            elif isinstance(value,list):
                for v in value:
                    walk(v)
        walk(spec)

class ProviderTests(unittest.IsolatedAsyncioTestCase):
    async def provider(self, handler, **kwargs):
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        self.addAsyncCleanup(client.aclose)
        return AIProvider(settings(**kwargs),client)

    async def test_gemini_request_and_valid_response(self):
        def handler(request):
            body = json.loads(request.content)
            self.assertIn('systemInstruction',body)
            self.assertEqual(body['generationConfig']['responseMimeType'],'application/json')
            self.assertEqual(request.headers['x-goog-api-key'],'fake-key')
            self.assertNotIn('supersecret',request.content.decode())
            return httpx.Response(200,json={'candidates':[{'finishReason':'STOP','content':{'parts':[{'text':sample().model_dump_json()}]}}]})
        engine = await self.provider(handler,gemini_api_key='fake-key')
        result = await engine.extract('username admin password supersecret', None)
        self.assertEqual(len(result.assets),1)

    async def test_groq_json_mode_and_context(self):
        def handler(request):
            body = json.loads(request.content)
            self.assertEqual(body['response_format'],{'type':'json_object'})
            self.assertIn('Yogasree',body['messages'][1]['content'])
            return httpx.Response(200,json={'choices':[{'finish_reason':'stop','message':{'content':sample().model_dump_json()}}]})
        engine = await self.provider(handler,ai_provider='groq',groq_api_key='fake-key')
        self.assertEqual((await engine.extract('next answer',sample())).site.name,'Yogasree Textiles')

    async def test_whisper_language_and_multipart(self):
        def handler(request):
            self.assertEqual(str(request.url),'https://api.groq.com/openai/v1/audio/transcriptions')
            self.assertIn(b'whisper-large-v3',request.content)
            self.assertIn(b'name="language"',request.content)
            return httpx.Response(200,json={'text':'Ground floor-la 8 port switch irukku'})
        engine = await self.provider(handler,groq_api_key='fake-key')
        self.assertIn('Ground floor',await engine.transcribe(b'audio','audio/wav','ta'))

    async def test_invalid_json_topology_and_truncated_output(self):
        for text, finish in [('not json','STOP'), ('{"cameras":[{"ref":"c","nvr_id":"missing"}]}','STOP'), ('{}','MAX_TOKENS')]:
            engine = await self.provider(lambda req: httpx.Response(200,json={'candidates':[{'finishReason':finish,'content':{'parts':[{'text':text}]}}]}),gemini_api_key='fake')
            with self.assertRaises(ProviderError):
                await engine.extract('test',None)

    async def test_malformed_provider_envelopes_are_safe_errors(self):
        for body in ({'candidates':['invalid']}, [], {'candidates':[{}]}):
            engine = await self.provider(lambda req: httpx.Response(200,json=body),gemini_api_key='fake')
            with self.assertRaises(ProviderError):
                await engine.extract('test',None)

    async def test_upstream_response_size_limit(self):
        engine = await self.provider(lambda req: httpx.Response(200,content=b'x'*(2*1024*1024+1)),gemini_api_key='fake')
        with self.assertRaises(ProviderError) as caught:
            await engine.extract('test',None)
        self.assertEqual(caught.exception.code,'provider_response_too_large')

    async def test_provider_failures(self):
        for status, expected in [(429,503),(401,502),(500,502)]:
            engine = await self.provider(lambda req: httpx.Response(status,text='private upstream error'),gemini_api_key='fake')
            with self.assertRaises(ProviderError) as result:
                await engine.extract('test',None)
            self.assertEqual(result.exception.status,expected)
            self.assertNotIn('private',str(result.exception))

    async def test_concurrency_exhaustion_rejects_then_recovers(self):
        entered, release = asyncio.Event(), asyncio.Event()
        stub = StubProvider()
        original = stub.extract
        async def blocking(*args):
            entered.set()
            await release.wait()
            return await original(*args)
        stub.extract = blocking
        app = create_app(settings(max_concurrent_briefings=1),stub)
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://test') as client:
                first = asyncio.create_task(client.post('/api/v1/ai/site-briefing',headers=AUTH,json={'text':'first'}))
                await asyncio.wait_for(entered.wait(),timeout=2)
                try:
                    second = await client.post('/api/v1/ai/site-briefing',headers=AUTH,json={'text':'second'})
                    self.assertEqual(second.status_code,503)
                    self.assertEqual(second.headers['retry-after'],'5')
                finally:
                    release.set()
                    result = await first
                self.assertEqual(result.status_code,200)
                third = await client.post('/api/v1/ai/site-briefing',headers=AUTH,json={'text':'third'})
                self.assertEqual(third.status_code,200)

    async def test_timeout_and_missing_configuration(self):
        def timeout(request):
            raise httpx.ReadTimeout('private',request=request)
        engine = await self.provider(timeout,gemini_api_key='fake')
        with self.assertRaises(ProviderError) as caught:
            await engine.extract('test',None)
        self.assertEqual(caught.exception.status,504)
        engine = await self.provider(timeout)
        with self.assertRaises(ProviderError) as caught:
            await engine.transcribe(b'x','audio/wav','auto')
        self.assertEqual(caught.exception.status,503)

if __name__ == '__main__':
    unittest.main()
