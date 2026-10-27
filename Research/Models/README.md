# Target detector training and evaluation

The local inference, depth-association, and goal-resolution tools are implemented. Target-specific detector training remains pending: no door, elevator-indicator, or handrail weights or held-out training corpus are included. Apple Vision OCR and rectangle context can produce experimental EXIT candidates; these do not establish a usable exit. Remembered landmarks use a separate research provider that requires accepted spatial alignment and physical validation.

## Sources checked on October 21, 2026

| Target | Source candidate | What is verified / missing |
| --- | --- | --- |
| Door | [Mohamed and Sirlantzis, Mendeley Data V1](https://data.mendeley.com/datasets/m9n4f6prn4/1) | Publisher lists CC BY 4.0, door annotations and multiple capture environments. No assets imported; environment/session grouping, attribution and target-specific negative coverage must be reviewed. |
| Handrail | [da, Roboflow handrail dataset](https://universe.roboflow.com/da-nsoap/handrail) | Publisher lists CC BY 4.0 and a handrail class. Download/deployment access, original image provenance, group metadata and annotation quality need review; no account/API key or hosted inference is used. |
| Elevator indicator/panel | No accepted corpus/model | Source consented panel/signage scenes and hard negatives; do not substitute arbitrary buttons or numerical displays. |
| Exit sign | [Apple Vision text request](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) | OS-managed OCR, explicit revision 3, rectangle context and exact EXIT token. Weight checksum is unavailable and explicitly nil; do not invent a vendor checksum/license. App-held-out and physical target evaluation remain pending. |

[DoorDetect](https://github.com/MiguelARD/DoorDetect-Dataset) was also inspected. Its README describes mixed image sources and downloadable weights, but the inspected repository view did not establish a complete redistribution license/provenance chain. It was not imported or represented as approved weights.

## Annotation and collection contract

Each JSONL row describes one image, a declared environment/session split, rights evidence, actual dimensions and all target boxes. Use `annotations: []` for reviewed absent-target scenes. A source with unidentified capture groups cannot be assigned random adjacent frames across splits; recover grouping metadata or collect a consented replacement corpus first. Keep collection sessions stationary/protected. Document permission, retention and withdrawal before collecting people/private spaces; this tooling is not an in-app recorder.

- `door`: full visible human-passage door/frame instance, with occlusion and open/closed state documented separately; cabinet/fridge doors, mirrors, posters and open passages are hard negatives.
- `exitSign`: sign text plus sign context; printed instructions, reflected text, isolated arrows and unrelated occurrences of “exit” are negatives. An exit sign never certifies door/route access.
- `elevatorIndicator`: indicator/panel with elevator/lift context; directories, ordinary switches, clocks and unrelated digit displays are negatives. A sign is not an operable elevator.
- `handrail`: visible rail instance, including occlusion and continuity annotations; pipes, shelf edges and decorative rails are negatives. A box alone does not establish reachability or continuity; handrail promotion also needs elongated 3D/temporal evidence. The implemented `HandrailStructureVerifier` checks current contiguous depth lines and temporal support; it still needs calibration/evaluation with actual detector output.

Required row shape (the values below illustrate a schema, not an existing consent record):

```json
{"id":"capture-001","image":"images/001.jpg","width":640,"height":480,"sessionID":"session-A","environmentID":"building-A","split":"train","rightsBasis":"consentedCapture","license":"document actual permission terms","rightsEvidence":"path/to/actual/consent-record","annotations":[{"label":"door","box":[100,40,220,400]}]}
```

The preparer validates dimensions using macOS `sips`, rejects environment/session/duplicate-image leakage, invalid boxes and missing rights metadata, and requires positive/negative coverage in every explicit split. It copies only the supplied corpus into a new directory and writes Create ML annotations plus provenance. It does not verify a claimed consent record on behalf of the owner.

## Executable workflow

```sh
python3 Research/Models/prepare_dataset.py /absolute/path/rows.jsonl /absolute/path/new-prepared
swiftc Research/Models/train_detector.swift -o /tmp/lumapath-train-detector
/tmp/lumapath-train-detector /absolute/path/new-prepared /absolute/path/new-model-run 500
swiftc Research/Models/infer_evaluation.swift -o /tmp/lumapath-infer-evaluation
/tmp/lumapath-infer-evaluation /absolute/path/new-model-run/Detector.mlmodel /absolute/path/new-prepared /absolute/path/new-results.jsonl
python3 Research/Models/evaluate_detections.py /absolute/path/new-results.jsonl /absolute/path/new-report.json
python3 -m unittest discover -s Research/Models -p 'test_*.py'
```

Create ML transfer learning uses separate validation data and exports actual `.mlmodel` weights, a SHA256 and held-out AP results. The inference runner measures real host execution and exports normalized detection boxes, provenance and explicit unknown ranges. The scorer reports per-target precision/recall, absent-target false detections, unknown associations, range error when measured ground truth exists, and inference p50/p95. Host timings are not iPhone latency results. Test-set labels must not tune thresholds; a new threshold/model requires a fresh held-out evaluation protocol.

Before registration, finish the source/license/model card and class mapping; set transform exactly `scaleFill.fullImage.explicitQuarterTurn`. `ModelRegistry.register` verifies the file checksum and actually compiles/loads an object-detector asset; a generic classifier or arbitrary file is rejected. Runtime inference accepts only recognized object boxes in the declared class map. Registration permits Research only; ordinary live targets remain unavailable. A model checksum proves file identity, not its license, class accuracy or safety.

## Validation status

Tool compilation and synthetic tooling tests pass. No real target model was trained, no corpus was downloaded, and no held-out accuracy/physical performance is claimed. See [the evaluation record](../../Evaluation/A6-validation.md) and [model workplan](model-workplan.json).
