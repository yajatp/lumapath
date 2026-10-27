#!/usr/bin/env python3
"""Score held-out normalized boxes, negatives, association error and latency per target; never promote automatically."""
import argparse
import json
import math
from pathlib import Path


def iou(a, b):
    x0, y0 = max(a[0], b[0]), max(a[1], b[1])
    x1, y1 = min(a[2], b[2]), min(a[3], b[3])
    overlap = max(0, x1-x0)*max(0, y1-y0)
    area = (a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-overlap
    return overlap/area if area > 0 else 0


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values)-1, math.ceil(p*len(values))-1)]


def evaluate(rows):
    totals = {}
    identities = set()
    model_digest = None
    for row in rows:
        identity = row['id']
        if identity in identities or row.get('split') != 'test' or not row.get('modelSHA256') or not row.get('environmentID') or not row.get('sessionID'):
            raise ValueError('Unique held-out test IDs, model hash and environment/session provenance required')
        digest = row['modelSHA256']
        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest) or model_digest not in (None,digest):
            raise ValueError('One verified model SHA256 is required per report')
        model_digest = digest
        allowed = {'door','exitSign','elevatorIndicator','handrail'}
        if not row['evaluatedTargets'] or len(set(row['evaluatedTargets'])) != len(row['evaluatedTargets']) or not set(row['evaluatedTargets']) <= allowed:
            raise ValueError('Explicit supported target classes required')
        if any(item.get('target') not in row['evaluatedTargets'] for item in row['truth']+row['predictions']):
            raise ValueError('Unlisted evaluation target')
        identities.add(identity)
        duration = row['inferenceMilliseconds']
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
            raise ValueError('Invalid measured latency')
        for item in row['truth']+row['predictions']:
            box = item['box']
            if len(box) != 4 or not all(isinstance(v, (int, float)) and math.isfinite(v) and 0 <= v <= 1 for v in box) or box[2] <= box[0] or box[3] <= box[1]:
                raise ValueError('Boxes must be normalized [minX,minY,maxX,maxY]')
        for target in row['evaluatedTargets']:
            data = totals.setdefault(target, {'tp': 0, 'fp': 0, 'fn': 0, 'negativeImages': 0, 'negativeImagesWithDetection': 0, 'latencies': [], 'rangeErrors': [], 'associationUnknown': 0})
            truth = [t for t in row['truth'] if t['target'] == target]
            predictions = [p for p in row['predictions'] if p['target'] == target]
            if not all(isinstance(p.get('score'), (int, float)) and math.isfinite(p['score']) and 0 <= p['score'] <= 1 for p in predictions):
                raise ValueError('Invalid model scores')
            data['latencies'].append(duration)
            if not truth:
                data['negativeImages'] += 1
                data['negativeImagesWithDetection'] += bool(predictions)
            used = set()
            for prediction in sorted(predictions, key=lambda p: -p['score']):
                choices = [(iou(prediction['box'], t['box']), index) for index, t in enumerate(truth) if index not in used]
                overlap, index = max(choices, default=(0, -1))
                if overlap < 0.5:
                    data['fp'] += 1
                    continue
                data['tp'] += 1
                used.add(index)
                measured, actual = prediction.get('rangeMeters'), truth[index].get('rangeMeters')
                if actual is not None and (not math.isfinite(actual) or actual <= 0):
                    raise ValueError('Invalid ground-truth range')
                if measured is not None and (not math.isfinite(measured) or measured <= 0):
                    raise ValueError('Invalid measured range')
                if measured is None or actual is None:
                    data['associationUnknown'] += 1
                else:
                    data['rangeErrors'].append(abs(measured-actual))
            data['fn'] += len(truth)-len(used)
    report = {}
    for target, data in totals.items():
        report[target] = {k: data[k] for k in ['tp', 'fp', 'fn', 'negativeImages', 'negativeImagesWithDetection', 'associationUnknown']}
        report[target] |= {'precision': data['tp']/(data['tp']+data['fp']) if data['tp']+data['fp'] else None,
            'recall': data['tp']/(data['tp']+data['fn']) if data['tp']+data['fn'] else None,
            'absentTargetFalseDetectionRate': data['negativeImagesWithDetection']/data['negativeImages'] if data['negativeImages'] else None,
            'inferenceP50Milliseconds': percentile(data['latencies'], 0.5), 'inferenceP95Milliseconds': percentile(data['latencies'], 0.95),
            'associatedRangeMAEMeters': sum(data['rangeErrors'])/len(data['rangeErrors']) if data['rangeErrors'] else None}
    return {'schemaVersion': 1, 'ordinaryLiveAvailable': False, 'targets': report}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.results.read_text().splitlines() if line.strip()]
    if not rows:
        raise ValueError('No held-out inference results; no metrics may be fabricated')
    with args.output.open('x') as destination:
        json.dump(evaluate(rows), destination, indent=2, allow_nan=False)
        destination.write('\n')
