# A3 validation — October 21, 2026

Owner: Yajat. Baseline: `7e39cf4` (A2). Implementation is available as Research-only geometry, generic hazard policy, and acknowledged delivery. **G1, B3 feedback/overlay integration, and M2 physical joint acceptance remain pending.** No actual obstacle sensing, cue comprehension, or latency performance is claimed from these software checks.

## Executed results

| Check | Result | Scope |
| --- | --- | --- |
| Swift package tests | PASS — 40 tests, zero failures | 22 existing + 18 geometry/risk tests |
| Native simulator buffer tests | PASS — 2 tests, zero failures | Original-buffer lease plus padded copy → geometry → event ledger |
| Native simulator UI tests | PASS — 3 tests, zero failures | Replay journey; unsupported live capture/demo fallback; synthetic ahead/side/close/missing-depth Research cases |
| Unsigned generic Simulator build | PASS | Native application and local package source compile |
| Unsigned generic iPhoneOS build | PASS | Compiles against device SDK; not installed or exercised on a phone |
| Hosted CI | Not run | Package tests and unsigned build configured; requires push/hosted run |
| Physical G1 / M2 | Not evaluated | Paired phone unavailable; B3 output/renderer not implemented |

Environment: Xcode 26.2 (17C52), Swift 6.2.3, SDK 26.2, iPhone 17 Pro Simulator runtime 26.3. iOS 17 minimum is a compilation target, not physical compatibility evidence.

Commands:

```sh
swift test
xcodegen generate
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/lumapath-a3-derived build
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/lumapath-a3-device build
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'platform=iOS Simulator,id=805CB9F9-E484-4D6A-938F-2418C3131D21' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -derivedDataPath /tmp/lumapath-a3-derived \
  -resultBundlePath /tmp/lumapath-a3-release.xcresult test
```

The result bundle is a temporary local artifact; source tests and fixture hashes are the reproducible repository evidence. App Intents metadata notices occur for targets without AppIntents. Native test builds additionally report that LumaPathPerception is missing LumaPathDomain, despite `Package.swift` explicitly declaring that direct dependency and all builds/tests passing. This resembles [reported Xcode 26 dependency-scan diagnostics](https://forums.swift.org/t/xcode-26-unable-to-find-module-dependency/80516); that attribution is an inference. The warning is recorded, not hidden by disabling dependency checks or explicit modules.

## Software checks established

- Same-depth ahead/side fixtures receive warning/information respectively. A credible close first frame emits urgent immediately. All new events carry Research scope and the original measurement deadline.
- NaN/infinity/nonpositive/out-of-range/low-or-invalid-confidence measurements produce no hazards or free-space claims. Missing confidence preserves supported generic geometry with a limitation; an obstacle remains alongside unobserved regions.
- Robust tile support rejects isolated speckles without averaging different depth surfaces. A bounded cluster span prevents chained farther samples from diluting a supported close surface. Four-neighbor components separate across unknown gaps/depth discontinuities. The component budget keeps nearest geometry and reports truncation.
- A wide component supplies depth measurements to each visible region it occupies. Cropped components cannot create visible bounds or visible-region distances. Intrinsics scale from image to depth resolution; display conversion applies the supplied transform once.
- Default ground remains unknown and low points remain unclassified. Declared rig height, broad support, two consistent fresh frames, normal pose, and confidence are required before removing horizontal floor inliers. Wrong-height table surfaces, time gaps, generation changes, and tracking loss do not inherit a trusted floor.
- Mismatched/expired input and mixed-source-frame geometry cannot emit current events. Duplicate source frames are ignored. Optional schema additions remain compatible with old version-2 values.
- First events persist independently of UI snapshot delivery; urgency order, explicit acknowledgment, tombstones, expiry, generation isolation, immutable pending IDs, and stop behavior pass. Overflow returns the rejected batch atomically while preserving urgent pending events. A synchronous stop from the ledger callback cannot publish an old result.
- The native integration allocates synthetic image/depth/confidence CVPixelBuffers with row padding, copies only actual pixels, and feeds the real processor/ledger. These are mock capture inputs, not ARKit measurements or a physical image-alignment test.

## Limits and required physical evidence

Thresholds are engineering hypotheses: 0.3–4.0 m window, 2 × 2 aggregation, ≥2 tile samples, ≥8 component samples, 0.20 m depth/0.25 m neighbor gates, 1.0 m corridor/urgent range, and 32 components. Thin objects, discontinuous/reflective surfaces, tilted terrain, occlusion, and dense scenes require held-out testing; dropped samples/components never mean clear space. No sensor-reliability or safety probability is computed.

Ground is only an initial gravity-horizontal model for a declared measured rig. It is not a general floor/ramp estimator. Default handheld capture does not remove floor. A3 does not implement rolling occupancy, steps, drops, overhead hazards, motion, semantic detection, or A4's full disagreement/quality model. Per-frame observation IDs do not constitute object tracks.

Physical protocol remains unexecuted:

1. Freeze source/config/calibration versions; record phone/OS/depth kind, viewport, mount, lighting, surfaces, measured ground truth, input availability, and all exclusions.
2. Use a stationary/protected rig. Compare ahead/left/right ordinary obstacles and matched negative scenes, including dark/absorbing, reflective, thin, missing-coverage, and camera-only conditions. Record false alerts, misses, unavailable trials, range errors, and denominators.
3. With B3's renderer, verify image/depth/projection alignment on an asymmetric measured target after rotation/cropping; discard wrong-frame overlays. The text-only Research screen cannot establish this result.
4. With B3 feedback, verify first-event timing, urgent interruption, deduplication, acknowledged delivery, ledger backpressure, pause/background/viewport cancellation, restart generation isolation, and no stale speech/haptics. Fixture ledger ordering alone does not pass T20's real output behavior.
5. Collect the predeclared G1 ordinary-obstacle and negative-scene evidence in specification Section 20, then record a bounded activation decision. Measure capture-to-geometry/output timing and resource/thermal behavior; no configured deadline is a measured worst-case guarantee.

Current coverage is an initial G0 software subset and partial T01/T02/T04/T05/T06/T07/T08/T12/T20/T46 foundations. Full physical scenario acceptance and all output/user evidence remain pending. Ordinary live activation is disabled; opt-in Research analysis and synthetic historical results are labeled accordingly.
