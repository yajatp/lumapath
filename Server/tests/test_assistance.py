import copy
import io
import json
import tempfile
import unittest
from pathlib import Path
from lumapath_service.assistance import AssistanceProxy
from lumapath_service.auth import Principal
from lumapath_service.database import Database
from lumapath_service.schema import APIError
from lumapath_service.http import Application

class AssistanceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.db=Database(Path(self.temp.name)/'db.sqlite3'); self.now=100.; self.sent=[]
        self.user=Principal('user','user')
        self.proxy=AssistanceProxy(self.db,self.provider,daily_cap_microusd=100000,request_reserve_microusd=100,clock=lambda:self.now,monotonic=lambda:self.now)
    def body(self,task='attention'):
        body=dict(schemaVersion=2,requestId='req-1',sessionId='session-1',generation=1,sourceSequence=2,goalRevision=3,profileRevision=4,budgetMs=1000,textConsent=True)
        if task=='attention': body.update(goal='door',detail='minimal',candidates=[dict(id='obs-1',kind='door',bearing='left',evidence='observed')],allowedSelections=['obs-1','none'])
        else: body.update(text='Find a door')
        return body
    def provider(self,payload,timeout,images):
        self.sent.append(copy.deepcopy(payload))
        return dict(model=payload['model'],answers={k:dict(type='choice',choice=next(iter(q['criteria'])),confidence=.9) for k,q in payload['questions'].items()})
    def error(self,code,call):
        with self.assertRaises(APIError) as result: call()
        self.assertEqual(result.exception.code,code)
    def test_envelope_and_minimal_provider_state(self):
        result=self.proxy.call(self.user,'attention',self.body())
        self.assertEqual(result['selection'],'obs-1'); self.assertEqual(result['goalRevision'],3)
        self.assertNotIn('sessionId',json.dumps(self.sent)); self.assertNotIn('user',json.dumps(self.sent))
        self.assertEqual(result['quotaRemaining'],29)
    def test_consent_schema_and_unconfigured_fail_closed(self):
        for change,code in [(dict(textConsent=False),'consentRequired'),(dict(schemaVersion=1),'unsupportedSchema'),(dict(allowedSelections=['bogus']),'invalidPayload'),(dict(candidates=[[]]),'invalidPayload')]:
            self.error(code,lambda:self.proxy.call(self.user,'attention',self.body()|change))
        self.assertEqual(self.sent,[])
        self.error('providerNotConfigured',lambda:AssistanceProxy(self.db).call(self.user,'attention',self.body()))
    def test_invalid_selection_pin_and_timeout_breaker(self):
        def bad(*args): return dict(model='jev-1.14.0',answers={'selection':dict(type='choice',choice='injected',confidence=1)})
        self.proxy.transport=bad
        for _ in range(3): self.error('invalidSelection',lambda:self.proxy.call(self.user,'attention',self.body()))
        self.error('providerCircuitOpen',lambda:self.proxy.call(self.user,'attention',self.body()))
        self.now+=61; self.proxy.transport=self.provider
        self.assertEqual(self.proxy.call(self.user,'attention',self.body())['selection'],'obs-1')
        def late(*args):
            value=self.provider(*args); self.now+=2; return value
        self.proxy.transport=late
        self.error('providerTimeout',lambda:self.proxy.call(self.user,'attention',self.body()))
        self.proxy.transport=lambda *args:dict(model='jev-latest')
        self.error('providerModelMismatch',lambda:self.proxy.call(self.user,'attention',self.body()))
    def test_quota_and_spend_survive_proxy_restart(self):
        for _ in range(30): self.proxy.call(self.user,'attention',self.body())
        self.error('quotaExceeded',lambda:self.proxy.call(self.user,'attention',self.body()))
        other=AssistanceProxy(self.db,self.provider,daily_cap_microusd=3000,request_reserve_microusd=100,clock=lambda:self.now,monotonic=lambda:self.now)
        self.error('dailySpendCap',lambda:other.call(Principal('other','user'),'intent',self.body('intent')))
        self.now+=86400
        self.assertEqual(other.call(self.user,'intent',self.body('intent'))['intent'],'findTarget')
    def test_intent_consistency_and_classification_are_bounded_suggestions(self):
        result=self.proxy.call(self.user,'classification',self.body('classification'))
        self.assertTrue(result['suggestionOnly']); self.assertTrue(result['humanReviewRequired'])
        def conflicting(payload,*args):
            result=self.provider(payload,*args); result['answers']['target']['choice']='none'; return result
        self.proxy.transport=conflicting
        result=self.proxy.call(self.user,'intent',self.body('intent'))
        self.assertEqual(result['intent'],'clarify'); self.assertTrue(result['clarificationRequired'])
    def test_image_presence_bounds_and_frame_retained(self):
        import base64
        from PIL import Image
        buffer=io.BytesIO(); Image.new('RGB',(4,4)).save(buffer,format='PNG')
        body=self.body('image'); del body['text']
        body.update(imageConsent=True,researchOnly=True,frameId='original-frame',target='door',image=dict(format='png',base64=base64.b64encode(buffer.getvalue()).decode()))
        def image_provider(payload,timeout,images):
            self.assertTrue(images); self.assertIn('assets',payload)
            return dict(model=payload['model'],answers=dict(present=dict(type='noul',noul=.1,confidence=.9),box=dict(type='box',confidence=.8,box=dict(top=.1,bottom=.5,left=.2,right=.8))))
        self.proxy.transport=image_provider
        result=self.proxy.call(self.user,'image',body)
        self.assertIsNone(result['box']); self.assertEqual(result['frameId'],'original-frame')
        self.error('imageConsentRequired',lambda:self.proxy.call(self.user,'image',body|dict(imageConsent=False)))
        def invalid(*args):
            value=image_provider(*args); value['answers']['box']['box']['left']=.9; return value
        self.proxy.transport=invalid
        self.error('invalidBox',lambda:self.proxy.call(self.user,'image',body))
    def test_image_metadata_rejected_before_provider(self):
        import base64
        from PIL import Image, PngImagePlugin
        image=io.BytesIO(); info=PngImagePlugin.PngInfo(); info.add_text('private','private GPS-like metadata')
        Image.new('RGB',(4,4)).save(image,format='PNG',pnginfo=info)
        body=self.body('image'); del body['text']
        body.update(imageConsent=True,researchOnly=True,frameId='original',target='door',image=dict(format='png',base64=base64.b64encode(image.getvalue()).decode()))
        self.error('evidenceMetadataMustBeRemoved',lambda:self.proxy.call(self.user,'image',body))
        self.assertEqual(self.sent,[])

    def test_authenticated_http_and_private_error_logging(self):
        class Identity:
            def authenticate(inner,auth):
                if auth!='Bearer fixture': raise APIError(401,'authenticationRequired')
                return self.user
        class Service:
            def limit(*args): pass
        app=Application(Service(),Identity(),self.proxy)
        def request(auth):
            raw=json.dumps(self.body()).encode(); response={}
            env=dict(REQUEST_METHOD='POST',PATH_INFO='/v1/assistance/attention',CONTENT_LENGTH=str(len(raw)),CONTENT_TYPE='application/json',HTTP_AUTHORIZATION=auth)
            env['wsgi.input']=io.BytesIO(raw)
            result=b''.join(app(env,lambda status,headers:response.update(status=status)))
            return response,result
        self.assertTrue(request(None)[0]['status'].startswith('401'))
        with self.assertLogs('lumapath.requests',level='INFO') as logs: response,raw=request('Bearer fixture')
        self.assertTrue(response['status'].startswith('200'))
        self.assertNotIn('obs-1',''.join(logs.output)); self.assertNotIn('fixture',''.join(logs.output))
