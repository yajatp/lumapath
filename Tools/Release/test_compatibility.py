import copy
import csv
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

from audit import audit, ROOT
from compatibility import audit_compatibility, audit_built_app


class CompatibilityAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(ROOT / 'Evaluation/Compatibility', self.root / 'Evaluation/Compatibility')
        shutil.copytree(ROOT / 'LumaPath.xcodeproj', self.root / 'LumaPath.xcodeproj', ignore=shutil.ignore_patterns('xcuserdata'))
        for path in ['project.yml', 'Package.swift']:
            shutil.copy(ROOT / path, self.root / path)
        self.status = json.loads((ROOT / 'Evaluation/feature-status.json').read_text())
        with (ROOT / 'Evaluation/scenarios.csv').open() as file:
            self.scenarios = list(csv.DictReader(file))
        self.matrix = json.loads((self.root / 'Evaluation/Compatibility/matrix.json').read_text())

    def check(self):
        (self.root / 'Evaluation/Compatibility/matrix.json').write_text(json.dumps(self.matrix))
        return audit_compatibility(self.root, self.status, self.scenarios)

    def test_inventory_preserves_pending_acceptance(self):
        result = audit()
        self.assertEqual((result['requirements'], result['scenarios']), (23, 64))
        self.assertEqual(result['compatibility']['deviceVerifiedRows'], 0)
        self.assertFalse(result['compatibility']['readyForPairAcceptance'])
        self.assertEqual(result['releaseAcceptance'], 'pendingExternalEvidenceAndPairReview')

    def test_omitted_requirements_scenarios_context_and_device_categories_fail(self):
        for field in ['requirements', 'scenarios', 'context', 'category']:
            with self.subTest(field=field):
                status = copy.deepcopy(self.status)
                scenarios = copy.deepcopy(self.scenarios)
                matrix = copy.deepcopy(self.matrix)
                if field == 'requirements': self.status['requirements'].pop()
                if field == 'scenarios': self.scenarios.pop()
                if field == 'context': self.status['requirements'][0].pop('captureBackend')
                if field == 'category': self.matrix['rows'].pop(0)
                with self.assertRaises(ValueError): self.check()
                self.status, self.scenarios, self.matrix = status, scenarios, matrix

    def test_fixture_cannot_be_relabelled_as_verified_physical_evidence(self):
        self.matrix['rows'][-1]['status'] = 'deviceVerified'
        with self.assertRaises(ValueError): self.check()
        self.matrix['rows'][-1]['status'] = 'fixtureVerified'
        self.matrix['rows'][0]['status'] = 'deviceVerified'
        with self.assertRaises(ValueError): self.check()

    def test_premature_g9_and_unreviewed_scenario_pass_fail(self):
        self.matrix['gateStatus'] = 'passed'
        with self.assertRaises(ValueError): self.check()
        self.matrix['gateStatus'] = 'notEvaluated'
        self.matrix['scenarioResults'][0]['status'] = 'passed'
        next(r for r in self.scenarios if r['scenarioID'] == 'T49')['status'] = 'passed'
        with self.assertRaisesRegex(ValueError, 'Scenario pass requires'): self.check()

    def test_missing_and_outside_evidence_and_install_filters_fail(self):
        for path in ['missing.md', '../outside.md']:
            self.matrix['rows'][0]['evidencePaths'] = [path]
            with self.assertRaises(ValueError): self.check()
        self.matrix['rows'][0]['evidencePaths'] = []
        with (self.root / 'project.yml').open('a') as file:
            file.write('\nUIRequiredDeviceCapabilities: [arkit]\n')
        with self.assertRaises(ValueError): self.check()

    def test_compiled_metadata_checks_do_not_claim_os_install(self):
        info = dict(MinimumOSVersion='17.0', UIDeviceFamily=[1])
        plist = self.root / 'Info.plist'
        plist.write_bytes(plistlib.dumps(info))
        self.assertFalse(audit_built_app(self.root)['installedOnMinimumOS'])
        for changes in [dict(MinimumOSVersion='26.0'), dict(UIRequiredDeviceCapabilities=['arkit']),
                        dict(UIRequiredDeviceCapabilities={'arm64': False}), dict(UIDeviceFamily=[2])]:
            plist.write_bytes(plistlib.dumps(info | changes))
            with self.assertRaises(ValueError): audit_built_app(self.root)

    def test_deployment_source_generated_and_package_drift_fail(self):
        for path, old, new in [('project.yml', "iOS: '17.0'", "iOS: '26.0'"),
                               ('LumaPath.xcodeproj/project.pbxproj', '= 17.0;', '= 26.0;'),
                               ('Package.swift', '.iOS(.v17)', '.iOS(.v26)')]:
            file = self.root / path
            source = file.read_text()
            self.assertIn(old, source)
            file.write_text(source.replace(old, new))
            with self.assertRaises(ValueError): self.check()
            file.write_text(source)
