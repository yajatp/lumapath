import json
from lumapath_service.http import Application
from lumapath_service.intelligence import IntelligenceService, expiry
import test_service as fixtures

class IntelligenceTest(fixtures.ServiceTest):
    """Re-run A9 boundaries on the actual A10 service, then test lifecycle/aggregation."""
    def setUp(self):
        super().setUp(); self.service=IntelligenceService(self.db,self.storage,self.clock); self.app=Application(self.service,self.identity)
    def issue(self): return self.service.public_issues()['issues'][0]
    def test_expiry_downgrades_routing_and_invalidates_public_cache(self):
        self.publish(self.create()); before=self.service.route_evidence(); self.assertTrue(before['issues'][0]['verifiedBarrier'])
        self.now+=86401
        after=self.service.route_evidence(); self.assertEqual(after['issues'][0]['state'],'expired'); self.assertFalse(after['issues'][0]['verifiedBarrier'])
        self.assertGreater(after['version'],before['version']); self.assertEqual(self.service.public_list()['reports'],[])
        self.assertEqual(self.service.public_issues()['issues'][0]['independentObserverCount'],0)
    def test_category_expiry_windows_do_not_accept_user_extended_claims(self):
        for category,expected in [('sidewalkObstruction',86400),('poorLighting',7*86400),('damagedCurb',30*86400),('entranceBarrier',7*86400)]:
            body=self.report(category=category,expectedPersistence='scheduled' if category=='entranceBarrier' else 'structural',restrictionSchedule=dict(startsAt=self.now-100,endsAt=self.now-10+7*86400,applicableUTCHours=list(range(24))) if category=='entranceBarrier' else None)
            self.assertEqual(expiry(body)-body['observedAt'],expected)
    def test_duplicates_and_repeat_confirmations_do_not_inflate_independence_or_verify(self):
        self.publish(self.create('one'),status='publishedUnverified'); self.publish(self.create('two'),status='publishedUnverified')
        other=self.service.create(self.other,self.report(),'other-draft')[0]; self.publish(other,status='publishedUnverified')
        issue=self.issue(); self.assertEqual(len(self.service.public_issues()['issues']),1); self.assertEqual(issue['independentObserverCount'],2)
        self.error(409,lambda:self.service.confirm(self.author,issue['id'],{'observedAt':self.now}))
        observer,_=self.login('independent-observer')
        first=self.service.confirm(observer,issue['id'],{'observedAt':self.now}); repeated=self.service.confirm(observer,issue['id'],{'observedAt':self.now})
        self.assertEqual(first['revision'],repeated['revision']); self.assertEqual(repeated['independentConfirmationCount'],1)
        self.assertEqual(repeated['status'],'publishedUnverified')
    def test_same_coordinates_different_sides_levels_categories_remain_distinct(self):
        for index,changes in enumerate([{},dict(side='south'),dict(level='upper'),dict(category='poorLighting')]):
            self.publish(self.create('draft-'+str(index),**changes))
        self.assertEqual(len(self.service.public_issues()['issues']),4)
    def test_dispute_removes_verified_route_influence_and_review_is_audited(self):
        self.publish(self.create()); issue=self.issue(); old_version=self.service.route_evidence()['version']
        disputed=self.service.dispute(self.other,issue['id'],dict(expectedRevision=issue['revision'],reason='Current obstruction is uncertain'))
        self.assertEqual(disputed['status'],'disputed'); self.assertFalse(self.service.route_evidence()['issues'][0]['verifiedBarrier'])
        self.assertGreater(self.service.route_evidence()['version'],old_version)
        self.error(403,lambda:self.service.review_issue(self.author,issue['id'],dict(expectedRevision=disputed['revision'],status='verified',reason='self')))
        reviewed=self.service.review_issue(self.mod,issue['id'],dict(expectedRevision=disputed['revision'],status='verified',reason='Independent current survey',evidenceReference='survey-new'))
        self.assertEqual(reviewed['status'],'verified'); self.assertTrue(self.service.route_evidence()['issues'][0]['verifiedBarrier'])
        history=self.service.issue_history(self.mod,issue['id']); self.assertEqual([x['action'] for x in history['history']],['disputed','verified'])
        self.error(403,lambda:self.service.issue_history(self.other,issue['id']))
    def test_resolved_issue_reopens_only_with_new_observation_and_new_review(self):
        report=self.publish(self.create()); issue=self.issue()
        resolved=self.service.review_issue(self.mod,issue['id'],dict(expectedRevision=issue['revision'],status='resolved',reason='Observed removed'))
        report=self.service.read(self.author,report['id']); self.assertEqual(resolved['status'],'resolved')
        self.error(400,lambda:self.service.reopen(self.author,report['id'],dict(expectedRevision=report['revision'],report=report['report'],evidenceReference='new-claim')))
        self.now+=30
        new=self.report(description='New obstruction observed',observedAt=self.now-1)
        reopened=self.service.reopen(self.author,report['id'],dict(expectedRevision=report['revision'],report=new,evidenceReference='new-reviewed-observation'))
        self.assertEqual(reopened['status'],'reopened'); self.assertEqual(self.service.route_evidence()['issues'][0]['state'],'disputed')
        issue=self.issue(); reviewed=self.service.review_issue(self.mod,issue['id'],dict(expectedRevision=issue['revision'],status='verified',reason='Reviewed new evidence',evidenceReference='new-survey'))
        self.assertEqual(reviewed['status'],'verified')
    def test_public_queries_export_and_distance_use_only_generalized_public_fields(self):
        self.publish(self.create(description='secret person alice@example.test'))
        query={'minLat':41,'maxLat':42,'minLon':-88,'maxLon':-87,'sort':'distance','latitude':41.88,'longitude':-87.62}
        result=self.service.public_issues(query); self.assertEqual(len(result['issues']),1); self.assertGreater(result['issues'][0]['distanceMeters'],0)
        for format in ['geojson','csv','text']:
            export=self.service.civic_export(query,format); encoded=json.dumps(export)
            for secret in [self.author.id,'alice@example.test','description','evidence_key','actor_id']: self.assertNotIn(secret,encoded)
        self.assertEqual(self.service.public_issues({'minLat':0,'maxLat':1,'minLon':0,'maxLon':1})['issues'],[])
        self.error(400,lambda:self.service.public_issues({'sort':'distance','latitude':float('nan'),'longitude':0}))
    def test_deletion_removes_issue_projection_and_invalidates_evidence_version(self):
        report=self.publish(self.create()); before=self.service.route_evidence()['version']
        self.service.delete(self.author,report['id'],report['revision'])
        self.assertEqual(self.service.public_issues()['issues'],[]); self.assertEqual(self.service.route_evidence()['issues'],[])
        self.assertGreater(self.service.route_evidence()['version'],before)
    def test_manual_merge_can_be_undone_and_confirmation_aliases_count_once(self):
        observer,_=self.login('observer')
        first=self.publish(self.create('old')); source=self.issue(); self.service.confirm(observer,source['id'],{'observedAt':self.now})
        source=self.issue(); self.service.review_issue(self.mod,source['id'],dict(expectedRevision=source['revision'],status='resolved',reason='Was resolved'))
        other=self.service.create(self.other,self.report(observedAt=self.now-5),'new')[0]; self.publish(other)
        issues=self.service.public_issues()['issues']; target=next(x for x in issues if x['id']!=source['id']); source=next(x for x in issues if x['id']==source['id'])
        target=self.service.confirm(observer,target['id'],{'observedAt':self.now})
        merged=self.service.merge(self.mod,target['id'],dict(expectedRevision=target['revision'],sourceID=source['id'],sourceRevision=source['revision'],reason='Same reviewed issue'))
        self.assertEqual(merged['independentConfirmationCount'],1)
        repeated=self.service.confirm(observer,target['id'],{'observedAt':self.now}); self.assertEqual(repeated['revision'],merged['revision'])
        source_revision=self.service.issue_history(self.mod,source['id'])['issue']['revision']
        self.service.unmerge(self.mod,source['id'],dict(expectedRevision=source_revision,targetRevision=merged['revision'],reason='Separate occurrences'))
        self.assertEqual(len(self.service.public_issues()['issues']),2)
    def test_different_side_merge_is_rejected_even_at_same_coordinates(self):
        self.publish(self.create('north')); self.publish(self.create('south',side='south'))
        a,b=self.service.public_issues()['issues']
        self.error(409,lambda:self.service.merge(self.mod,a['id'],dict(expectedRevision=a['revision'],sourceID=b['id'],sourceRevision=b['revision'],reason='Nearby')))
    def test_http_intelligence_routes_and_csv_do_not_publish_private_evidence(self):
        self.publish(self.create()); issue=self.issue()
        result=self.request('GET','/v1/public/issues'); self.assertEqual(result['status'],200)
        self.assertEqual(self.request('GET','/v1/public/route-evidence')['body']['issues'][0]['state'],'verified')
        exported=self.request('GET','/v1/public/civic-export',QUERY_STRING='format=csv')
        self.assertEqual(exported['status'],200); self.assertTrue(exported['headers']['Content-Type'].startswith('text/csv'))
        self.assertEqual(self.request('GET','/v1/issues/'+issue['id']+'/history',authorization=self.other_auth)['status'],403)
    def test_expired_confirmations_invalidate_cache_without_refreshing_condition(self):
        report=self.publish(self.create(category='damagedCurb')); issue=self.issue(); observer,_=self.login('observer')
        self.service.confirm(observer,issue['id'],{'observedAt':self.now}); before=self.service.route_evidence()['version']
        self.now+=86401
        current=self.issue(); self.assertEqual(current['independentConfirmationCount'],0); self.assertEqual(current['status'],'verified')
        self.assertGreater(self.service.route_evidence()['version'],before)

    def test_existing_a9_database_migrates_without_losing_reports_and_backfills_issues(self):
        import sqlite3
        from pathlib import Path
        from lumapath_service.database import Database
        file=self.root/'legacy'/'database.sqlite3'; file.parent.mkdir()
        connection=sqlite3.connect(file)
        connection.executescript((Path(__file__).resolve().parents[1]/'migrations'/'001_initial.sql').read_text())
        connection.execute('INSERT INTO users(id,issuer,subject) VALUES(?,?,?)',('legacy-author','https://identity.example','legacy'))
        connection.execute('INSERT INTO reports(id,author_id,body,status,revision,created_at,updated_at) VALUES(?,?,?,?,1,?,?)',
                           ('legacy-report','legacy-author',json.dumps(self.report()),'verified',self.now,self.now))
        connection.commit(); connection.close()
        migrated=Database(file); service=IntelligenceService(migrated,self.storage,self.clock)
        self.assertEqual(len(service.public_issues()['issues']),1)
        with migrated.connect() as db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0],2)
            self.assertEqual(db.execute('SELECT id FROM reports').fetchone()[0],'legacy-report')

    def test_scheduled_entrance_is_inactive_outside_hours_and_feed_expires_at_boundary(self):
        from datetime import datetime,timezone
        hour=datetime.fromtimestamp(self.now,timezone.utc).hour
        boundary=(int(self.now)//3600+1)*3600
        self.now=boundary-30
        schedule=dict(startsAt=self.now-100,endsAt=self.now+86400,applicableUTCHours=[hour])
        self.publish(self.create(category='entranceBarrier',expectedPersistence='scheduled',restrictionSchedule=schedule))
        before=self.service.route_evidence(); self.assertTrue(before['issues'][0]['verifiedBarrier']); self.assertEqual(before['validUntil'],boundary)
        self.now=boundary+1
        after=self.service.route_evidence(); self.assertEqual(after['issues'][0]['state'],'inactive'); self.assertFalse(after['issues'][0]['verifiedBarrier'])
        self.assertGreater(after['version'],before['version']); self.assertGreater(after['issues'][0]['revision'],before['issues'][0]['revision'])
    def test_schedule_requires_explicit_bounds_and_cannot_extend_beyond_seven_days(self):
        self.error(400,lambda:self.create(category='entranceBarrier',expectedPersistence='scheduled'))
        schedule=dict(startsAt=self.now,endsAt=self.now+8*86400,applicableUTCHours=[12])
        self.error(400,lambda:self.create(category='entranceBarrier',expectedPersistence='scheduled',restrictionSchedule=schedule))

    def test_operational_logs_omit_credentials_query_strings_and_private_report_text(self):
        with self.assertLogs('lumapath.requests',level='INFO') as captured:
            self.request('POST','/v1/reports',self.report(description='private contact person@example.test'),self.author_auth,HTTP_IDEMPOTENCY_KEY='private-log-key')
            self.request('GET','/v1/public/issues',QUERY_STRING='sort=distance&latitude=41&longitude=-87')
        log=' '.join(captured.output)
        for value in ('person@example.test',self.author_auth,'private-log-key','latitude=41',self.author.id): self.assertNotIn(value,log)

    def test_real_clock_feed_lifetime_never_exceeds_swift_300_second_contract(self):
        service=IntelligenceService(self.db,self.storage)
        for _ in range(3):
            feed=service.route_evidence()
            self.assertGreater(feed['validUntil'],feed['generatedAt'])
            self.assertLessEqual(feed['validUntil']-feed['generatedAt'],300)

    def test_mixed_schedule_cannot_extend_an_active_temporary_barrier_past_expiry(self):
        self.now=(int(self.now)//3600)*3600+1000
        from datetime import datetime,timezone
        hour=datetime.fromtimestamp(self.now,timezone.utc).hour
        self.publish(self.create('temporary',category='entranceBarrier',observedAt=self.now-86400+20))
        schedule=dict(startsAt=self.now-100,endsAt=self.now+86400,applicableUTCHours=[(hour+1)%24])
        self.publish(self.create('scheduled',category='entranceBarrier',expectedPersistence='scheduled',restrictionSchedule=schedule))
        before=self.service.route_evidence(); self.assertTrue(before['issues'][0]['verifiedBarrier'])
        self.assertEqual(before['validUntil'],self.now+20)
        self.now+=21
        after=self.service.route_evidence(); self.assertEqual(after['issues'][0]['state'],'inactive'); self.assertFalse(after['issues'][0]['verifiedBarrier'])
