import json
from pathlib import Path
import tempfile
import unittest
from lumapath_service.auth import Principal
from lumapath_service.database import Database
from lumapath_service.intelligence import IntelligenceService
from lumapath_service.storage import LocalObjectStorage
from lumapath_service.assistance import AssistanceProxy
from lumapath_service.operations import backup,restore

class OperationsTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup); self.root=Path(self.temp.name)
        self.live=self.root/'live'; self.db=Database(self.live/'community.sqlite3'); self.storage=LocalObjectStorage(self.live/'objects')
        AssistanceProxy(self.db)
        self.service=IntelligenceService(self.db,self.storage)
        with self.db.transaction() as db:
            db.execute("INSERT INTO users VALUES('user','issuer','subject','moderator')")
            db.execute("INSERT INTO sessions VALUES('credential','user',9999999999)")

        self.user=Principal('user','user')
        import time
        report=self.service.create(self.user,dict(category='sidewalkObstruction',description='Synthetic fixture',segmentID='fixture',side='north',level='ground',latitude=41.,longitude=-87.,observedAt=time.time()-1,expectedPersistence='temporary',sourceMode='manualPublicLocation',publicLocationConfirmed=True),'fixture')[0]
        self.report_id=report['id']
    def test_backup_delete_restore_reapplies_deletion_and_revokes_sessions(self):
        snapshot=self.root/'snapshot'; backup(self.live,snapshot)
        self.service.delete(self.user,self.report_id,1)
        with self.db.transaction() as db: db.execute('INSERT INTO assistance_usage VALUES(1,500)')
        result=restore(snapshot,self.live,self.root/'restored')
        self.assertTrue(result['sessionsRevoked'])
        restored=Database(self.root/'restored/community.sqlite3')
        with restored.connect() as db:
            self.assertEqual(db.execute('SELECT deleted,body FROM reports').fetchone()[:],(1,'{}'))
            self.assertEqual(db.execute('SELECT COUNT(*) FROM sessions').fetchone()[0],0)
            self.assertEqual(db.execute('SELECT role FROM users').fetchone()[0],'user')
            self.assertEqual(db.execute('SELECT reserved FROM assistance_usage').fetchone()[0],500)
    def test_integrity_and_no_overwrite(self):
        snapshot=self.root/'snapshot'; backup(self.live,snapshot)
        with self.assertRaises(ValueError): backup(self.live,snapshot)
        (snapshot/'community.sqlite3').write_bytes(b'corrupt')
        with self.assertRaises(ValueError): restore(snapshot,self.live,self.root/'bad')
        self.assertFalse((self.root/'bad').exists())
    def test_private_evidence_restored_then_post_backup_delete_purged(self):
        key=self.storage.put(b'private fixture')
        with self.db.transaction() as db: db.execute('UPDATE reports SET evidence_key=?,evidence_type=?',(key,'image/png'))
        snapshot=self.root/'snapshot'; backup(self.live,snapshot)
        self.service.delete(self.user,self.report_id,1)
        restore(snapshot,self.live,self.root/'restored')
        self.assertEqual(list((self.root/'restored/objects').iterdir()),[])
    def test_traversal_and_missing_current_rejected(self):
        snapshot=self.root/'snapshot'; backup(self.live,snapshot)
        manifest=json.loads((snapshot/'manifest.json').read_text()); manifest['files']['../escape']='anything'
        (snapshot/'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError): restore(snapshot,self.live,self.root/'bad')
        with self.assertRaises(ValueError): restore(snapshot,self.root/'missing',self.root/'bad')
