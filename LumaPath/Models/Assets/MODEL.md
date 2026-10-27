# Bundled scene detector

October 26 update: Full YOLOv3 Int8 LUT is now the default Research preset; Tiny remains selectable for a device comparison/fallback. Both have the **same 80 classes**. The full model's larger capacity does not add doors, stairs, curbs or potholes. No improvement in LumaPath accuracy or latency has yet been measured on iPhone.

- Full model: https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3/YOLOv3Int8LUT.mlmodel
- Full size: 62,200,325 bytes
- Full SHA-256: 0e32f297ad9cfc0ea8e67276867956488c7ee10dc87c057da4debc939e20b76d
- Original authors and Darknet license reference are embedded in both assets; both use DARKNET-LICENSE.txt below.
- Runtime selects and verifies the exact preset. Models use their own IDs in observations. Changing preset ends capture; preparations are revision-guarded. Research controls disclose supported and unsupported categories.

Tiny preset provenance:

YOLOv3 Tiny FP16, Apple catalog version 2.0, Joseph Redmon / Ali Farhadi.

- Catalog: https://developer.apple.com/machine-learning/models/
- Exact asset: https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel
- Size: 17,769,580 bytes
- SHA-256: 73406178d0f5793d0d5d1e38274acd146a744c2245c9b63a11998a5015925dda
- Source: https://github.com/pjreddie/darknet
- License: model metadata directs readers to the original Darknet license (public domain); reproduced in DARKNET-LICENSE.txt. This is the original Darknet model, not an Ultralytics model or license.
- Training domain: COCO 80 object categories. No LumaPath held-out accuracy, physical distance, elderly usability or safety validation exists for these weights.
- Input: full image scaleFill, explicit quarter-turn, 416×416 RGB. Vision boxes are inverse-rotated into original top-left normalized image coordinates before depth association.
- Output: NMS coordinates/confidence object boxes. Classifier-only output is rejected. Runtime validates the pinned asset checksum and exposes only the explicit COCO class list with score >=0.6.

The model is copied as a SwiftPM Models resource, compiled locally by Core ML once per detector instance, and runs locally. No hosted model call or key is needed. It describes optional Research objects; it does not extend Find target capabilities, infer metric distance from RGB, or authorize navigation. Device latency, thermal cost, labels, orientation and model loading remain Mac/iPhone validation tasks.
