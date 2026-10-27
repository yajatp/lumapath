import csv
from datetime import datetime, timezone
import io
import json
import math
import secrets
from .schema import exact, number, require, revision, text, token, ReportInput
from .service import CommunityService, canonical, public_report
from dataclasses import asdict

VISIBLE = ('publishedUnverified','verified','disputed','resolved','reopened','expired')

def expiry(body):
    category = body['category']
    seconds = 7*86400 if category=='poorLighting' else 30*86400 if category in ('unevenSurface','damagedCurb','stairsIssue') else 86400
    if category=='entranceBarrier' and body['expectedPersistence']=='scheduled':
        schedule=body.get('restrictionSchedule')
        return min(body['observedAt']+7*86400,schedule['endsAt']) if schedule else body['observedAt']
    return body['observedAt']+seconds

def applicable(body, now):
    if expiry(body)<=now: return False
    if body['expectedPersistence']!='scheduled': return True
    schedule=body.get('restrictionSchedule')
    return bool(schedule and schedule['startsAt']<=now<schedule['endsAt']
                and datetime.fromtimestamp(now,timezone.utc).hour in schedule['applicableUTCHours'])


class IntelligenceService(CommunityService):
    def __init__(self,database,storage,clock=None):
        if clock is None: super().__init__(database,storage)
        else: super().__init__(database,storage,clock)
        # Backfill existing A9 reports transactionally; repeat startup is idempotent.
        with self.database.transaction() as db:
            for row in db.execute('SELECT id FROM reports WHERE deleted=0 AND id NOT IN (SELECT report_id FROM issue_members) ORDER BY created_at,id').fetchall():
                self._after_report_change(db,row['id'])
    def _members(self,db,issue_id):
        return db.execute('SELECT reports.* FROM reports JOIN issue_members ON report_id=reports.id WHERE issue_id=? AND deleted=0 ORDER BY created_at,reports.id',(issue_id,)).fetchall()
    def _issue(self,db,issue_id,allow_merged=False):
        token(issue_id); row=db.execute('SELECT * FROM issues WHERE id=?',(issue_id,)).fetchone()
        require(row is not None and (allow_merged or row['merged_into'] is None),404,'issueNotFound')
        return row
    def _issue_audit(self,db,issue_id,principal,action,reason):
        db.execute('INSERT INTO issue_audit(issue_id,actor_id,action,reason,at) VALUES(?,?,?,?,?)',(issue_id,principal.id,action,reason,self.clock()))
    def _refresh(self,db,issue_id):
        issue=self._issue(db,issue_id,allow_merged=True); members=self._members(db,issue_id)
        states=[r['status'] for r in members]
        state = next((s for s in ('reopened','disputed','verified','publishedUnverified') if s in states),None)
        if state is None:
            state='rejected' if states and all(s=='rejected' for s in states) else 'resolved' if 'resolved' in states else 'expired' if 'expired' in states else 'pendingReview' if members else 'withdrawn'
        relevant=[r for r in members if r['status']==state]
        if not relevant: relevant=members
        bodies=[json.loads(r['body']) for r in relevant]
        history=[json.loads(r['body']) for r in members if r['status'] in VISIBLE] or bodies
        first=min((b['observedAt'] for b in history),default=issue['first_observed'])
        last=max((b['observedAt'] for b in history),default=issue['last_observed'])
        end=max((expiry(b) for b in bodies),default=self.clock())
        values=(first,last,end,state)
        if values!=(issue['first_observed'],issue['last_observed'],issue['expires_at'],issue['status']):
            db.execute('UPDATE issues SET first_observed=?,last_observed=?,expires_at=?,status=?,revision=revision+1,updated_at=? WHERE id=?',(*values,self.clock(),issue_id))
            self._invalidate(db)
    def _after_report_change(self,db,report_id):
        row=db.execute('SELECT * FROM reports WHERE id=?',(report_id,)).fetchone()
        membership=db.execute('SELECT issue_id FROM issue_members WHERE report_id=?',(report_id,)).fetchone()
        if row['deleted']:
            if membership: self._refresh(db,membership['issue_id'])
            return
        body=json.loads(row['body']); end=expiry(body)
        db.execute('INSERT INTO report_applicability VALUES(?,?) ON CONFLICT(report_id) DO UPDATE SET active=excluded.active',(report_id,int(applicable(body,self.clock()))))
        old=membership['issue_id'] if membership else None
        if old:
            issue=self._issue(db,old,allow_merged=True)
            if (issue['category'],issue['segment_id'],issue['side'],issue['level'])==(body['category'],body['segmentID'],body['side'],body['level']):
                self._refresh(db,old); return
            db.execute('DELETE FROM issue_members WHERE report_id=?',(report_id,)); self._refresh(db,old)
        candidates=db.execute("SELECT * FROM issues WHERE category=? AND segment_id=? AND side=? AND level=? AND first_observed<=? AND expires_at>=? AND merged_into IS NULL AND status NOT IN ('resolved','withdrawn','rejected') ORDER BY first_observed,id",(body['category'],body['segmentID'],body['side'],body['level'],end,body['observedAt'])).fetchall()
        if candidates: issue_id=candidates[0]['id']
        else:
            issue_id=secrets.token_hex(16)
            db.execute('INSERT INTO issues(id,category,segment_id,side,level,latitude,longitude,first_observed,last_observed,expires_at,status,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                       (issue_id,body['category'],body['segmentID'],body['side'],body['level'],round(body['latitude'],3),round(body['longitude'],3),body['observedAt'],body['observedAt'],end,'pendingReview',self.clock()))
        db.execute('INSERT INTO issue_members VALUES(?,?)',(report_id,issue_id)); self._refresh(db,issue_id)
        db.execute('UPDATE issues SET revision=revision+1,updated_at=? WHERE id=?',(self.clock(),issue_id)); self._invalidate(db)
    def expire(self):
        with self.database.transaction() as db:
            changed=set()
            rows=db.execute("SELECT * FROM reports WHERE deleted=0 AND status IN ('publishedUnverified','verified','disputed','reopened')").fetchall()
            for row in rows:
                active=int(applicable(json.loads(row['body']),self.clock()))
                prior=db.execute('SELECT active FROM report_applicability WHERE report_id=?',(row['id'],)).fetchone()
                if prior is not None and prior['active']!=active:
                    member=db.execute('SELECT issue_id FROM issue_members WHERE report_id=?',(row['id'],)).fetchone()
                    if member:
                        db.execute('UPDATE issues SET revision=revision+1,updated_at=? WHERE id=?',(self.clock(),member['issue_id']))
                        db.execute('INSERT INTO issue_audit(issue_id,actor_id,action,reason,at) VALUES(?,?,?,?,?)',
                                   (member['issue_id'],'systemClock','applicabilityChanged','publicScheduleBoundary',self.clock()))
                        changed.add(member['issue_id'])
                db.execute('INSERT INTO report_applicability VALUES(?,?) ON CONFLICT(report_id) DO UPDATE SET active=excluded.active',(row['id'],active))
                if expiry(json.loads(row['body']))<=self.clock():
                    db.execute("UPDATE reports SET status='expired',revision=revision+1,updated_at=? WHERE id=?",(self.clock(),row['id']))
                    self._audit(db,row['id'],'systemExpiry','expired','conditionValidityElapsed')
                    membership=db.execute('SELECT issue_id FROM issue_members WHERE report_id=?',(row['id'],)).fetchone()
                    if membership: changed.add(membership['issue_id'])
            expired_confirmations=db.execute('SELECT DISTINCT issue_id FROM confirmations WHERE expires_at<=?',(self.clock(),)).fetchall()
            db.execute('DELETE FROM confirmations WHERE expires_at<=?',(self.clock(),))
            for row in expired_confirmations:
                root=self._issue(db,row['issue_id'],allow_merged=True)
                while root['merged_into'] is not None: root=self._issue(db,root['merged_into'],allow_merged=True)
                db.execute('UPDATE issues SET revision=revision+1,updated_at=? WHERE id=?',(self.clock(),root['id']))
                db.execute('INSERT INTO issue_audit(issue_id,actor_id,action,reason,at) VALUES(?,?,?,?,?)',
                           (root['id'],'systemExpiry','confirmationExpired','independentObservationValidityElapsed',self.clock()))
            for issue_id in changed: self._refresh(db,issue_id)
            if changed or expired_confirmations: self._invalidate(db)
    def moderate(self,principal,report_id,body):
        if isinstance(body,dict) and body.get('status') in ('verified','publishedUnverified'):
            with self.database.connect() as db:
                row=self._row(db,report_id)
                member=db.execute('SELECT issue_id FROM issue_members WHERE report_id=?',(report_id,)).fetchone()
                if member and principal.role=='moderator':
                    require(all(r['author_id']!=principal.id for r in self._members(db,member['issue_id'])),403,'selfModerationForbidden')
                require(expiry(json.loads(row['body']))>self.clock(),409,'freshObservationRequired')
        return super().moderate(principal,report_id,body)
    def _related_ids(self,db,issue_id):
        return [r[0] for r in db.execute('WITH RECURSIVE related(id) AS (SELECT ? UNION ALL SELECT issues.id FROM issues JOIN related ON issues.merged_into=related.id) SELECT id FROM related',(issue_id,))]
    def _projection(self,db,issue):
        related=self._related_ids(db,issue['id']); placeholders=','.join('?' for _ in related)
        members=self._members(db,issue['id']); authors={r['author_id'] for r in members if r['status'] in ('verified','publishedUnverified','disputed') and expiry(json.loads(r['body']))>self.clock()}
        confirmations={r[0] for r in db.execute('SELECT DISTINCT user_id FROM confirmations WHERE issue_id IN ('+placeholders+') AND expires_at>?',(*related,self.clock()))}
        contributors=[json.loads(r['body']) for r in members if r['status']==issue['status']]
        evidence_observed=max((b['observedAt'] for b in contributors),default=issue['last_observed'])
        applicable_now=any(applicable(b,self.clock()) for b in contributors) and issue['status'] in ('verified','publishedUnverified','disputed')
        boundaries=[]
        for b in contributors:
            if expiry(b)>self.clock(): boundaries.append(expiry(b))
            schedule=b.get('restrictionSchedule')
            if schedule:
                boundaries += [x for x in (schedule['startsAt'],schedule['endsAt'],(math.floor(self.clock()/3600)+1)*3600) if x>self.clock()]
        next_boundary=min(boundaries,default=self.clock()+300)
        return {'id':issue['id'],'applicableNow':applicable_now,'nextApplicabilityBoundary':next_boundary,'evidenceObservedAt':evidence_observed,'category':issue['category'],'segmentID':issue['segment_id'],'side':issue['side'],'level':issue['level'],
                'latitude':issue['latitude'],'longitude':issue['longitude'],'firstObservedAt':issue['first_observed'],'lastObservedAt':issue['last_observed'],
                'expiresAt':issue['expires_at'],'status':issue['status'],'revision':issue['revision'],'updatedAt':issue['updated_at'],
                'independentConfirmationCount':len(confirmations-authors),'independentObserverCount':len(confirmations|authors)}
    def public_issues(self,query=None):
        self.expire(); query=query or {}
        require(set(query)<=set(('minLat','minLon','maxLat','maxLon','latitude','longitude','sort','limit','status','category')))
        raw_limit=number(query.get('limit',100),1,100); require(raw_limit==int(raw_limit)); limit=int(raw_limit)
        sort=query.get('sort','recency'); require(sort in ('recency','distance'))
        box=None
        if any(k in query for k in ('minLat','minLon','maxLat','maxLon')):
            require(all(k in query for k in ('minLat','minLon','maxLat','maxLon')))
            box=tuple(number(query[k],-90 if 'Lat' in k else -180,90 if 'Lat' in k else 180) for k in ('minLat','minLon','maxLat','maxLon'))
            require(box[0]<=box[2] and box[1]<=box[3])
        if sort=='distance':
            latitude=number(query.get('latitude'),-90,90); longitude=number(query.get('longitude'),-180,180)
        if 'status' in query: require(query['status'] in VISIBLE)
        if 'category' in query:
            from .schema import CATEGORIES
            require(isinstance(query['category'],str) and query['category'] in CATEGORIES)
        with self.database.connect() as db:
            rows=db.execute("SELECT * FROM issues WHERE merged_into IS NULL AND status IN ('publishedUnverified','verified','disputed','resolved','reopened','expired') ORDER BY updated_at DESC,id").fetchall()
            items=[]
            for row in rows:
                if box and not (box[0]<=row['latitude']<=box[2] and box[1]<=row['longitude']<=box[3]): continue
                if 'status' in query and row['status']!=query['status']: continue
                if 'category' in query and row['category']!=query['category']: continue
                item=self._projection(db,row)
                if sort=='distance':
                    # Use generalized public coordinates; precise location cannot be recovered by repeated distance queries.
                    a,b=math.radians(latitude),math.radians(item['latitude']); dl=math.radians(item['longitude']-longitude)
                    h=math.sin((b-a)/2)**2+math.cos(a)*math.cos(b)*math.sin(dl/2)**2
                    item['distanceMeters']=2*6371000*math.asin(math.sqrt(min(1,h)))
                items.append(item)
            items.sort(key=lambda x:(x['distanceMeters'],x['id']) if sort=='distance' else (-x['updatedAt'],x['id']))
            version=db.execute("SELECT value FROM metadata WHERE key='public_version'").fetchone()[0]
            return {'schemaVersion':1,'version':version,'generatedAt':self.clock(),'issues':items[:limit],'truncated':len(items)>limit}
    def public_list(self):
        self.expire()
        with self.database.connect() as db:
            version=db.execute("SELECT value FROM metadata WHERE key='public_version'").fetchone()[0]
            rows=db.execute("SELECT reports.*,issues.status AS issue_status FROM reports JOIN issue_members ON reports.id=report_id JOIN issues ON issues.id=issue_id WHERE reports.deleted=0 AND reports.status IN ('publishedUnverified','verified','disputed') AND issues.merged_into IS NULL ORDER BY reports.updated_at DESC,reports.id LIMIT 100")
            items=[]
            for row in rows:
                item=public_report(row); item['status']=row['issue_status']; item['applicableNow']=applicable(json.loads(row['body']),self.clock()); items.append(item)
            return {'schemaVersion':1,'version':version,'reports':items}
    def confirm(self,principal,issue_id,body):
        exact(body,('observedAt',)); observed=number(body['observedAt'],self.clock()-86400,self.clock()); require(observed+86400>self.clock()); self.expire()
        with self.database.transaction() as db:
            issue=self._issue(db,issue_id); require(issue['status'] in ('verified','publishedUnverified','disputed') and self.clock()<issue['expires_at'],409,'issueNotCurrent')
            require(all(r['author_id']!=principal.id for r in self._members(db,issue_id)),409,'selfConfirmationNotIndependent')
            related=self._related_ids(db,issue_id); placeholders=','.join('?' for _ in related)
            previous=db.execute('SELECT * FROM confirmations WHERE issue_id IN ('+placeholders+') AND user_id=? AND expires_at>?',(*related,principal.id,self.clock())).fetchone()
            if previous: return self._projection(db,issue)
            db.execute('INSERT INTO confirmations VALUES(?,?,?,?)',(issue_id,principal.id,observed,min(observed+86400,issue['expires_at'])))
            db.execute('UPDATE issues SET revision=revision+1,updated_at=? WHERE id=?',(self.clock(),issue_id)); self._invalidate(db)
            self._issue_audit(db,issue_id,principal,'confirmed','independentObservationNotVerification')
            return self._projection(db,self._issue(db,issue_id))
    def dispute(self,principal,issue_id,body):
        exact(body,('expectedRevision','reason')); expected=revision(body['expectedRevision']); reason=text(body['reason'],500); self.expire()
        with self.database.transaction() as db:
            issue=self._issue(db,issue_id); require(issue['revision']==expected,409,'revisionConflict')
            require(issue['status'] in ('verified','publishedUnverified'),409,'issueNotCurrent')
            for row in self._members(db,issue_id):
                if row['status'] in ('verified','publishedUnverified'):
                    db.execute("UPDATE reports SET status='disputed',revision=revision+1,updated_at=? WHERE id=?",(self.clock(),row['id']))
                    self._audit(db,row['id'],principal.id,'disputed',reason)
            self._issue_audit(db,issue_id,principal,'disputed',reason); self._refresh(db,issue_id); self._invalidate(db)
            return self._projection(db,self._issue(db,issue_id))
    def review_issue(self,principal,issue_id,body):
        require(principal.role=='moderator',403,'moderatorRequired')
        exact(body,('expectedRevision','status','reason'),('evidenceReference',))
        expected=revision(body['expectedRevision']); reason=text(body['reason'],500)
        require(body['status'] in ('verified','publishedUnverified','resolved','rejected'))
        evidence=body.get('evidenceReference')
        if evidence is not None: token(evidence)
        if body['status']=='verified': require(evidence is not None,400,'verificationEvidenceRequired')
        self.expire()
        with self.database.transaction() as db:
            issue=self._issue(db,issue_id); require(issue['revision']==expected,409,'revisionConflict')
            members=self._members(db,issue_id); require(all(r['author_id']!=principal.id for r in members),403,'selfModerationForbidden')
            require(issue['status'] in ('disputed','reopened','publishedUnverified','verified'),409,'invalidTransition')
            for row in members:
                if body['status'] in ('verified','publishedUnverified'): require(expiry(json.loads(row['body']))>self.clock(),409,'freshObservationRequired')
                db.execute('UPDATE reports SET status=?,revision=revision+1,updated_at=? WHERE id=?',(body['status'],self.clock(),row['id']))
                self._audit(db,row['id'],principal.id,body['status'],reason,evidence)
            self._issue_audit(db,issue_id,principal,body['status'],reason); self._refresh(db,issue_id); self._invalidate(db)
            return self._projection(db,self._issue(db,issue_id))
    def reopen(self,principal,report_id,body):
        exact(body,('expectedRevision','report','evidenceReference')); expected=revision(body['expectedRevision']); token(body['evidenceReference'])
        report=ReportInput.parse(body['report'],self.clock())
        with self.database.transaction() as db:
            row=self._row(db,report_id); self._authorize(row,principal,owner_only=True)
            require(row['revision']==expected,409,'revisionConflict'); require(row['status']=='resolved',409,'resolvedReportRequired')
            old=json.loads(row['body']); new=asdict(report)
            require(report.observedAt>old['observedAt'] and expiry(new)>self.clock(),400,'newObservationRequired')
            require(all(new[k]==old[k] for k in ('category','segmentID','side','level')),400,'reopenLocationMismatch')
            db.execute("UPDATE reports SET body=?,status='reopened',revision=revision+1,updated_at=? WHERE id=?",(canonical(new),self.clock(),report_id))
            self._audit(db,report_id,principal.id,'reopened','newEvidenceReviewRequired',body['evidenceReference']); self._after_report_change(db,report_id); self._invalidate(db)
            return self._private(self._row(db,report_id))
    def merge(self,principal,target_id,body):
        require(principal.role=='moderator',403,'moderatorRequired')
        exact(body,('expectedRevision','sourceID','sourceRevision','reason')); expected=revision(body['expectedRevision']); source_revision=revision(body['sourceRevision']); reason=text(body['reason'],500)
        token(body['sourceID']); require(body['sourceID']!=target_id)
        with self.database.transaction() as db:
            target=self._issue(db,target_id); source=self._issue(db,body['sourceID'])
            require(target['revision']==expected and source['revision']==source_revision,409,'revisionConflict')
            require(all(source[k]==target[k] for k in ('category','segment_id','side','level')),409,'differentPublicIssue')
            require(source['first_observed']<=target['expires_at'] and target['first_observed']<=source['expires_at'],409,'nonoverlappingIssueWindow')
            members=self._members(db,source['id'])+self._members(db,target_id)
            require(all(r['author_id']!=principal.id for r in members),403,'selfModerationForbidden')
            ids=[r['id'] for r in self._members(db,source['id'])]
            db.execute('INSERT INTO issue_merges VALUES(?,?,?,0) ON CONFLICT(source_id) DO UPDATE SET target_id=excluded.target_id,report_ids=excluded.report_ids,undone=0',
                       (source['id'],target_id,canonical(ids)))
            db.execute('UPDATE issue_members SET issue_id=? WHERE issue_id=?',(target_id,source['id']))
            db.execute('UPDATE issues SET merged_into=?,revision=revision+1,updated_at=? WHERE id=?',(target_id,self.clock(),source['id']))
            self._refresh(db,target_id); db.execute('UPDATE issues SET revision=revision+1,updated_at=? WHERE id=?',(self.clock(),target_id))
            self._issue_audit(db,target_id,principal,'merged',reason); self._issue_audit(db,source['id'],principal,'mergedInto',reason); self._invalidate(db)
            return self._projection(db,self._issue(db,target_id))
    def unmerge(self,principal,source_id,body):
        require(principal.role=='moderator',403,'moderatorRequired')
        exact(body,('expectedRevision','targetRevision','reason')); expected=revision(body['expectedRevision']); target_revision=revision(body['targetRevision']); reason=text(body['reason'],500)
        with self.database.transaction() as db:
            source=self._issue(db,source_id,allow_merged=True); merge=db.execute('SELECT * FROM issue_merges WHERE source_id=? AND undone=0',(source_id,)).fetchone()
            require(merge is not None and source['merged_into']==merge['target_id'],409,'mergeUnavailable')
            target=self._issue(db,merge['target_id']); require(source['revision']==expected and target['revision']==target_revision,409,'revisionConflict')
            ids=json.loads(merge['report_ids'])
            require(all(r['author_id']!=principal.id for r in self._members(db,target['id'])),403,'selfModerationForbidden')
            for report_id in ids:
                row=db.execute('SELECT issue_id FROM issue_members WHERE report_id=?',(report_id,)).fetchone()
                require(row is not None and row['issue_id']==target['id'],409,'mergeMembershipChanged')
                db.execute('UPDATE issue_members SET issue_id=? WHERE report_id=?',(source_id,report_id))
            db.execute('UPDATE issues SET merged_into=NULL,revision=revision+1,updated_at=? WHERE id=?',(self.clock(),source_id))
            db.execute('UPDATE issue_merges SET undone=1 WHERE source_id=?',(source_id,))
            self._refresh(db,source_id); self._refresh(db,target['id'])
            db.execute('UPDATE issues SET revision=revision+1,updated_at=? WHERE id=?',(self.clock(),target['id']))
            self._issue_audit(db,source_id,principal,'unmerged',reason); self._issue_audit(db,target['id'],principal,'unmerged',reason); self._invalidate(db)
            return self._projection(db,self._issue(db,source_id))
    def issue_history(self,principal,issue_id):
        require(principal.role=='moderator',403,'moderatorRequired')
        with self.database.connect() as db:
            issue=self._issue(db,issue_id,allow_merged=True)
            return {'issue':self._projection(db,issue),'mergedInto':issue['merged_into'],'reportIDs':[r['id'] for r in self._members(db,issue_id)],'history':[dict(r) for r in db.execute('SELECT action,reason,at FROM issue_audit WHERE issue_id=? ORDER BY id',(issue_id,))]}
    def route_evidence(self,query=None):
        result=self.public_issues(query); generated=self.clock()
        mapping={'publishedUnverified':'unverified','verified':'verified','disputed':'disputed','expired':'expired','resolved':'resolved','reopened':'disputed'}
        items=[]
        for issue in result['issues']:
            items.append({'issueID':issue['id'],'revision':issue['revision'],'segmentID':issue['segmentID'],'side':issue['side'],'level':issue['level'],
                          'state':mapping[issue['status']] if issue['applicableNow'] or issue['status'] in ('expired','resolved','reopened') else 'inactive','observedAt':issue['evidenceObservedAt'],'expiresAt':issue['expiresAt'],
                          'verifiedBarrier':issue['status']=='verified' and issue['applicableNow'] and issue['category'] in ('sidewalkObstruction','entranceBarrier')})
        active_expiries=[x['expiresAt'] for x in items if x['expiresAt']>generated]
        return {'schemaVersion':1,'version':result['version'],'generatedAt':generated,'validUntil':min([generated+300]+active_expiries+[x['nextApplicabilityBoundary'] for x in result['issues']]),
                'complete':not result['truncated'],'coverage':'filtered' if query else 'allPublicIssues','issues':items}
    def civic_export(self,query=None,format='geojson'):
        require(format in ('geojson','csv','text')); result=self.public_issues(query)
        require(not result['truncated'],413,'narrowExportAreaOrFilters')
        fields=('issueID','category','segmentID','side','level','latitude','longitude','firstObservedAt','lastObservedAt','independentConfirmationCount','status','applicableNow')
        rows=[dict(zip(fields,(x['id'],x['category'],x['segmentID'],x['side'],x['level'],x['latitude'],x['longitude'],x['firstObservedAt'],x['lastObservedAt'],x['independentConfirmationCount'],x['status'],x['applicableNow']))) for x in result['issues']]
        if format=='geojson':
            return {'type':'FeatureCollection','schemaVersion':1,'evidenceVersion':result['version'],'features':[
                {'type':'Feature','geometry':{'type':'Point','coordinates':[r['longitude'],r['latitude']]},'properties':{k:v for k,v in r.items() if k not in ('latitude','longitude')}} for r in rows]}
        if format=='csv':
            output=io.StringIO(); writer=csv.DictWriter(output,fieldnames=fields); writer.writeheader()
            writer.writerows({k:("'"+v if isinstance(v,str) and v.startswith(('=','+','-','@')) else v) for k,v in r.items()} for r in rows)
            return output.getvalue()
        return '\n'.join(f"{r['category']} near public segment {r['segmentID']} ({r['side']}, {r['level']}): {r['status']} (currently applicable: {r['applicableNow']}); {r['independentConfirmationCount']} independent confirmations. First observed {datetime.fromtimestamp(r['firstObservedAt'],timezone.utc).isoformat()}, last observed {datetime.fromtimestamp(r['lastObservedAt'],timezone.utc).isoformat()}." for r in rows) or 'No public issues in selected area.'
