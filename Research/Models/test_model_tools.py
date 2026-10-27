import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
import json
import struct
import zlib

HERE = Path(__file__).resolve().parent

def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

prepare = load('prepare_dataset')
evaluate = load('evaluate_detections')

class ModelToolsTests(unittest.TestCase):
    def rows(self, root):
        rows = []
        for split in ['train', 'validation', 'test']:
            for negative in [False, True]:
                name = f'{split}-{negative}'
                (root / name).write_bytes(name.encode())
                rows.append({'id': name,'split': split,'image': name,'sessionID': split,'environmentID': split,
                    'rightsBasis': 'publicLicensed','license': 'synthetic test only','rightsEvidence': 'test generation',
                    'width': 32,'height': 32,'annotations': [] if negative else [{'label': 'door','box': [1,1,20,20]}]})
        return rows

    def test_group_and_duplicate_image_leakage_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for group in ['sessionID','environmentID']:
                rows = self.rows(root)
                rows[2][group] = rows[0][group]
                with self.assertRaisesRegex(ValueError, 'leaks'):
                    prepare.validate_rows(rows,root)
            rows = self.rows(root)
            (root / rows[2]['image']).write_bytes((root / rows[0]['image']).read_bytes())
            with self.assertRaisesRegex(ValueError, 'sha256 leaks'):
                prepare.validate_rows(rows,root)

    def test_rights_boxes_and_missing_negatives_cannot_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            rows = self.rows(root)
            self.assertEqual(prepare.validate_rows(rows,root),{'door'})
            invalid = copy.deepcopy(rows); invalid[0]['rightsEvidence'] = ''
            with self.assertRaises(ValueError): prepare.validate_rows(invalid,root)
            invalid = copy.deepcopy(rows); invalid[0]['annotations'][0]['box'][2] = 100
            with self.assertRaises(ValueError): prepare.validate_rows(invalid,root)
            with self.assertRaisesRegex(ValueError, 'absent-target'):
                prepare.validate_rows([r for r in rows if r['annotations']],root)

    def test_real_preparation_checks_pixels_and_writes_create_ml_annotations(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            rows = self.rows(root)
            def chunk(kind, data):
                return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
            for index, row in enumerate(rows):
                image = root / (row['image']+'.png')
                header = struct.pack('!2I5B',32,32,8,2,0,0,0)
                pixels = b''.join(b'\0'+bytes([index*30,100,50])*32 for _ in range(32))
                image.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',header)+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b''))
                row['image'] = image.name
            manifest = root / 'rows.jsonl'
            manifest.write_text('\n'.join(json.dumps(row) for row in rows))
            output = root / 'prepared'
            prepare.prepare(manifest,output)
            annotations = json.loads((output/'train/annotations.json').read_text())
            self.assertEqual(annotations[0]['annotations'][0]['coordinates'],{'x': 11,'y': 11,'width': 20,'height': 20})
            self.assertEqual(annotations[1]['annotations'],[])
            self.assertEqual(len(json.loads((output/'provenance.json').read_text())['rows']),6)
            with self.assertRaises(ValueError): prepare.prepare(manifest,output)

    def test_metrics_count_missed_objects_false_detections_and_unknown_association(self):
        positive = {'id': 'positive','split': 'test','modelSHA256': '0'*64,'environmentID': 'held-out','sessionID': 'capture',
            'inferenceMilliseconds': 40,'evaluatedTargets': ['door'],'truth': [{'target': 'door','box': [0.1,0.1,0.4,0.8],'rangeMeters': 2}],
            'predictions': [{'target': 'door','score': 0.9,'box': [0.1,0.1,0.4,0.8]}]}
        negative = copy.deepcopy(positive); negative['id'] = 'negative'; negative['truth'] = []; negative['inferenceMilliseconds'] = 80
        missed = copy.deepcopy(positive); missed['id'] = 'missed'; missed['predictions'] = []
        result = evaluate.evaluate([positive,negative,missed])['targets']['door']
        self.assertEqual((result['tp'],result['fp'],result['fn']),(1,1,1))
        self.assertEqual(result['precision'],0.5)
        self.assertEqual(result['recall'],0.5)
        self.assertEqual(result['absentTargetFalseDetectionRate'],1)
        self.assertIsNone(result['associatedRangeMAEMeters'])
        self.assertEqual(result['associationUnknown'],1)
        self.assertEqual(result['inferenceP95Milliseconds'],80)
        with self.assertRaises(ValueError): evaluate.evaluate([positive,positive])
        invalid = copy.deepcopy(positive); invalid['predictions'][0]['score'] = float('nan')
        with self.assertRaises(ValueError): evaluate.evaluate([invalid])

if __name__ == '__main__':
    unittest.main()
