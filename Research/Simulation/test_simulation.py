import base64
import copy
import hashlib
import io
import json
import unittest
import numpy as np
from PIL import Image
from generate import CATALOG, DH, DW, HEIGHT, WIDTH, rays, render, session, trace


class SimulationTests(unittest.TestCase):
    def test_exact_box_depth_and_projection_are_in_original_camera_coordinates(self):
        origin=np.array((0.,0.,0.))
        boxes=[(np.array((-1.,-1.,-2.1)),np.array((1.,1.,-2.)),np.ones(3),3)]
        directions,optical,_=rays(DW,DH,origin,0)
        depth,ids,_,_=trace(boxes,origin,directions)
        self.assertEqual(depth[24,32],2)
        self.assertEqual(ids[24,32],3)
        self.assertEqual(np.linalg.norm(optical[24,32])*depth[24,32],2)
        moved=np.array((0.,0.,-0.5))
        moved_depth,_,_,_=trace(boxes,moved,directions)
        self.assertEqual(moved_depth[24,32],1.5)

    def test_room_has_aligned_rgb_depth_mask_and_visible_requested_targets(self):
        sample=render(303,0,"normal")
        with Image.open(io.BytesIO(base64.b64decode(sample["jpeg"]))) as image:
            self.assertEqual(image.size,(WIDTH,HEIGHT)); image.verify()
        depth=np.frombuffer(base64.b64decode(sample["depthFloat32LE"]),dtype="<f4").reshape(DH,DW)
        mask=np.frombuffer(base64.b64decode(sample["instanceMaskUInt8"]),dtype=np.uint8).reshape(DH,DW)
        confidence=np.frombuffer(base64.b64decode(sample["confidenceUInt8"]),dtype=np.uint8).reshape(DH,DW)
        self.assertTrue(np.array_equal(np.isfinite(depth),confidence>0))
        self.assertTrue(set(np.unique(mask))<={0,*CATALOG})
        labels={item["label"] for item in sample["groundTruth"]}
        self.assertTrue({"bed","dining table","door","floor corridor"}<=labels)
        for item in sample["groundTruth"]:
            b=item["imageBounds"]
            self.assertTrue(0<=b["minX"]<b["maxX"]<=1 and 0<=b["minY"]<b["maxY"]<=1)
            if item["nearestVisibleRangeMeters"] is not None: self.assertGreater(item["nearestVisibleRangeMeters"],0)

    def test_lighting_does_not_magically_change_ideal_geometry_or_create_predictions(self):
        normal,dim=render(303,0,"normal"),render(303,0,"dim")
        self.assertLess(dim["_rgb"].mean(),normal["_rgb"].mean()/2)
        self.assertEqual(normal["idealDepthFloat32LE"],dim["idealDepthFloat32LE"])
        self.assertEqual(normal["groundTruth"],dim["groundTruth"])
        self.assertNotIn("predictions",dim)
        dropped=render(303,0,"depthDropout")
        self.assertLess(np.isfinite(dropped["_raw"]).sum(),np.isfinite(normal["_raw"]).sum())
        missing=render(303,0,"missingDepth")
        self.assertIsNone(missing["depthFloat32LE"]); self.assertIsNone(missing["confidenceUInt8"])

    def test_sessions_are_reproducible_explicitly_synthetic_and_environment_disjoint(self):
        a=session(count=4); b=session(count=4)
        self.assertEqual(json.dumps(a,sort_keys=True),json.dumps(b,sort_keys=True))
        self.assertTrue(a["synthetic"]); self.assertEqual(a["sourceMode"],"demoReplay")
        self.assertEqual([s["lighting"] for s in a["samples"]],["normal","dim","depthDropout","missingDepth"])
        for sample in a["samples"]:
            self.assertEqual(sample["frame"]["envelope"]["sourceMode"],"demoReplay")
            self.assertEqual(sample["frame"]["depthKind"]=="none",sample["depthFloat32LE"] is None)
        datasets=[session(seed,split,count=1) for seed,split in ((101,"train"),(202,"validation"),(303,"test"))]
        self.assertEqual(len({d["layoutSHA256"] for d in datasets}),3)
        self.assertEqual(len({d["environmentID"] for d in datasets}),3)
        self.assertEqual(len({d["id"] for d in datasets}),3)


if __name__=="__main__": unittest.main()
