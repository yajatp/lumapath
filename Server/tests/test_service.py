import base64
import io
import json
from pathlib import Path
import tempfile
import time
import unittest
from types import SimpleNamespace
from cryptography.hazmat.primitives.asymmetric import rsa
from PIL import Image
import jwt
from lumapath_service.auth import IdentityService, OIDCVerifier, UnconfiguredIdentity
from lumapath_service.database import Database
from lumapath_service.http import Application
from lumapath_service.schema import APIError
from lumapath_service.service import CommunityService
from lumapath_service.storage import LocalObjectStorage

class FixtureKeys:
    def __init__(self,key): self.key=key
    def get_signing_key_from_jwt(self,token): return SimpleNamespace(key=self.key)

class ServiceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); self.db=Database(self.root/'db'/'service.sqlite3'); self.storage=LocalObjectStorage(self.root/'objects')
        self.now=time.time(); self.clock=lambda:self.now
        verifier=OIDCVerifier('https://identity.example','lumapath','https://identity.example/jwks',FixtureKeys(self.key.public_key()))
        self.identity=IdentityService(self.db,verifier,self.clock); self.service=CommunityService(self.db,self.storage,self.clock); self.app=Application(self.service,self.identity)
        self.author,self.author_auth=self.login('author'); self.other,self.other_auth=self.login('other'); self.mod,self.mod_auth=self.login('moderator')
        with self.db.transaction() as db: db.execute("UPDATE users SET role='moderator' WHERE id=?",(self.mod.id,))
        self.mod=self.identity.authenticate(self.mod_auth)
    def signed(self,subject,nonce_value,**changes):
        claims=dict(iss='https://identity.example',aud='lumapath',sub=subject,iat=int(time.time()),exp=int(time.time())+600,nonce=nonce_value)
        claims.update(changes)
        return jwt.encode(claims,self.key,algorithm='RS256',headers={'kid':'fixture-key'})
    def login(self,subject):
        nonce=self.identity.challenge()['nonce']; result=self.identity.exchange(self.signed(subject,nonce),nonce)
        auth='Bearer '+result['accessToken']; return self.identity.authenticate(auth),auth
    def report(self,**changes):
        body=dict(category='sidewalkObstruction',description='Private reviewed description',segmentID='pilot-1',side='north',level='ground',latitude=41.88123,longitude=-87.62123,
                  observedAt=self.now-10,expectedPersistence='temporary',sourceMode='manualPublicLocation',publicLocationConfirmed=True)
        body.update(changes); return body
    def create(self,key='draft-1',**changes): return self.service.create(self.author,self.report(**changes),key)[0]
    def publish(self,report,status='verified'):
        return self.service.moderate(self.mod,report['id'],dict(expectedRevision=report['revision'],status=status,reason='Reviewed fixture evidence',evidenceReference='fixture-survey-1'))
    def error(self,status,call):
        with self.assertRaises(APIError) as result: call()
        self.assertEqual(result.exception.status,status)
    def request(self,method,path,body=None,authorization=None,**headers):
        payload=json.dumps(body).encode() if body is not None else b''
        env={'REQUEST_METHOD':method,'PATH_INFO':path,'REMOTE_ADDR':'127.0.0.1','CONTENT_LENGTH':str(len(payload)),
             'CONTENT_TYPE':'application/json','wsgi.input':io.BytesIO(payload),**headers}
        if authorization: env['HTTP_AUTHORIZATION']=authorization
        response={}
        result=b''.join(self.app(env,lambda status,h:response.update(status=int(status.split()[0]),headers=dict(h))))
        response['body']=result if response['headers']['Content-Type']!='application/json' else json.loads(result)
        return response
    def test_real_signature_identity_exchange_nonce_replay_and_revocation(self):
        nonce=self.identity.challenge()['nonce']; signed=self.signed('new',nonce)
        result=self.identity.exchange(signed,nonce)
        self.error(401,lambda:self.identity.exchange(signed,nonce))
        auth='Bearer '+result['accessToken']; self.identity.revoke(auth)
        self.error(401,lambda:self.identity.authenticate(auth))
    def test_wrong_issuer_audience_nonce_unsigned_and_expired_tokens_rejected(self):
        for claims in [dict(iss='https://wrong.example'),dict(aud='wrong'),dict(nonce='wrong'),dict(exp=int(time.time())-1),dict(iat=int(time.time())+100)]:
            nonce=self.identity.challenge()['nonce']
            self.error(401,lambda:self.identity.exchange(self.signed('bad',nonce,**claims),nonce))
        nonce=self.identity.challenge()['nonce']
        wrong_key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        forged=jwt.encode(dict(iss='https://identity.example',aud='lumapath',sub='bad',nonce=nonce,iat=int(time.time()),exp=int(time.time())+300),wrong_key,algorithm='RS256')
        self.error(401,lambda:self.identity.exchange(forged,nonce))
        nonce=self.identity.challenge()['nonce']
        unsigned=jwt.encode(dict(iss='https://identity.example',aud='lumapath',sub='bad',nonce=nonce,iat=int(time.time()),exp=int(time.time())+300),key='',algorithm='none')
        self.error(401,lambda:self.identity.exchange(unsigned,nonce))
    def test_role_claims_never_grant_moderation_and_missing_provider_is_truthful(self):
        nonce=self.identity.challenge()['nonce']; result=self.identity.exchange(self.signed('role-injection',nonce,role='moderator'),nonce)
        principal=self.identity.authenticate('Bearer '+result['accessToken']); self.assertEqual(principal.role,'user')
        self.error(503,lambda:UnconfiguredIdentity().verify('anything','nonce'))
    def test_duplicate_submission_exactly_once_and_conflicting_payload(self):
        first,created=self.service.create(self.author,self.report(),'same-draft'); second,repeated=self.service.create(self.author,self.report(),'same-draft')
        self.assertTrue(created); self.assertFalse(repeated); self.assertEqual(first['id'],second['id'])
        self.error(409,lambda:self.service.create(self.author,self.report(description='changed'),'same-draft'))
        with self.db.connect() as db: self.assertEqual(db.execute('SELECT COUNT(*) FROM reports').fetchone()[0],1)
    def test_invalid_payload_private_location_and_server_fields_rejected(self):
        for changes in [dict(publicLocationConfirmed=False),dict(description=''),dict(latitude=float('nan')),dict(category='invalid'),dict(role='moderator'),dict(expectedPersistence=[]),dict(sourceMode='savedRoomMap')]:
            self.error(400,lambda:self.create(**changes))
    def test_object_authorization_and_self_moderation_are_enforced(self):
        report=self.create(); self.error(403,lambda:self.service.read(self.other,report['id']))
        self.error(403,lambda:self.service.moderate(self.author,report['id'],dict(expectedRevision=1,status='verified',reason='self')))
        own=self.service.create(self.mod,self.report(),'mod-draft')[0]
        self.error(403,lambda:self.publish(own))
    def test_revision_conflict_and_edit_invalidates_public_projection(self):
        report=self.publish(self.create()); version=self.service.public_list()['version']
        self.error(409,lambda:self.service.edit(self.author,report['id'],dict(expectedRevision=1,report=self.report())))
        updated=self.service.edit(self.author,report['id'],dict(expectedRevision=report['revision'],report=self.report(description='updated')))
        self.assertEqual(updated['status'],'pendingReview'); self.assertEqual(self.service.public_list()['reports'],[])
        self.assertGreater(self.service.public_list()['version'],version)
    def test_public_projection_omits_personal_text_account_and_evidence(self):
        report=self.publish(self.create(description='private contact alice@example.test'))
        public=self.service.public_list(); encoded=json.dumps(public)
        for private in [self.author.id,'alice@example.test','author_id','evidence_key','description','accessToken']: self.assertNotIn(private,encoded)
        self.assertEqual(public['reports'][0]['latitude'],41.881)
        self.assertEqual(public['reports'][0]['id'],report['id'])
    def evidence_payload(self,expected=1):
        data=io.BytesIO(); Image.new('RGB',(8,8),'white').save(data,format='PNG')
        return dict(expectedRevision=expected,reviewed=True,mediaType='image/png',base64=base64.b64encode(data.getvalue()).decode())
    def test_private_evidence_ownership_metadata_validation_and_deletion(self):
        report=self.create(); body=self.evidence_payload()
        self.error(403,lambda:self.service.attach(self.other,report['id'],body))
        attached=self.service.attach(self.author,report['id'],body)
        binary,media=self.service.evidence(self.author,report['id']); self.assertEqual(media,'image/png'); self.assertGreater(len(binary),0)
        self.error(403,lambda:self.service.evidence(self.other,report['id']))
        self.service.delete(self.author,report['id'],attached['revision'])
        self.assertEqual(list((self.root/'objects').iterdir()),[])
        with self.db.connect() as db:
            self.assertEqual(db.execute('SELECT body FROM reports').fetchone()[0],'{}')
            self.assertEqual(db.execute('SELECT completed FROM deletion_jobs').fetchone()[0],1)
        self.error(410,lambda:self.create())
    def test_failed_storage_rolls_back_revision_and_failed_delete_is_retryable(self):
        report=self.create(); original_put=self.storage.put
        self.storage.put=lambda data:(_ for _ in ()).throw(OSError('fixture disk failure'))
        with self.assertRaises(OSError): self.service.attach(self.author,report['id'],self.evidence_payload())
        self.assertEqual(self.service.read(self.author,report['id'])['revision'],1)
        self.storage.put=original_put; attached=self.service.attach(self.author,report['id'],self.evidence_payload())
        original_delete=self.storage.delete; self.storage.delete=lambda key:(_ for _ in ()).throw(OSError('fixture deletion failure'))
        self.service.delete(self.author,report['id'],attached['revision']); self.error(404,lambda:self.service.read(self.author,report['id']))
        self.storage.delete=original_delete; self.service.run_deletions()
        self.assertEqual(list((self.root/'objects').iterdir()),[])
    def test_http_auth_schema_limits_error_redaction_and_cache_headers(self):
        self.assertEqual(self.request('GET','/v1/reports/whatever')['status'],401)
        created=self.request('POST','/v1/reports',self.report(),self.author_auth,HTTP_IDEMPOTENCY_KEY='http-draft')
        self.assertEqual(created['status'],201)
        self.assertEqual(created['headers']['Cache-Control'],'no-store')
        other=self.request('GET','/v1/reports/'+created['body']['id'],authorization=self.other_auth)
        self.assertEqual(other['status'],403); self.assertNotIn('Private reviewed',json.dumps(other))
        self.assertEqual(self.request('GET','/health')['body']['status'],'ok')
        for _ in range(2): self.service.limit('fixture-quota',2,3600)
        self.service.limit('different-window',5,60)
        self.error(429,lambda:self.service.limit('fixture-quota',2,3600))
    def test_moderation_requires_evidence_reason_and_valid_transition(self):
        report=self.create()
        self.error(400,lambda:self.service.moderate(self.mod,report['id'],dict(expectedRevision=1,status='verified',reason='reviewed')))
        published=self.publish(report)
        self.error(409,lambda:self.service.moderate(self.mod,report['id'],dict(expectedRevision=published['revision'],status='pendingReview',reason='invalid')))
        detail=self.service.read(self.mod,report['id']); self.assertEqual(detail['audit'][-1]['action'],'verified')

    def test_real_loopback_http_identity_and_report_roundtrip(self):
        import http.client
        import threading
        from wsgiref.simple_server import make_server
        from lumapath_service.__main__ import QuietHandler
        server=make_server('127.0.0.1',0,self.app,handler_class=QuietHandler)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            connection.request('POST','/v1/auth/challenge',body=b'',headers={'Content-Length':'0'})
            response=connection.getresponse(); self.assertEqual(response.status,200); nonce=json.loads(response.read())['nonce']
            body=json.dumps(dict(identityToken=self.signed('http-user',nonce),nonce=nonce))
            connection.request('POST','/v1/auth/exchange',body=body,headers={'Content-Type':'application/json'})
            response=connection.getresponse(); self.assertEqual(response.status,200); auth='Bearer '+json.loads(response.read())['accessToken']
            connection.request('POST','/v1/reports',body=json.dumps(self.report()),headers={'Content-Type':'application/json','Authorization':auth,'Idempotency-Key':'live-http-draft'})
            response=connection.getresponse(); self.assertEqual(response.status,201); report=json.loads(response.read())
            connection.request('GET','/v1/reports/'+report['id'],headers={'Authorization':auth})
            response=connection.getresponse(); self.assertEqual(response.status,200); self.assertEqual(json.loads(response.read())['id'],report['id'])
            connection.close()
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=3)

    def test_concurrent_duplicate_requests_insert_one_report(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as executor:
            results=list(executor.map(lambda _:self.service.create(self.author,self.report(),'concurrent-draft'),range(8)))
        self.assertEqual(len({r[0]['id'] for r in results}),1)
        self.assertEqual(sum(r[1] for r in results),1)

    def test_metadata_and_malformed_evidence_are_rejected_without_storage(self):
        report=self.create(); body=self.evidence_payload(); body['base64']='not valid!'
        self.error(400,lambda:self.service.attach(self.author,report['id'],body))
        from PIL.PngImagePlugin import PngInfo
        metadata=PngInfo(); metadata.add_text('contact','private@example.test')
        image=io.BytesIO(); Image.new('RGB',(8,8)).save(image,format='PNG',pnginfo=metadata)
        body=self.evidence_payload(); body['base64']=base64.b64encode(image.getvalue()).decode()
        self.error(400,lambda:self.service.attach(self.author,report['id'],body))
        self.assertEqual(list((self.root/'objects').iterdir()),[])

if __name__=='__main__': unittest.main()
