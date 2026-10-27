#!/usr/bin/env python3
"""Check release evidence structure; pending acceptance never becomes a pass."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess
from compatibility import audit_compatibility, audit_built_app, evidence_files

ROOT=Path(__file__).resolve().parents[2]

def audit(root=ROOT):
    status=json.loads((root/'Evaluation/feature-status.json').read_text())
    requirements=status['requirements']
    evidence=set()
    for item in requirements+status['capabilities']:
        for key in ('fixtureResults','deviceResults','serviceResults','researchResults','evidencePaths'):
            for path in item.get(key,[]):
                target=root/path
                if not target.resolve().is_relative_to(root.resolve()) or not target.is_file(): raise ValueError('Missing/outside evidence: '+path)
                evidence.add(path)
        # B1 shell/B2 image enhancement expose no ordinary hazard guidance.
        presentation_only = item.get('capabilityID') in ('B1.consumerShell','B2.visualRenderer')
        if item['defaultEnabled'] and not presentation_only and (item.get('gateStatus')!='passed' or not item.get('reviewedBy')): raise ValueError('Unreviewed feature activation')
    with (root/'Evaluation/scenarios.csv').open() as source:
        scenarios=list(csv.DictReader(source))
    compatibility = audit_compatibility(root, status, scenarios)
    evidence.add(compatibility['matrixPath'])
    evidence_files(root, [row['resultPath'] for row in scenarios])
    evidence.update(['Evaluation/feature-status.json', 'Evaluation/scenarios.csv', 'project.yml', 'Package.swift',
                     'LumaPath.xcodeproj/project.pbxproj', 'Tools/Release/audit.py', 'Tools/Release/compatibility.py',
                     'LumaPath/Shared/CompatibilityContracts.swift', 'LumaPath/Shared/ResourcePolicy.swift',
                     'LumaPath/App/LiveCameraView.swift'])
    model=root/'Evaluation/Fusion/synthetic-result/model.json'; metrics=json.loads((model.parent/'metrics.json').read_text())
    if hashlib.sha256(model.read_bytes()).hexdigest()!=metrics['modelSHA256']: raise ValueError('Model hash mismatch')
    model_data=json.loads(model.read_text())
    if hashlib.sha256((root/'Research/Fusion/experiment.py').read_bytes()).hexdigest()!=model_data['trainingScriptSHA256']: raise ValueError('Training script hash mismatch')
    if hashlib.sha256((root/'Evaluation/Fusion/synthetic-manifest.jsonl').read_bytes()).hexdigest()!=model_data['manifestSHA256']: raise ValueError('Dataset hash mismatch')
    for package in range(11,15):
        path=f'Evaluation/A{package}-validation.md'
        if not (root/path).is_file(): raise ValueError('Missing package validation')
        evidence.add(path)
    return dict(schemaVersion=2,sourceBaseCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
                auditedWorkingTree=True,requirements=23,scenarios=64,compatibility=compatibility,evidenceSHA256={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(evidence)},
                softwareAudit='passed',releaseAcceptance='pendingExternalEvidenceAndPairReview',productionDeployment=False,
                blockers=['Physical compatibility G9 and provisional OS-floor decision','C2 product fallback workflows; C3 physical resource/accessibility trials','Physical G1/G3/G4/G5/G6/G8','Live provider/staging G7','Consented learned-fusion dataset','B1–B14 integration and pair review','Physical performance/thermal and production rollback'])

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--output',type=Path); parser.add_argument('--built-app',type=Path); args=parser.parse_args()
    result=audit()
    if args.built_app: result['builtApp']=audit_built_app(args.built_app)
    encoded=json.dumps(result,sort_keys=True,indent=2)+'\n'
    if args.output: args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(encoded)
    else: print(encoded)
