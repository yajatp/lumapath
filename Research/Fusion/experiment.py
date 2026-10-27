#!/usr/bin/env python3
"""Offline research only: semantic-association support, never hazard suppression."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import random

FEATURES=('coverage','contrast','semanticScore','associationScore','disagreement')
SPLITS=('train','validation','test')

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def validate(rows, synthetic=False):
    if not rows or len(rows)>1_000_000: raise ValueError('Dataset size outside budget')
    seen=set(); groups={key:{} for key in ('environmentID','sessionID','sourceID')}
    for row in rows:
        if not isinstance(row,dict): raise ValueError('Expected row object')
        if row.get('split') not in SPLITS or not isinstance(row.get('id'),str) or not row['id'] or row['id'] in seen:
            raise ValueError('Unique ID and explicit split required')
        seen.add(row['id'])
        if row.get('synthetic') is not synthetic: raise ValueError('Cannot mix synthetic and physical data')
        if not synthetic and (row.get('consent') is not True or not row.get('consentRecord') or not row.get('license')):
            raise ValueError('Consent evidence and license required')
        for key in groups:
            value=row.get(key)
            if not isinstance(value,str) or not value: raise ValueError('Missing group identifier')
            prior=groups[key].setdefault(value,row['split'])
            if prior!=row['split']: raise ValueError(key+' leaks across splits')
        if type(row.get('supported')) is not int or row['supported'] not in (0,1): raise ValueError('Binary annotated ground truth required')
        for key in FEATURES:
            value=row.get('features',{}).get(key)
            if type(value) not in (int,float) or not math.isfinite(value) or not 0<=value<=1: raise ValueError('Invalid bounded feature: '+key)
        for key in ('lighting','surface'):
            if not isinstance(row.get(key),str) or not row[key]: raise ValueError('Condition label required')
    for split in SPLITS:
        if {r['supported'] for r in rows if r['split']==split}!={0,1}: raise ValueError('Each split requires both classes')

def vector(row): return [1.]+[row['features'][k] for k in FEATURES]
def sigmoid(value): return 1/(1+math.exp(-max(-40,min(40,value))))
def score(weights,row): return sum(a*b for a,b in zip(weights,vector(row)))
def baseline(row):
    f=row['features']
    return .9 if f['coverage']>=.6 and f['semanticScore']>=.7 and f['associationScore']>=.6 and f['disagreement']<.5 else .1

def metrics(rows, probabilities):
    bins=[]
    for index in range(10):
        values=[(r['supported'],p) for r,p in zip(rows,probabilities) if min(int(p*10),9)==index]
        bins.append(dict(bin=index,count=len(values),meanProbability=sum(p for _,p in values)/len(values) if values else None,
                         positiveRate=sum(y for y,_ in values)/len(values) if values else None))
    return dict(count=len(rows),positives=sum(r['supported'] for r in rows),negatives=sum(1-r['supported'] for r in rows),
                falseNegatives=sum(r['supported']==1 and p<.5 for r,p in zip(rows,probabilities)),
                falsePositives=sum(r['supported']==0 and p>=.5 for r,p in zip(rows,probabilities)),
                abstentions=sum(.4<=p<=.6 for p in probabilities),
                brier=sum((p-r['supported'])**2 for r,p in zip(rows,probabilities))/len(rows),calibration=bins)

def run(manifest, destination, synthetic=False):
    rows=[json.loads(line) for line in manifest.read_text().splitlines() if line.strip()]
    validate(rows,synthetic)
    if destination.exists(): raise ValueError('Output must be a new directory')
    train=[r for r in rows if r['split']=='train']; validation=[r for r in rows if r['split']=='validation']; test=[r for r in rows if r['split']=='test']
    weights=[0.]*(1+len(FEATURES))
    for _ in range(1000):
        gradient=[0.]*len(weights)
        for row in train:
            error=sigmoid(score(weights,row))-row['supported']
            for j,value in enumerate(vector(row)): gradient[j]+=error*value
        weights=[w-.2*(g/len(train)+(.001*w if j else 0)) for j,(w,g) in enumerate(zip(weights,gradient))]
    # Temperature is fitted ONLY on validation; test is never used in fitting/selection.
    temperatures=(.25,.5,.75,1.,1.5,2.,3.,4.)
    temperature=min(temperatures,key=lambda t:sum((sigmoid(score(weights,r)/t)-r['supported'])**2 for r in validation))
    probabilities=[sigmoid(score(weights,r)/temperature) for r in test]
    learned=metrics(test,probabilities); deterministic=metrics(test,[baseline(r) for r in test])
    conditions={}
    for key in ('lighting','surface'):
        for value in sorted({r[key] for r in test}):
            indices=[i for i,r in enumerate(test) if r[key]==value]; subset=[test[i] for i in indices]
            conditions[key+':'+value]={'learned':metrics(subset,[probabilities[i] for i in indices]),'baseline':metrics(subset,[baseline(r) for r in subset])}
    decision='reject' if learned['brier']>=deterministic['brier'] or learned['falseNegatives']>deterministic['falseNegatives'] else 'pendingIndependentReview'
    if synthetic: decision='pendingRealData'
    model=dict(schemaVersion=1,task='semanticAssociationSupported',features=FEATURES,weights=weights,temperature=temperature,
               researchOnly=True,geometryAuthority=False,manifestSHA256=digest(manifest),trainingScriptSHA256=digest(__file__))
    encoded=json.dumps(model,sort_keys=True,indent=2)+'\n'
    report=dict(schemaVersion=1,synthetic=synthetic,decision=decision,liveActivation=False,modelSHA256=hashlib.sha256(encoded.encode()).hexdigest(),
                manifestSHA256=digest(manifest),splits=dict(Counter(r['split'] for r in rows)),learned=learned,baseline=deterministic,conditions=conditions,
                exclusions=0,seed=17,epochs=1000,learningRate=.2,l2=.001,temperatureCandidates=temperatures)
    destination.mkdir(parents=True)
    (destination/'model.json').write_text(encoded)
    (destination/'metrics.json').write_text(json.dumps(report,sort_keys=True,indent=2)+'\n')
    (destination/'held-out.jsonl').write_text(''.join(json.dumps(dict(id=r['id'],truth=r['supported'],learned=p,baseline=baseline(r)))+'\n' for r,p in zip(test,probabilities)))
    return report

def fixture(path):
    rng=random.Random(17); rows=[]
    for split in SPLITS:
        for i in range(96):
            features={k:round(rng.random(),6) for k in FEATURES}
            supported=int(1.3*features['associationScore']+features['semanticScore']+features['coverage']-.8*features['disagreement']>1.5)
            rows.append(dict(id=f'{split}-{i}',split=split,environmentID=f'{split}-environment-{i//24}',sessionID=f'{split}-session-{i//12}',sourceID=f'{split}-frame-{i}',
                             synthetic=True,features=features,supported=supported,lighting=('bright','dark')[i%2],surface=('matte','reflective')[i%2]))
    if path.exists(): raise ValueError('Fixture destination exists')
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(''.join(json.dumps(row,sort_keys=True)+'\n' for row in rows))

if __name__=='__main__':
    parser=argparse.ArgumentParser(); sub=parser.add_subparsers(dest='command',required=True)
    generate=sub.add_parser('fixture'); generate.add_argument('path',type=Path)
    execute=sub.add_parser('run'); execute.add_argument('manifest',type=Path); execute.add_argument('destination',type=Path); execute.add_argument('--synthetic',action='store_true')
    args=parser.parse_args()
    if args.command=='fixture': fixture(args.path)
    else: print(json.dumps(run(args.manifest,args.destination,args.synthetic),indent=2))
