#!/usr/bin/env python3
"""Frozen comparative-study accounting. This tool never grants feature activation."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import subprocess

CATEGORIES=('geometry','quality','overhead','passage','steps','prediction','memory','routing')
CONFIGS=('LumaPath/Shared/Configuration.swift','LumaPath/Shared/QualityContracts.swift','LumaPath/Shared/AdvancedContracts.swift','LumaPath/Shared/SpatialContracts.swift','LumaPath/Shared/GeometryContracts.swift','Evaluation/feature-status.json')

def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def freeze(root):
    return dict(schemaVersion=1,sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
                files={p:sha(root/p) for p in CONFIGS},methods=['deterministicBaseline','currentProducer'],
                sensorInterpretation='Processed ARKit depth; not independent raw LiDAR and camera sensors',physicalAcceptance='pending')

def percentile(values, p=.95):
    values=sorted(values)
    return values[max(0,math.ceil(p*len(values))-1)] if values else None

def finite(value, minimum=0): return type(value) in (int,float) and math.isfinite(value) and value>=minimum

def analyze(rows, config):
    if config.get('schemaVersion')!=1 or len(config.get('methods',[]))!=2 or len(set(config['methods']))!=2: raise ValueError('Frozen two-method configuration required')
    fingerprint=hashlib.sha256(json.dumps(config,sort_keys=True).encode()).hexdigest()
    seen=set(); pairs={}; origins=set()
    for row in rows:
        if row.get('category') not in CATEGORIES or row.get('method') not in config['methods']: raise ValueError('Unknown category or method')
        if row.get('configurationSHA256')!=fingerprint: raise ValueError('Configuration mismatch')
        if row.get('origin') not in ('physical','synthetic'): raise ValueError('Explicit provenance required')
        origins.add(row['origin'])
        for key in ('trialID','sessionID','environmentID','device','os','groundTruthReference'):
            if not isinstance(row.get(key),str) or not row[key]: raise ValueError('Trial metadata required: '+key)
        if row['origin']=='physical' and (row.get('consent') is not True or not row.get('consentReference')): raise ValueError('Protected collection consent required')
        if row.get('heldOut') is not True: raise ValueError('Evaluation must be held out')
        key=(row['trialID'],row['category'],row['method'])
        if key in seen: raise ValueError('Duplicate trial/method')
        seen.add(key)
        pair=pairs.setdefault((row['trialID'],row['category']),[]); pair.append(row)
        for key in ('available','expectedPositive','detected','falseActivation','hardConstraintViolation'):
            if type(row.get(key)) is not bool: raise ValueError('Boolean required: '+key)
        if not isinstance(row.get('exclusionReason'),str): raise ValueError('Explicit exclusion reason, empty if included')
        for key in ('negativeMinutes','falseAlerts','latencyMs'):
            if not finite(row.get(key)): raise ValueError('Invalid measurement: '+key)
        if type(row['falseAlerts']) is not int: raise ValueError('Integer false-alert count required')
        if row['falseAlerts'] and row['negativeMinutes']<=0: raise ValueError('False alerts require negative exposure denominator')
        if row['expectedPositive'] and row['negativeMinutes']!=0: raise ValueError('Positive and negative exposures must be separate')
        for key in ('errorMeters','intervalCovered'):
            if key=='errorMeters' and row.get(key) is not None and not finite(row[key]): raise ValueError('Invalid measurement error')
            if key=='intervalCovered' and row.get(key) is not None and type(row[key]) is not bool: raise ValueError('Invalid uncertainty coverage')
    if len(origins)>1: raise ValueError('Never mix synthetic and physical evidence')
    for pair in pairs.values():
        if {r['method'] for r in pair}!=set(config['methods']): raise ValueError('Every trial needs both actual methods')
        for key in ('sessionID','environmentID','device','os','groundTruthReference','expectedPositive','negativeMinutes','exclusionReason','origin'):
            if pair[0][key]!=pair[1][key]: raise ValueError('Unpaired comparison: '+key)
    output={}
    for category in CATEGORIES:
        output[category]={}
        for method in config['methods']:
            trials=[r for r in rows if r['category']==category and r['method']==method]
            included=[r for r in trials if not r['exclusionReason']]
            positive=[r for r in included if r['expectedPositive']]
            negative_minutes=sum(r['negativeMinutes'] for r in included)
            detected=sum(r['detected'] and r['available'] for r in positive)
            errors=[r['errorMeters'] for r in included if r['available'] and r.get('errorMeters') is not None]
            intervals=[r['intervalCovered'] for r in included if r.get('intervalCovered') is not None]
            output[category][method]=dict(total=len(trials),included=len(included),exclusions=dict(Counter(r['exclusionReason'] for r in trials if r['exclusionReason'])),
                unavailable=sum(not r['available'] for r in included),positiveTrials=len(positive),detections=detected,misses=len(positive)-detected,
                recall=detected/len(positive) if positive else None,negativeMinutes=negative_minutes,falseAlerts=sum(r['falseAlerts'] for r in included),
                falseAlertsPerMinute=sum(r['falseAlerts'] for r in included)/negative_minutes if negative_minutes else None,
                errorCount=len(errors),p95ErrorMeters=percentile(errors),latencyCount=len(included),p95LatencyMs=percentile([r['latencyMs'] for r in included]),
                intervalCount=len(intervals),intervalCoverage=sum(intervals)/len(intervals) if intervals else None,
                falseActivations=sum(r['falseActivation'] for r in included),hardConstraintViolations=sum(r['hardConstraintViolation'] for r in included))
    return dict(schemaVersion=1,configurationSHA256=fingerprint,origin=next(iter(origins),'unavailable'),trialPairs=len(pairs),results=output,
                gates={g:'pendingPhysicalEvidenceAndReview' for g in ('G1','G3','G4','G5','G6')},liveActivation=False)

if __name__=='__main__':
    parser=argparse.ArgumentParser(); sub=parser.add_subparsers(dest='command',required=True)
    f=sub.add_parser('freeze'); f.add_argument('destination',type=Path)
    a=sub.add_parser('analyze'); a.add_argument('configuration',type=Path); a.add_argument('trials',type=Path); a.add_argument('destination',type=Path)
    args=parser.parse_args()
    if args.destination.exists(): raise SystemExit('Output exists; choose a new path')
    if args.command=='freeze': result=freeze(Path(__file__).resolve().parents[2])
    else: result=analyze([json.loads(l) for l in args.trials.read_text().splitlines() if l.strip()],json.loads(args.configuration.read_text()))
    args.destination.parent.mkdir(parents=True,exist_ok=True); args.destination.write_text(json.dumps(result,sort_keys=True,indent=2)+'\n')
