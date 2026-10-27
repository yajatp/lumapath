import base64
from dataclasses import asdict
import hashlib
import json
import secrets
import time
from .schema import APIError, ReportInput, exact, require, revision, text, token
from .storage import validate_image

TRANSITIONS = {
    'pendingReview': {'publishedUnverified','verified','rejected','needsInformation'},
    'needsInformation': {'pendingReview','rejected'},
    'publishedUnverified': {'verified','disputed','expired','withdrawn'},
    'verified': {'disputed','resolved','expired','withdrawn'},
    'disputed': {'verified','resolved','rejected','expired'},
    'reopened': {'publishedUnverified','verified','rejected','needsInformation'},
    'resolved': set(), 'expired': set(), 'rejected': set(), 'withdrawn': set(),
}
PUBLIC_STATES = ('publishedUnverified','verified','disputed')

def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)

def public_report(row):
    body = json.loads(row['body'])
    # Whitelist controlled fields. No author, free text, evidence keys, sessions, or history of travel.
    return {'id':row['id'],'category':body['category'],'segmentID':body['segmentID'],'side':body['side'],'level':body['level'],
            'latitude':round(body['latitude'],3),'longitude':round(body['longitude'],3),'observedAt':body['observedAt'],
            'status':row['status'],'revision':row['revision'],'updatedAt':row['updated_at']}

class CommunityService:
    def __init__(self, database, storage, clock=time.time):
        self.database, self.storage, self.clock = database, storage, clock
    def limit(self, bucket, maximum=60, seconds=60):
        now = self.clock()
        with self.database.transaction() as db:
            db.execute('DELETE FROM rate_limits WHERE reset_at<=?',(now,))
            row = db.execute('SELECT reset_at,count FROM rate_limits WHERE bucket=?',(bucket,)).fetchone()
            count = row['count']+1 if row else 1
            reset_at = row['reset_at'] if row else now+seconds
            require(count<=maximum,429,'rateLimited')
            db.execute('INSERT INTO rate_limits VALUES(?,?,?) ON CONFLICT(bucket) DO UPDATE SET reset_at=excluded.reset_at,count=excluded.count',(bucket,reset_at,count))
    def _row(self,db,report_id):
        token(report_id)
        row = db.execute('SELECT * FROM reports WHERE id=? AND deleted=0',(report_id,)).fetchone()
        require(row is not None,404,'reportNotFound')
        return row
    def _authorize(self,row,principal,owner_only=False):
        require(row['author_id']==principal.id or (not owner_only and principal.role=='moderator'),403,'objectForbidden')
    def _audit(self,db,report_id,actor,action,reason,evidence=None):
        db.execute('INSERT INTO audit(report_id,actor_id,action,reason,evidence_reference,at) VALUES(?,?,?,?,?,?)',
                   (report_id,actor,action,reason,evidence,self.clock()))
    def _invalidate(self,db):
        db.execute("UPDATE metadata SET value=value+1 WHERE key='public_version'")
    def _after_report_change(self,db,report_id): pass
    def _private(self,row):
        return {'id':row['id'],'report':json.loads(row['body']),'status':row['status'],'revision':row['revision'],
                'createdAt':row['created_at'],'updatedAt':row['updated_at'],'hasPrivateEvidence':row['evidence_key'] is not None}
    def create(self,principal,body,key):
        self.limit('create:'+principal.id,20,3600)
        token(key); report = ReportInput.parse(body,self.clock())
        payload = canonical(asdict(report)); digest = hashlib.sha256(payload.encode()).hexdigest()
        with self.database.transaction() as db:
            prior = db.execute('SELECT * FROM idempotency WHERE user_id=? AND key=?',(principal.id,key)).fetchone()
            if prior:
                require(prior['digest']==digest,409,'idempotencyConflict')
                row = db.execute('SELECT * FROM reports WHERE id=?',(prior['report_id'],)).fetchone()
                require(row['deleted']==0,410,'reportDeleted')
                return self._private(row),False
            report_id, now = secrets.token_hex(16), self.clock()
            db.execute('INSERT INTO reports(id,author_id,body,status,revision,created_at,updated_at) VALUES(?,?,?,?,1,?,?)',
                       (report_id,principal.id,payload,'pendingReview',now,now))
            db.execute('INSERT INTO idempotency VALUES(?,?,?,?)',(principal.id,key,digest,report_id))
            self._audit(db,report_id,principal.id,'submitted','userReviewedPublicLocation'); self._after_report_change(db,report_id)
            return self._private(self._row(db,report_id)),True
    def read(self,principal,report_id):
        with self.database.connect() as db:
            row = self._row(db,report_id); self._authorize(row,principal)
            result = self._private(row)
            if principal.role=='moderator':
                result['audit'] = [dict(x) for x in db.execute('SELECT action,reason,evidence_reference,at FROM audit WHERE report_id=? ORDER BY id',(report_id,))]
            return result
    def edit(self,principal,report_id,body):
        exact(body,('expectedRevision','report'))
        expected = revision(body['expectedRevision']); parsed = ReportInput.parse(body['report'],self.clock())
        with self.database.transaction() as db:
            row = self._row(db,report_id); self._authorize(row,principal,owner_only=True)
            require(row['revision']==expected,409,'revisionConflict')
            require(row['status'] not in ('withdrawn','rejected'),409,'reportTerminal')
            db.execute('UPDATE reports SET body=?,status=?,revision=revision+1,updated_at=? WHERE id=?',
                       (canonical(asdict(parsed)),'pendingReview',self.clock(),report_id))
            self._audit(db,report_id,principal.id,'edited','reviewRequiredAfterEdit'); self._after_report_change(db,report_id); self._invalidate(db)
            return self._private(self._row(db,report_id))
    def moderate(self,principal,report_id,body):
        require(principal.role=='moderator',403,'moderatorRequired')
        exact(body,('expectedRevision','status','reason'),('evidenceReference',))
        expected, reason = revision(body['expectedRevision']), text(body['reason'],500)
        require(isinstance(body['status'],str))
        evidence = body.get('evidenceReference')
        if evidence is not None: token(evidence)
        with self.database.transaction() as db:
            row = self._row(db,report_id)
            require(row['author_id']!=principal.id,403,'selfModerationForbidden')
            require(row['revision']==expected,409,'revisionConflict')
            require(body['status'] in TRANSITIONS.get(row['status'],set()),409,'invalidTransition')
            if body['status']=='verified': require(evidence is not None,400,'verificationEvidenceRequired')
            db.execute('UPDATE reports SET status=?,revision=revision+1,updated_at=? WHERE id=?',(body['status'],self.clock(),report_id))
            self._audit(db,report_id,principal.id,body['status'],reason,evidence); self._after_report_change(db,report_id); self._invalidate(db)
            return self._private(self._row(db,report_id))
    def queue(self,principal,limit=100):
        require(principal.role=='moderator',403,'moderatorRequired')
        with self.database.connect() as db:
            return [self._private(r) for r in db.execute("SELECT * FROM reports WHERE deleted=0 AND status IN ('pendingReview','needsInformation','disputed','reopened') ORDER BY CASE WHEN json_extract(body,'$.category') IN ('sidewalkObstruction','entranceBarrier') THEN 0 ELSE 1 END,created_at,id LIMIT ?",(limit,))]
    def attach(self,principal,report_id,body):
        exact(body,('expectedRevision','reviewed','mediaType','base64'))
        expected = revision(body['expectedRevision']); require(body['reviewed'] is True)
        require(isinstance(body['base64'],str) and len(body['base64'])<=1_400_000,413,'evidenceBudget')
        try: data = base64.b64decode(body['base64'],validate=True)
        except Exception: raise APIError(400,'invalidEvidenceEncoding') from None
        validate_image(data,body['mediaType'])
        new_key = None
        try:
            with self.database.transaction() as db:
                row = self._row(db,report_id); self._authorize(row,principal,owner_only=True)
                require(row['revision']==expected,409,'revisionConflict')
                require(row['evidence_key'] is None,409,'evidenceAlreadyAttached')
                require(row['status'] not in ('withdrawn','rejected'),409,'reportTerminal')
                new_key = self.storage.put(data)
                db.execute('UPDATE reports SET evidence_key=?,evidence_type=?,status=?,revision=revision+1,updated_at=? WHERE id=?',
                           (new_key,body['mediaType'],'pendingReview',self.clock(),report_id))
                self._audit(db,report_id,principal.id,'evidenceAttached','userReviewedMetadataFreeArtifact'); self._after_report_change(db,report_id); self._invalidate(db)
                return self._private(self._row(db,report_id))
        except Exception:
            if new_key is not None:
                try: self.storage.delete(new_key)
                except Exception: pass # Maintenance reconciles orphaned immutable objects after a crash/failure.
            raise
    def evidence(self,principal,report_id):
        with self.database.connect() as db:
            row = self._row(db,report_id); self._authorize(row,principal)
            require(row['evidence_key'] is not None,404,'evidenceNotFound')
            try: return self.storage.read(row['evidence_key']),row['evidence_type']
            except OSError: raise APIError(503,'evidenceStorageUnavailable') from None
    def delete(self,principal,report_id,expected):
        revision(expected)
        with self.database.transaction() as db:
            row = self._row(db,report_id); self._authorize(row,principal,owner_only=True)
            require(row['revision']==expected,409,'revisionConflict')
            db.execute('UPDATE reports SET deleted=1,status=?,revision=revision+1,updated_at=? WHERE id=?',('withdrawn',self.clock(),report_id))
            db.execute('INSERT INTO deletion_jobs(id,report_id,object_key) VALUES(?,?,?)',(secrets.token_hex(16),report_id,row['evidence_key']))
            self._audit(db,report_id,principal.id,'deleted','ownerRequestedDeletion'); self._after_report_change(db,report_id); self._invalidate(db)
        self.run_deletions()
        return {'deleted':True,'privateDeletion':'queuedOrCompleted'}
    def run_deletions(self):
        with self.database.connect() as db:
            jobs = [dict(r) for r in db.execute('SELECT * FROM deletion_jobs WHERE completed=0 LIMIT 100')]
        for job in jobs:
            try:
                if job['object_key']: self.storage.delete(job['object_key'])
                with self.database.transaction() as db:
                    db.execute('UPDATE reports SET body=?,evidence_key=NULL,evidence_type=NULL WHERE id=?',('{}',job['report_id']))
                    db.execute('UPDATE audit SET reason=?,evidence_reference=NULL WHERE report_id=?',('redactedAfterDeletion',job['report_id']))
                    db.execute('UPDATE deletion_jobs SET completed=1,object_key=NULL,attempts=attempts+1 WHERE id=?',(job['id'],))
            except Exception:
                with self.database.transaction() as db: db.execute('UPDATE deletion_jobs SET attempts=attempts+1 WHERE id=?',(job['id'],))
    def public_list(self):
        with self.database.connect() as db:
            version = db.execute("SELECT value FROM metadata WHERE key='public_version'").fetchone()[0]
            rows = db.execute("SELECT * FROM reports WHERE deleted=0 AND status IN ('publishedUnverified','verified','disputed') ORDER BY updated_at DESC,id LIMIT 100")
            return {'schemaVersion':1,'version':version,'reports':[public_report(row) for row in rows]}
    def health(self):
        with self.database.connect() as db: db.execute('SELECT 1').fetchone()
        return {'status':'ok','schemaVersion':1,'deployment':'localOrStagingNotProductionAcceptance'}
