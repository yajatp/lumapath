# LumaPath simulation lab

The deterministic room renderer generates paired RGB JPEG, noisy axial depth, confidence, ideal depth, instance masks, visible bounding boxes, camera intrinsics/poses and nearest visible surface ranges. All labels are generated ground truth, never detector output. A floor corridor is an annotated region, not evidence of a safe route.

Install `requirements.txt`, then run from the repository:

```sh
python -m unittest discover -s Research/Simulation -v
python Research/Simulation/generate.py path/to/new-output-directory
```

The default corpus contains 13 sessions / 156 frames: separate room layouts for train (seed 101), validation (202) and test (303), each with normal, dim, depth dropout and missing-depth sequences, plus a mixed test demo. Do not split frames from one environment across training and evaluation. The bundled `LumaPath/Shared/Fixtures/simulation-room-v1.lumasim.json` is the 12-frame mixed test demo; never use it for training and report it as independent evaluation.

Files carry `synthetic: true`, `sourceMode: demoReplay`, generator version, environment ID, layout digest and original frame identities. They use `.lumasim.json`, separate from phone research captures. Depth is little-endian Float32 in meters, NaN for missing raw depth, with UInt8 confidence (0 missing, 2 supported); masks are UInt8 instance IDs. The 64×48 grids share the RGB camera's 320×240 field of view. Axial depth differs from Euclidean range. All timestamps are simulated historical time, not device uptime. Dim lighting affects RGB; depth perturbations are explicitly synthetic and are not an iPhone calibration.

The room uses project-generated cuboids only. It includes a bed, dining table, closed door, chair, floor, wall and floor-corridor region. Primitive renders are useful for collection/export plumbing, coordinate checks, missing-sensor tests and controlled algorithm comparisons. They cannot establish real-world YOLO accuracy, low-light performance, learned fusion quality or walking safety. Door and corridor labels do not add classes to the installed 80-class detector. No learned model has been trained on this corpus.

Validation on Windows, October 26, 2026: four Python tests passed, covering known metric geometry, RGB/depth/mask alignment, visible targets, dim/dropout/missing behavior, determinism and disjoint split layouts. Generated output: 13 sessions / 156 frames. Native execution and phone acceptance remain separate.
