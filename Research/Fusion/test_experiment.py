import copy
import json
from pathlib import Path
import tempfile
import unittest
from experiment import fixture,run,validate

class FusionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); self.manifest=self.root/'rows.jsonl'; fixture(self.manifest)
        self.rows=[json.loads(line) for line in self.manifest.read_text().splitlines()]
    def test_split_consent_and_feature_validation(self):
        for key in ('environmentID','sessionID','sourceID'):
            rows=copy.deepcopy(self.rows); rows[-1][key]=rows[0][key]
            with self.assertRaises(ValueError): validate(rows,True)
        with self.assertRaises(ValueError): validate(self.rows,False)
        for value in (float('nan'),1.1,True):
            rows=copy.deepcopy(self.rows); rows[0]['features']['coverage']=value
            with self.assertRaises(ValueError): validate(rows,True)
        rows=copy.deepcopy(self.rows)
        for row in rows: row['synthetic']=False
        with self.assertRaises(ValueError): validate(rows,False)
        for row in rows: row.update(consent=True,consentRecord='private-consent-record',license='consented-research-only')
        validate(rows,False)
    def test_reproducible_experiment_stays_research(self):
        report=run(self.manifest,self.root/'one',True); run(self.manifest,self.root/'two',True)
        self.assertEqual((self.root/'one/model.json').read_bytes(),(self.root/'two/model.json').read_bytes())
        self.assertEqual(report['decision'],'pendingRealData'); self.assertFalse(report['liveActivation'])
        self.assertEqual(report['learned']['count'],96)
    def test_test_labels_cannot_tune_model(self):
        run(self.manifest,self.root/'one',True)
        for row in self.rows:
            if row['split']=='test': row['supported']=1-row['supported']
        self.manifest.write_text('\n'.join(json.dumps(r) for r in self.rows)); run(self.manifest,self.root/'two',True)
        a=json.loads((self.root/'one/model.json').read_text()); b=json.loads((self.root/'two/model.json').read_text())
        self.assertEqual(a['weights'],b['weights']); self.assertEqual(a['temperature'],b['temperature'])
