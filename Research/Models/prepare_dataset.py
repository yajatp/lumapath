#!/usr/bin/env python3
"""Validate licensed/consented JSONL rows and prepare explicit, disjoint Create ML splits."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess

TARGETS = {'door', 'exitSign', 'elevatorIndicator', 'handrail'}
SPLITS = {'train', 'validation', 'test'}


def validate_rows(rows, root):
    groups = {'sessionID': {}, 'environmentID': {}, 'sha256': {}}
    identifiers = set()
    for row in rows:
        if row.get('split') not in SPLITS or row.get('id') in identifiers or not row.get('id'):
            raise ValueError('Each row needs a unique ID and explicit train/validation/test split')
        identifiers.add(row['id'])
        if row.get('rightsBasis') not in {'publicLicensed', 'consentedCapture'} or not row.get('rightsEvidence') or not row.get('license'):
            raise ValueError('Rights basis, license and evidence are required per image')
        image = (root / row['image']).resolve()
        if not image.is_file():
            raise ValueError(f'Missing image: {image}')
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        for key, value in [('sessionID', row.get('sessionID')), ('environmentID', row.get('environmentID')), ('sha256', digest)]:
            if not value:
                raise ValueError(f'Missing {key}')
            prior = groups[key].setdefault(value, row['split'])
            if prior != row['split']:
                raise ValueError(f'{key} leaks between {prior} and {row["split"]}')
        width, height = row.get('width', 0), row.get('height', 0)
        if not isinstance(width, int) or not isinstance(height, int) or min(width, height) <= 0:
            raise ValueError('Positive integer image dimensions are required')
        if not isinstance(row.get('annotations'), list):
            raise ValueError('Annotations must be a list; use [] for verified absent-target images')
        for annotation in row['annotations']:
            box = annotation.get('box', [])
            if annotation.get('label') not in TARGETS or len(box) != 4 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in box):
                raise ValueError('Unknown class or invalid [x,y,width,height] pixel box')
            x, y, w, h = box
            if min(x, y) < 0 or min(w, h) <= 0 or x+w > width or y+h > height:
                raise ValueError('Box outside image')
        row['_path'] = image
        row['_sha256'] = digest
    if {r['split'] for r in rows} != SPLITS:
        raise ValueError('Explicit train, validation and test splits are all required')
    # Every modeled target needs both positive evidence and verified negative images in held-out data.
    targets = {a['label'] for r in rows for a in r['annotations']}
    if not targets:
        raise ValueError('No positive target annotations')
    for split in SPLITS:
        for target in targets:
            if not any(r['split'] == split and any(a['label'] == target for a in r['annotations']) for r in rows):
                raise ValueError(f'{target} missing positive examples in {split}')
            if not any(r['split'] == split and not r['annotations'] for r in rows):
                raise ValueError(f'{split} requires explicitly annotated absent-target images')
    return targets


def prepare(manifest, destination):
    rows = [json.loads(line) for line in manifest.read_text().splitlines() if line.strip()]
    targets = validate_rows(rows, manifest.parent)
    # Validate dimensions against actual pixels before copying or training; this workflow runs on macOS.
    for row in rows:
        result = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(row['_path'])], check=True, text=True, capture_output=True)
        dimensions = dict(line.strip().split(': ', 1) for line in result.stdout.splitlines() if ': ' in line)
        if int(dimensions['pixelWidth']) != row['width'] or int(dimensions['pixelHeight']) != row['height']:
            raise ValueError('Annotation dimensions do not match actual image pixels')
    if destination.exists():
        raise ValueError('Output must be a new directory; existing data is never overwritten')
    destination.mkdir(parents=True)
    for split in sorted(SPLITS):
        folder = destination / split
        folder.mkdir()
        annotations = []
        for index, row in enumerate(r for r in rows if r['split'] == split):
            name = f'{index:06d}{row["_path"].suffix.lower()}'
            shutil.copyfile(row['_path'], folder / name)
            annotations.append({'image': name, 'annotations': [
                {'label': a['label'], 'coordinates': {'x': a['box'][0]+a['box'][2]/2, 'y': a['box'][1]+a['box'][3]/2,
                    'width': a['box'][2], 'height': a['box'][3]}} for a in row['annotations']]})
        (folder / 'annotations.json').write_text(json.dumps(annotations, indent=2)+'\n')
    provenance = [{k: v for k, v in row.items() if not k.startswith('_')} | {'sha256': row['_sha256']} for row in rows]
    (destination / 'provenance.json').write_text(json.dumps({'schemaVersion': 1, 'targets': sorted(targets), 'rows': provenance}, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepare(args.manifest.resolve(), args.output.resolve())
