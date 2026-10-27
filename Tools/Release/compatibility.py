"""Validate compatibility inventory without promoting fixture results to physical acceptance."""
import json
import plistlib
import re

REQUIRED_CONTEXT = {
    'deviceModel', 'osVersion', 'capabilityProfile', 'captureBackend', 'performancePreset',
    'capabilityRevision', 'permissionState', 'thermalState',
}
PHYSICAL_CATEGORIES = {
    'oldestSupported', 'compactHomeButton', 'olderNonLiDAR', 'recentNonLiDAR', 'olderLiDAR', 'recentLiDAR',
}
COMPATIBILITY_SCENARIOS = {f'T{i}' for i in range(49, 65)}


def evidence_files(root, paths):
    if not isinstance(paths, list):
        raise ValueError('Evidence paths must be a list')
    for path in paths:
        target = root / path
        if not target.resolve().is_relative_to(root.resolve()) or not target.is_file():
            raise ValueError('Missing/outside compatibility evidence: ' + path)


def audit_compatibility(root, status, scenarios):
    if status['schemaVersion'] != 3:
        raise ValueError('Feature inventory schema 3 required')
    requirements = status['requirements']
    if {r['requirementID'] for r in requirements} != {f'R{i:02}' for i in range(1, 24)} or len(requirements) != 23:
        raise ValueError('Exactly R01–R23 required')
    if {r['scenarioID'] for r in scenarios} != {f'T{i:02}' for i in range(1, 65)} or len(scenarios) != 64:
        raise ValueError('Exactly T01–T64 required')
    for item in requirements + status['capabilities']:
        if not REQUIRED_CONTEXT.issubset(item):
            raise ValueError('Missing compatibility context in feature inventory')
    matrix = json.loads((root / 'Evaluation/Compatibility/matrix.json').read_text())
    if matrix['schemaVersion'] != 1 or matrix['minimumOS'] != '17.0':
        raise ValueError('Review deployment-floor schema/policy change')
    rows = matrix['rows']
    if any(row['environment'] not in {'physical', 'simulator', 'injected'} for row in rows):
        raise ValueError('Invalid matrix environment')
    if len({r['id'] for r in rows}) != len(rows):
        raise ValueError('Duplicate matrix row')
    physical = [r for r in rows if r['environment'] == 'physical']
    if not PHYSICAL_CATEGORIES.issubset({r['category'] for r in physical}):
        raise ValueError('Missing required physical representative')
    required_identity = {'deviceModel', 'osVersion', 'operator', 'date', 'sourceCommit', 'configVersion',
                         'capabilityProfile', 'captureBackend', 'performancePreset', 'capabilityRevision',
                         'permissionState', 'thermalState', 'reviewedBy'}
    for row in rows:
        if row['status'] not in {'planned', 'fixtureVerified', 'deviceVerified', 'failed', 'blocked'}:
            raise ValueError('Invalid matrix status')
        evidence_files(root, row['evidencePaths'])
        if row['status'] == 'deviceVerified' and (
            row['environment'] != 'physical' or not row['evidencePaths'] or
            any(row.get(key) is None or row.get(key) == '' for key in required_identity)
        ):
            raise ValueError('Physical verification requires hardware identity, operator, review and evidence')
    results = matrix['scenarioResults']
    if {r['scenarioID'] for r in results} != COMPATIBILITY_SCENARIOS or len(results) != 16:
        raise ValueError('Exactly T49–T64 matrix results required')
    for result in results:
        evidence_files(root, result['evidencePaths'])
        scenario = next(row for row in scenarios if row['scenarioID'] == result['scenarioID'])
        if scenario.get('status') != result['status'] or scenario['resultPath'] not in result['evidencePaths']:
            raise ValueError('Scenario CSV and compatibility matrix disagree')
        if result['status'] not in {'notRun', 'partialSoftware', 'failed', 'passed'}:
            raise ValueError('Invalid compatibility scenario status')
        if result['status'] == 'passed' and (not result.get('reviewedBy') or not result['evidencePaths']):
            raise ValueError('Scenario pass requires review and evidence')
    if not matrix['targetOSVersions'] or matrix['minimumOS'] not in matrix['targetOSVersions']:
        raise ValueError('Minimum OS must be represented in target OS trials')
    ready = (not matrix['floorDecisionPending'] and bool(physical)
             and all(row['status'] == 'deviceVerified' for row in physical)
             and set(matrix['targetOSVersions']).issubset({row['osVersion'] for row in physical})
             and {'Yajat', 'Aarav'}.issubset(matrix['reviewedBy'] or [])
             and all(r['status'] == 'passed' for r in results))
    requirement = next(r for r in requirements if r['requirementID'] == 'R23')
    if (matrix['gateStatus'] == 'passed' or requirement['gateStatus'] == 'passed') and not ready:
        raise ValueError('G9 cannot pass with pending device/scenario/floor evidence')
    if matrix['gateStatus'] not in {'notEvaluated', 'passed', 'failed'}:
        raise ValueError('Invalid G9 gate status')
    # Check source filters and all generated targets without requiring a newer deployment OS.
    for path in ['project.yml', 'LumaPath.xcodeproj/project.pbxproj']:
        source = (root / path).read_text()
        if 'UIRequiredDeviceCapabilities' in source:
            raise ValueError('Review installation capability filter')
    project = (root / 'LumaPath.xcodeproj/project.pbxproj').read_text()
    floors = re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);', project)
    if not floors or set(floors) != {matrix['minimumOS']}:
        raise ValueError('Generated deployment target differs from matrix')
    configured = re.findall(r"^\s*iOS:\s*['\"]?([\d.]+)['\"]?\s*$", (root / 'project.yml').read_text(), re.MULTILINE)
    if set(configured) != {matrix['minimumOS']}:
        raise ValueError('Project source deployment target differs from matrix')
    if '.iOS(.v17)' not in (root / 'Package.swift').read_text():
        raise ValueError('Package deployment target differs from matrix')
    return dict(gate='G9', gateStatus=matrix['gateStatus'], minimumOS=matrix['minimumOS'],
                floorDecisionPending=matrix['floorDecisionPending'],
                physicalRows=len(physical), deviceVerifiedRows=sum(r['status'] == 'deviceVerified' for r in physical),
                scenariosPassed=sum(r['status'] == 'passed' for r in results),
                readyForPairAcceptance=ready, matrixPath='Evaluation/Compatibility/matrix.json')


def audit_built_app(path):
    """Inspect the compiled installation metadata; this does not prove installation on that OS."""
    with (path / 'Info.plist').open('rb') as file:
        info = plistlib.load(file)
    filters = info.get('UIRequiredDeviceCapabilities', [])
    if info.get('MinimumOSVersion') != '17.0' or info.get('UIDeviceFamily') != [1]:
        raise ValueError('Built deployment floor/family differs from policy')
    if not isinstance(filters, (list, dict)) or set(filters) - {'arm64'} or (isinstance(filters, dict) and filters.get('arm64') is False):
        raise ValueError('Built app has optional-hardware installation filters')
    return dict(minimumOS=info['MinimumOSVersion'], deviceFamily=info['UIDeviceFamily'],
                optionalHardwareFilters=False, installedOnMinimumOS=False)
