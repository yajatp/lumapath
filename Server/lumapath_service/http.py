"""Small WSGI boundary; body/header limits and redacted structured operational logging."""
import hashlib
import json
import logging
import secrets
from urllib.parse import parse_qs
from .schema import APIError, exact, require, revision

logger = logging.getLogger('lumapath.requests')

class Application:
    def __init__(self, service, identity, assistance=None):
        self.service, self.identity = service, identity
        self.assistance = assistance
    def __call__(self, environ, start_response):
        request_id, route = secrets.token_hex(8), 'unknown'
        try:
            method, path = environ.get('REQUEST_METHOD',''), environ.get('PATH_INFO','')
            require(len(path)<=512,414,'pathBudget')
            address = environ.get('REMOTE_ADDR','unknown')
            self.service.limit('ip:'+hashlib.sha256(address.encode()).hexdigest(),120)
            length = environ.get('CONTENT_LENGTH') or '0'
            require(length.isdigit() and int(length)<=1_500_000,413,'requestBudget')
            raw = environ['wsgi.input'].read(int(length))
            require(len(raw)==int(length),400,'incompleteBody')
            body = None
            if raw:
                require(environ.get('CONTENT_TYPE','').split(';')[0]=='application/json',415,'jsonRequired')
                try: body = json.loads(raw,parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
                except (ValueError,UnicodeError,RecursionError): raise APIError(400,'invalidJSON') from None
            segments = path.strip('/').split('/')
            status, data, extra = 200, None, []
            if path=='/health' and method=='GET':
                route='health'; data=self.service.health()
            elif path=='/v1/auth/challenge' and method=='POST':
                route='authChallenge'; data=self.identity.challenge()
            elif path=='/v1/auth/exchange' and method=='POST':
                route='authExchange'; exact(body,('identityToken','nonce')); data=self.identity.exchange(body['identityToken'],body['nonce'])
            elif path in ('/v1/public/issues','/v1/public/route-evidence','/v1/public/civic-export') and method=='GET':
                require(hasattr(self.service,'public_issues'),503,'intelligenceNotConfigured')
                route='publicIntelligence'; query=self._query(environ.get('QUERY_STRING',''))
                if path.endswith('/issues'): data=self.service.public_issues(query)
                elif path.endswith('/route-evidence'): data=self.service.route_evidence(query)
                else:
                    format=query.pop('format','geojson'); exported=self.service.civic_export(query,format)
                    if format=='geojson': data=exported
                    else:
                        data=exported.encode(); extra=[('Content-Type','text/csv; charset=utf-8' if format=='csv' else 'text/plain; charset=utf-8')]
            elif path=='/v1/public/reports' and method=='GET':
                route='publicReports'; data=self.service.public_list(); extra=[('ETag','"'+str(data['version'])+'"')]
            else:
                authorization = environ.get('HTTP_AUTHORIZATION')
                principal = self.identity.authenticate(authorization)
                self.service.limit('user:'+principal.id,120)
                if len(segments)==3 and segments[:2]==['v1','assistance'] and method=='POST':
                    route='assistance'
                    require(self.assistance is not None,503,'providerNotConfigured')
                    data=self.assistance.call(principal,segments[2],body)
                elif path=='/v1/session' and method=='DELETE':
                    route='revokeSession'; self.identity.revoke(authorization); data={'revoked':True}
                elif path=='/v1/reports' and method=='POST':
                    route='createReport'; data,created=self.service.create(principal,body,environ.get('HTTP_IDEMPOTENCY_KEY')); status=201 if created else 200
                elif path=='/v1/moderation/queue' and method=='GET':
                    route='moderationQueue'; data={'reports':self.service.queue(principal)}
                elif len(segments)>=3 and segments[:2]==['v1','reports']:
                    report_id=segments[2]
                    if len(segments)==3 and method=='GET': route='readReport'; data=self.service.read(principal,report_id)
                    elif len(segments)==3 and method=='PATCH': route='editReport'; data=self.service.edit(principal,report_id,body)
                    elif len(segments)==3 and method=='DELETE':
                        route='deleteReport'; exact(body,('expectedRevision',)); data=self.service.delete(principal,report_id,body['expectedRevision'])
                    elif len(segments)==4 and segments[3]=='moderation' and method=='POST': route='moderateReport'; data=self.service.moderate(principal,report_id,body)
                    elif len(segments)==4 and segments[3]=='evidence' and method=='POST': route='attachEvidence'; data=self.service.attach(principal,report_id,body)
                    elif len(segments)==4 and segments[3]=='evidence' and method=='GET':
                        route='readEvidence'; binary,media=self.service.evidence(principal,report_id); data=binary; extra=[('Content-Type',media)]
                    elif len(segments)==4 and segments[3]=='reopen' and method=='POST' and hasattr(self.service,'reopen'):
                        route='reopenReport'; data=self.service.reopen(principal,report_id,body)
                    else: raise APIError(404,'routeNotFound')
                elif len(segments)==4 and segments[:2]==['v1','issues'] and hasattr(self.service,'public_issues'):
                    route='issueAction'; issue_id,action=segments[2:]
                    methods={'confirmations':self.service.confirm,'disputes':self.service.dispute,'review':self.service.review_issue,'merge':self.service.merge,'unmerge':self.service.unmerge}
                    if method=='GET' and action=='history': data=self.service.issue_history(principal,issue_id)
                    elif method=='POST' and action in methods: data=methods[action](principal,issue_id,body)
                    else: raise APIError(404,'routeNotFound')
                else: raise APIError(404,'routeNotFound')
            payload = data if isinstance(data,bytes) else json.dumps(data,separators=(',',':'),allow_nan=False).encode()
        except APIError as error:
            status, payload, extra = error.status, json.dumps({'error':error.code,'requestID':request_id}).encode(), []
        except OSError:
            status, payload, extra = 503, json.dumps({'error':'storageUnavailable','requestID':request_id}).encode(), []
        except Exception:
            status, payload, extra = 500, json.dumps({'error':'internalError','requestID':request_id}).encode(), []
        names = {200:'OK',201:'Created',400:'Bad Request',401:'Unauthorized',403:'Forbidden',404:'Not Found',409:'Conflict',410:'Gone',413:'Payload Too Large',414:'URI Too Long',415:'Unsupported Media Type',429:'Too Many Requests',500:'Internal Server Error',503:'Service Unavailable'}
        headers=[('Cache-Control','no-store'),('X-Content-Type-Options','nosniff'),('Content-Length',str(len(payload))),('X-Request-ID',request_id)]
        if not any(k=='Content-Type' for k,_ in extra): headers.append(('Content-Type','application/json'))
        headers+=extra
        logger.info(json.dumps({'requestID':request_id,'route':route,'status':status}))
        start_response(str(status)+' '+names.get(status,'Error'),headers)
        return [payload]

    @staticmethod
    def _query(raw):
        require(len(raw)<=2048)
        try: parsed=parse_qs(raw,keep_blank_values=True,max_num_fields=12)
        except ValueError: raise APIError(400,'invalidQuery') from None
        require(all(len(v)==1 for v in parsed.values()))
        result={k:v[0] for k,v in parsed.items()}
        for key in ('minLat','minLon','maxLat','maxLon','latitude','longitude','limit'):
            if key in result:
                try: result[key]=float(result[key])
                except ValueError: raise APIError(400,'invalidQuery') from None
        return result
