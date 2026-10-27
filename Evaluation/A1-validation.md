# A1 validation — October 21, 2026

Scope: Yajat's A1 foundation. The expanded MVP and milestone M0 are not declared complete. Aarav's B1 shell/consumer review remains pending. All images, obstacle events, quality states, and depth calibration fixtures in this change are synthetic.

## Executed checks

| Check | Result | Evidence |
| --- | --- | --- |
| `swift test` | PASS — 10 Swift Testing tests, zero failures | `LumaPathTests/ContractTests.swift` |
| XcodeGen 2.46.0 generation | PASS | `project.yml` and committed `LumaPath.xcodeproj` |
| Unsigned generic iOS Simulator build | PASS — arm64 and x86_64, iOS 17 deployment target | LumaPath scheme, Xcode 26.2, SDK 26.2 |
| Native simulator control/restart journey | PASS — 1 XCTest UI test, zero failures | `LumaPathUITests/ReplayJourneyTests.swift`, iPhone 17 Pro / iOS 26.3 |
| Hosted CI | Not run | Workflow committed, requires push/hosted execution |
| Physical capture, renderer, feedback, accessibility participants | Not performed | A2/B1/B2/B3 and physical evidence remain pending |

Commands actually run from the repository:

```sh
swift test
xcodegen generate
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/lumapath-a1-derived build
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'platform=iOS Simulator,id=805CB9F9-E484-4D6A-938F-2418C3131D21' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -derivedDataPath /tmp/lumapath-a1-derived \
  -resultBundlePath /tmp/lumapath-a1-ui-release.xcresult test
```

The final local UI result bundle is `/tmp/lumapath-a1-ui-release.xcresult`; it is a temporary machine-local artifact, not required to reproduce tests. Domain and UI logs were inspected locally. Xcode emitted only the expected App Intents metadata notice for a target without AppIntents; no compiler warnings/errors remained in the passing build.

The first UI run exposed idle expiry publication disabling Start. Expiry now emits only on a state change, and Start permits idle. The next run exposed offscreen diagnostic controls; the controls now stay in a bottom safe-area inset. The final native run passed through the full sequence, recovery from unavailable input to the ordinary fixture, and fresh app restart.

## What the domain tests establish

- Schema rejection, invalid/future/expired timestamps, different modes/sessions/generations, duplicates, and out-of-order frame rejection.
- Pause/end clear current observations; resume requires fresh evidence; restarting after end uses a new session identity.
- Geometry/event/frame identity checks and reference consistency; expired observations do not remain current.
- Four generated orientations, mismatched image/depth sizes, explicit missing confidence, scaled intrinsics, optical versus ARKit signs, invalid depth rejection, and axial versus Euclidean range distinction.
- Three-entry storage cap, eviction invalidation, and clearing retained entries.
- Independent watchdog helper's single outage report and recovery behavior.
- Rebased fixture uptime, ordinary/limited/paused/unavailable snapshots, and newest-only transport behavior with no stale events after pause.
- Synthetic PNG dimensions match the static frame descriptor.

This is an initial G0 deterministic subset. It does not test cancellation of real speech/haptics/watch output or integrate live ARKit, which are not implemented. T06/T07/T08/T12/T46/T48 have foundation checks only. No physical depth accuracy, projection alignment, latency, dark-scene sensing, regional quality, or user-benefit result is claimed.
