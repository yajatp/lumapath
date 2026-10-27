# A6 runtime and model-work status — October 21, 2026

Owner: Yajat. **A6 remains in progress.** Real OCR, detector loading, association and goal-resolution software are implemented. Door/elevator-indicator/handrail trained assets and held-out evidence are absent; Yajat confirmed no existing models/dataset. An unavailable target is not completion of those required model subtasks. B6 Find/typed/voice/attention UI, A7 relocalized landmarks, human review and M5 acceptance remain open.

## Implemented paths

- `LumaPathModels` registers source/license/version/class mapping/transform/training-domain manifests. Custom `.mlmodel` assets require a real SHA256 match, successful Core ML compilation/loading and object-detector coordinate/confidence outputs; arbitrary files and classifiers do not supply invented boxes. Vision inference maps actual recognized labels through the declared class map. Registration verifies bytes/format, not the truth of the model card or legal rights.
- `VisionOCRAdapter` executes actual on-device Vision text recognition (revision 3) plus rectangle context. Exact EXIT text with supporting rectangular context produces a Research candidate; arbitrary text/instructions do not enter the command parser. The native positive sign → OCR → goal candidate test passes, as does the instruction negative. Testing caught and fixed the default rectangle aspect-ratio restriction that initially rejected the wide rendered sign.
- OCR's OS-managed weights have no app-readable checksum: manifest checksum is explicitly nil and source/runtime are identified. No third-party model, license approval, held-out accuracy or sign/route-access certification is invented.
- Explicit quarter-turn/full-image transforms convert Vision lower-left bounds back into the original image top-left frame. Tests cover all rotations. Owned encoded images are bounded to 4 MiB and validated for dimensions/aspect/EXIF; native requested lease encoding is bounded to 1024-pixel sides and invalidated on stop. Inference checks cancellation/freshness before/after work; work that finishes after expiry is rejected.
- Interior depth association keeps label score and association support separate, uses at most 256 samples and returns unknown for multiple plausible surfaces, sparse/missing confidence/depth or wrong capture identity. It does not average foreground/background into a false distance. Original source/freshness are retained.
- `LumaPathGoals` checks target/model capability, goal revision, session/generation and input order; ranks current visible candidates; keeps source labels distinct; invalidates lost/stale candidates; implements repeat/next/cancel/complete/continue and a 20-second “not observed yet” state. Repeated output rechecks freshness. Door/elevator/handrail stay unavailable; saved landmarks require A7. B6 owns request parsing, voice permissions and product interaction.
- Semantic batches/observations/associations have provider-neutral Codable contracts, schema-1 batch validation and original envelope provenance. Remote/map/remembered hypotheses cannot masquerade as current camera detections.

## Validation

- **65 Swift package tests pass**; seven semantic tests cover transforms, ambiguous-box association, unknown distance, manifests/checksums, unavailable targets, absent/lost targets, revisions/generations, provenance and non-command scene text.
- **Five native simulator tests pass**: existing buffer/luma/depth tests plus actual Vision OCR and current-lease image encoding. The OCR test uses an injected fixed clock for producer/goal logic and a separate advancing clock proving rejection after 300 ms. Thus a successful synthetic goal test does not assert real-time freshness performance.
- The **three existing UI journeys pass** in the full scheme run. Final changed producer/native assertions were rechecked with the native-only suite; the UI layout did not change.
- **Four Python model-tool tests pass**, including actual PNG dimension/preparation, group/duplicate leakage, rights/box/negative validation and precision/recall/absence/error accounting.
- Both `train_detector.swift` and `infer_evaluation.swift` compile and their help commands run. No real corpus training, exported target weights or held-out target inference was executed.

```sh
swift test
python3 -m unittest discover -s Research/Models -p 'test_*.py'
swiftc Research/Models/train_detector.swift -o /tmp/lumapath-train-detector
swiftc Research/Models/infer_evaluation.swift -o /tmp/lumapath-infer-evaluation
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'platform=iOS Simulator,id=805CB9F9-E484-4D6A-938F-2418C3131D21' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -derivedDataPath /tmp/lumapath-a5a6-derived \
  -resultBundlePath /tmp/lumapath-a5a6-complete-check.xcresult \
  -only-testing:LumaPathNativeTests test
```

`Evaluation/A6-fixture-inference.json` records measured simulator OCR times/counts on two rendered images, not held-out precision/recall or iPhone latency. These runs exceed the 300-ms scene lifetime on the simulator; production freshness guards reject late results. A5/A6 remain Research-only; performance optimization/device evidence is required before any promotion. The native build emits the recorded Domain dependency-scan warnings and App Intents metadata notices. No physical phone or watch is available for testing; hosted CI was not run.

## Required completion work

See [model workflow and source review](../Research/Models/README.md) and [explicit target subtasks](../Research/Models/model-workplan.json). Prepare a verified rights/provenance corpus with environment/session-disjoint splits, train/export the actual door/elevator/handrail models, integrate handrail 3D/temporal structure, and run target-specific held-out/negative/association/device-latency evaluation. EXIT needs instructions/reflection/arrow negatives and physical sign evaluation too. The forecast rises from 6 to **20 provisional points**; Yajat retains ownership and pair rebalancing is explicitly pending. Training/export tools and an unavailable-state registry alone do not complete A6 or R09.


## A5–A7 continuation

`HandrailStructureVerifier` now supplies current contiguous elongated 3D/temporal support, and the resolver requires that evidence for handrail candidates. Two analytic verifier tests cover supported lines, gaps, planes, repeated frames, observation gaps and expiry; these are not target accuracy metrics. A7 now supplies Research saved-landmark alignment/provider/goal software, with B7 integration and physical gates pending. User reconfirmed no model/data assets. Door/elevator/handrail training and held-out/device evaluation remain open. The continuation passes 77 package tests and four Python tool tests; native evidence is in `Evaluation/A7-validation.md`. Earlier 65-test evidence above refers to the prior source increment.
