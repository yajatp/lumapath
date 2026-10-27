# A2 validation — October 21, 2026

Owner: Yajat. Baseline: `4a291d2` (A1). A2 capture implementation is delivered; physical-device validation, Aarav's B2 renderer/review, and M1 joint acceptance remain pending. A3/A4 perception and quality assessment are not implemented by this change.

## Local results

| Check | Result | Evidence/scope |
| --- | --- | --- |
| Swift package tests | PASS — 22 tests, zero failures | 10 domain/replay + 12 capture-controller/calibration tests |
| Native simulator buffer test | PASS — 1 test, zero failures | Original CVPixelBuffer identity/read-only access; supplied and absent confidence; stop invalidation |
| Native simulator UI tests | PASS — 2 tests, zero failures | Original replay control/restart journey plus honest unsupported-capture/demo fallback |
| Generic iOS Simulator build | PASS | Native iOS capture source compiles for simulator |
| Unsigned iPhoneOS build | PASS | Native adapter compiles against the device SDK; not installed or run on a phone |
| Hosted CI | Not run | Workflow updated; requires push/hosted execution |
| Actual camera/depth/permissions/rotation/performance trials | Pending | Paired iPhone listed as unavailable; no physical measurements claimed |

Environment: Xcode 26.2 (17C52), Swift 6.2.3, iOS/iPhoneSimulator SDK 26.2, iPhone 17 Pro simulator runtime 26.3. Minimum target remains iOS 17.0; compiling that target is not evidence of a run on iOS 17 hardware. Only expected App Intents metadata notices occur in passing builds; no unsafe raw-buffer Sendable conformance was introduced.

Commands used:

```sh
swift test
xcodegen generate
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/lumapath-a2-derived build
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/lumapath-a2-device build
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'platform=iOS Simulator,id=805CB9F9-E484-4D6A-938F-2418C3131D21' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -derivedDataPath /tmp/lumapath-a2-derived \
  -resultBundlePath /tmp/lumapath-a2-final.xcresult test
```

The local test result bundle `/tmp/lumapath-a2-final.xcresult` is temporary and not required to reproduce tests. Source tests and generated fixtures are committed with the implementation; `Evaluation/A2-fixtures.json` records hashes. The native buffer test uses allocated synthetic CVPixelBuffers, not captured ARFrame data.

## Verified software behavior

- Runtime world/depth capability selection and authorization gating before driver start; denied/restricted permission and unsupported tracking never start the driver or request inappropriate permissions.
- A pending permission result after Stop or task cancellation cannot start capture later. A new generation is required for same-session restart; old-run callbacks and pre-start timestamps are rejected.
- Raw scene depth is preferred. Smoothed depth is explicitly identified when selected. Camera-only frames have no depth; absent confidence remains nil. Metadata is never substituted with a simulated live-depth frame.
- Frame identity, original timestamps, calibration, viewport transform, tracking, and pixel dimensions are preserved through the controller. Frame publication is coalesced/throttled; dropped frames do not queue an unbounded processing backlog.
- One latest retained buffer set, a newest-only delegate mailbox, and one processing frame bound application-owned raw retention to at most three; ARKit internal buffers are outside this bound. Generic eviction/lifetime tests and the native original-buffer test exercise access invalidation. Device memory consumption is not measured.
- Access-time expiry, independent scheduled missing-frame detection, cancellation hook, and recovery behavior work with injected clocks/drivers. Stop/interruption/failure/viewport changes invalidate leases. Releasing a coordinator stops its exclusively owned driver on MainActor.
- Four generated aspect-fill examples preserve centers, landmark direction, cropped corners, resolution calibration, and missing confidence. The native provider uses ARFrame.displayTransform directly; these examples do not establish alignment on an actual camera view.
- The diagnostic entry point is metadata only; it exercises the actual native lease boundary when supported. It provides no obstacle warnings, geometry inference, image enhancement, or live camera rendering.

## Physical protocol — not executed

1. Record phone model, OS, app source revision, SDK, schema/config versions, selected depth kind, viewport pixels/orientation, and authorization state. Select a signing team and connect a supported device. Keep camera tests stationary.
2. On a clean authorization state, tap Start capture. Record permit/deny/restricted behavior, Settings recovery, and whether an inactive permission prompt requires a new explicit Start. Confirm no camera permission is requested by demo/unsupported entry.
3. On a depth-capable phone, verify original image/depth/confidence sizes, formats, intrinsics, pose, capture timestamps, and selected scene versus smoothed kind. On a world-tracking phone without depth, verify camera-only metadata and absent depth. Do not infer capability from the paired-device name.
4. With Aarav's B2 renderer or a reviewed calibration consumer, present an asymmetric measured calibration target. Check portrait/both landscapes, aspect-fill crops, depth/image alignment, exact viewport identity, missing confidence, and overlay mismatch discard. The metadata-only diagnostic cannot establish rendered alignment by itself.
5. Pause/stop, leave the screen, background, and interrupt capture with a system event/call. Verify camera stops, leases fail, and no previous-frame output can survive. Restart explicitly with a new generation and verify genuinely fresh data before use.
6. Simulate stalled callbacks in a controlled debug harness; record observation access rejection and missing-frame notification times under representative load. A configured 300/500 ms target is not a measured worst-case timing guarantee.
7. Measure retained-frame counts, memory, capture-to-consumer time, and thermal/render behavior over sustained operation. B2 measures read/copy/render costs under the synchronous lease restriction. Record failures and unavailable trials with denominators.

Coverage: initial G0 software subset and partial T06/T07/T08/T12 foundations. T11 glare/renderer behavior, full T12 physical alignment, G1 sensing, G2 output/accessibility, T45 sustained performance, and M1 end-to-end acceptance remain pending. No physical gate is marked passed.
