import copy
import hashlib
import json
import unittest
from analyze import analyze

class StudyTests(unittest.TestCase):
    def setUp(self):
        self.config=dict(schemaVersion=1,methods=['baseline','current'])
        fingerprint=hashlib.sha256(json.dumps(self.config,sort_keys=True).encode()).hexdigest()
        common=dict(category='geometry',configurationSHA256=fingerprint,origin='synthetic',heldOut=True,sessionID='s1',environmentID='e1',device='fixture',os='fixture',groundTruthReference='fixture',exclusionReason='',falseActivation=False,hardConstraintViolation=False,errorMeters=None,intervalCovered=None)
        self.rows=[]
        for trial,expected in [('positive',True),('negative',False)]:
            for method in self.config['methods']:
                self.rows.append(common|dict(trialID=trial,method=method,available=method=='baseline',expectedPositive=expected,detected=True,negativeMinutes=0 if expected else 60,falseAlerts=0 if expected else 3,latencyMs=20))
    def test_unavailable_stays_in_recall_and_denominators(self):
        result=analyze(self.rows,self.config); current=result['results']['geometry']['current']
        self.assertEqual(current['recall'],0); self.assertEqual(current['misses'],1); self.assertEqual(current['unavailable'],2)
        self.assertEqual(current['falseAlertsPerMinute'],.05); self.assertFalse(result['liveActivation'])
        self.assertIsNone(result['results']['prediction']['current']['recall'])
    def test_exclusions_visible_but_not_counted_as_success(self):
        for row in self.rows[:2]: row['exclusionReason']='rig failure'
        result=analyze(self.rows,self.config)['results']['geometry']['current']
        self.assertEqual(result['exclusions'],{'rig failure':1}); self.assertEqual(result['positiveTrials'],0); self.assertIsNone(result['recall'])
    def test_unpaired_duplicate_mixed_and_mismatched_rejected(self):
        with self.assertRaises(ValueError): analyze(self.rows[:-1],self.config)
        with self.assertRaises(ValueError): analyze(self.rows+[self.rows[0]],self.config)
        for changes in [dict(configurationSHA256='wrong'),dict(origin='physical'),dict(negativeMinutes=-1),dict(latencyMs=float('nan')),dict(device='other'),dict(heldOut=False)]:
            rows=copy.deepcopy(self.rows); rows[0].update(changes)
            with self.assertRaises(ValueError): analyze(rows,self.config)
