# A4 initial quality increment — October 21, 2026

Owner: Yajat. Baseline: `96b17a0` (A3). **A4 is in progress, not complete.** A3 remains Research-only; G1, B3 integration, M2 acceptance, and physical validation remain open. This increment does not complete B4 profiles/accessibility or M3 acceptance.

## Executed checks

- `swift test`: PASS, 50 tests (40 existing plus 10 quality/disagreement tests).
- Native iPhone 17 Pro simulator tests: PASS, three tests including bounded luma sampling, padded depth integration and original-buffer leases. The application compiles as part of this test command.
- `git diff --check`: PASS.
- Physical capture, UI/output/accessibility participants, latency/thermal measurements, hosted CI: not run in this increment. Existing UI tests were not rerun; this change adds no controls or presentation layout.

```sh
swift test
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'platform=iOS Simulator,id=805CB9F9-E484-4D6A-938F-2418C3131D21' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -derivedDataPath /tmp/lumapath-a4-derived \
  -resultBundlePath /tmp/lumapath-a4-verified.xcresult \
  -only-testing:LumaPathNativeTests test
```

The result bundle and `/tmp/lumapath-a4-{swift,native}.log` are temporary local evidence. The native run emits the existing dependency-scan warning about LumaPathPerception/LumaPathDomain despite their explicit Package.swift dependency, plus App Intents metadata notices. These are not suppressed. Fixtures are analytic or allocated buffers, never captured sensor evidence.

## What is implemented

- Optional `QualityAssessment.details` preserves decoding of old version-2 replay fixtures. The regional quality configuration has its own version **1**; capture/geometry configuration remains version 2.
- Nine display cells: left/center/right × upper/middle/lower. Image position does not prove floor/body/overhead geometry. Cropped/unmeasured regions remain unknown. Each cell records usable/total depth, low/medium/high/invalid confidence counts (nil when absent), dark/clipped luma fraction, horizontal-neighbor contrast and optional nearest-range change.
- Exact regional coverage boundaries: below 30% sparse; 30% through below 70% limited; at least 70% high. Depth validity shares A3's 0.3–4 m window and maximum Euclidean range. A global average cannot hide a sparse region.
- Raw input quality degrades immediately; reaching active requires two consecutive fully supported fresh frames. Outages, generation changes and viewport/orientation changes reset recovery. The combined A3 Research result remains limited due to its unvalidated geometry/ground limitations even if raw quality becomes active. No warm-up delays first-frame hazard events.
- Same-frame/context/sequence/freshness checks reject stale or mixed input. Tracking/pose limitations disable the reported world-dependent support without deleting fresh optical geometry. A same-cell nearest-range change is uncertainty, not a cross-frame object association or motion estimate.
- The existing A2 independent 100 ms watchdog checks 300 ms frame expiry and 500 ms missing input, invalidates leases and invokes downstream cancellation. Capture diagnostics already stop the geometry pipeline/ledger on this signal, stop, interruption, background or viewport loss. Existing watchdog, generation and cancellation tests remain passing. No second capture owner or per-frame task stream is introduced.
- Read-only native sampling supports 8-bit bi-planar full/video-range YUV and BGRA, honors row strides and normalizes video luma. At most 128 × 128 byte samples are copied. Opt-in Research depth analysis supplies these to the actor; failed image diagnostics leave image quality unknown and retain supported depth geometry. There is no raw recording.
- A callable deterministic disagreement policy retains fresh geometry without labels, records floor/raised conflicts, leaves unmatched label distance unknown, treats doorway/exit as candidates with unknown traversability, and treats sparse regions as unobserved rather than clear or holes. Actual model inference/association remains A6. Tests include stale-label rejection, missing confidence and dark imagery with preserved obstacle events.
- `FusionEvaluationRecord` defines an initial Codable row with schema version, session/environment split keys, quality, geometry, separate optional label/association scores, model version, disagreements and ground truth. It does not create files, collect data, establish consent or train a model.

## Next A4 work

1. Deliver coverage/outage limitation transitions through an acknowledged event path alongside obstacle events; existing A3 ledger currently accepts geometry-backed obstacle events only. This increment reports quality reasons but does not claim limitation-event delivery or output cancellation in B3.
2. Integrate no-depth camera-only quality assessment and recovery into the shared product session boundary with Aarav's B4 details UI. The pure API is tested, and capture remains truthfully labeled camera-only, but live image-quality diagnostics currently run only with opt-in depth Research processing.
3. Integrate real semantic association when A6 exists. No model/candidate display or semantic distance is implemented here.
4. Review thresholds with Aarav, freeze per-device configurations, execute the protected A3 G1 protocol and A4 dark/sparse/glare/tracking/recovery scenarios, then complete M3 jointly. Dark ≤24, clipped ≥245, affected fraction ≥50%, contrast <0.05, range change ≥0.5 m and two-frame recovery are engineering hypotheses, not validated limits.
5. A12 must implement consented collection, environment/session-disjoint splitting, dataset/model cards and held-out learned-fusion evaluation. A row schema alone does not complete R19 research.

## Local completion increment — October 21, 2026

After pulling B1–B3 through origin/main 8a0f056 and committing the merge as a9b23a8, A4's remaining local transition/camera-only implementation is delivered:

- QualitySessionPipeline evaluates bounded image/depth diagnostics on a serial actor and publishes the shared SessionSnapshot boundary with the exact capture context. Live view now evaluates camera-only/image-enhancement sessions even with Research geometry off. No camera, recorder, network call or raw-buffer retention is added.
- Camera-only image recovery requires two fresh supported frames after startup/outage/darkness; overall sensing stays limited with unknown depth/coverage. Quality configuration is now **2** (same numerical image/coverage thresholds; adds a 1-second maximum outage-transition lifetime). Capture/geometry remain version 2. Frame-backed transitions inherit the shorter original frame deadline, never a new lifetime.
- QualityLimitationLedger supplies a separate bounded acknowledged event path alongside the geometry-only hazard ledger. Closed messages describe darkness, clipping, unknown/partial coverage and tracking/freshness loss. Same-condition frames do not repeat transitions. Original-frame events expire at their original deadline; an outage is explicitly frame-free with a bounded one-second event. Invalid context, duplicates, stale input and full-ledger backpressure remain explicit. Capture watchdog/render expiry/viewport loss invalidates in-flight quality work and resets recovery while retaining the sequence watermark.
- B3 consumes these typed Research transitions at priority 4: urgent/warning obstacles retain priorities 6/5. Changing quality replaces obsolete current/queued/suspended limitations without cancelling an urgent obstacle. Ordinary guidance remains off; no limitation output without Research opt-in. Pause/End/Help/background/capture loss clear scene output. Repeated status/watchdog reports preserve the one newly emitted outage cue instead of immediately cancelling it.
- Live view exposes a readable current quality summary; raw threshold IDs/implementation details are not UI copy. B4 still owns the regional details/profile/exercise/accessibility product work. Geometry is processed/delivered before the separate shared-session update; dark/missing imagery never gates obstacle events. Actual target-weight/semantic study evidence remains A6-blocked.

Executed package check: **117 Swift tests pass** (110 merged baseline plus 7 new quality/feedback tests). New cases cover camera-only two-frame image recovery, ack/coalescing/dedup, frame-free outage/sequence/stop behavior, bounded backpressure/context rejection, stop during delivery, urgent precedence/obsolete limitation cancellation and Research/TTL gating. Native tests exercise actual allocated BGRA/YUV luma leases into shared camera-only quality; injected clocks are logic evidence, not device latency. See Evaluation/A4-completion-checks.json for final simulator/native/UI results.

Remaining acceptance is external: threshold calibration, real sensing/phone output timing, physical G1/G2/M3, B4 regional details/UI and pair review. A4 local producer/integration work is delivered; A4/M3 acceptance is not declared complete. A6 trained door/elevator/handrail models, accepted grouped corpus, target-specific held-out metrics and physical latency remain unavailable and unchanged. A12 supplies offline experiment tooling but real consented fusion data remains missing.

Validation follow-up: an explicit fresh-timestamp/repeated-sequence case exposed recovery state advancing before SessionState rejected the sequence. `SessionState.canAcceptFrame` now preflights context/lifecycle/sequence before asynchronous quality work, and accept rechecks after suspension. Repeated outage notifications emit one transition. The test retains this regression. Initial full UI run passed 9/10 cases; the existing B3 preview test checked hittability immediately after app activation and failed. A bounded three-second reachability expectation retains the actual control-access requirement; both feedback UI tests passed on recheck. Final native/feedback revalidation after the producer fix is recorded in A4-completion-checks.json, with the initial failure retained rather than reported as a passing full run.
