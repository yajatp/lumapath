# B2 renderer validation

Owner: Aarav. Requirements R01/R03; scenarios T08/T11/T12. Implementation and automated validation are delivered; physical M1 acceptance remains pending. Aarav authorized direct main pushes using HexboxRC and continuation before B1 manual review is complete.

Baseline: ffe97aa2b132d5b95954e23deab6c8e00ee10638. Windows host has no Swift/Xcode. Hosted macOS CI supplied the passing native compilation and simulator checks recorded below. No physical phone, VoiceOver, sustained frame-time, memory, thermal, or hardware rotation result is claimed.

## Boundary and resource design

The live consumer uses A2's single ARKitSensorProvider. It requests permission only on Start; stops and invalidates on leaving, pause, end, Help, background or capture interruption; resumes with a fresh generation. Static preview only reads the bundled synthetic PNG. No native buffer or lazy CIImage leaves the read-only lease. Core Image renders synchronously into owned RGBA bytes before lease return. One CIContext disables intermediate caching, one newest-only producer stream feeds the consumer, output is capped at 1280 on its longer side (maximum 6,553,600 bytes per RGBA image). Replacement can briefly coexist with the prior output and temporary Data/Core Image storage; this is an allocation bound, not measured resident memory.

Frames are checked before and after rendering, cleared at their deadline and on producer freshness loss. Main-actor rendering is synchronous and may delay UI/timers; physical responsiveness and dropped-frame rates must be measured before acceptance. Per-frame render duration and rejected-render count are available in live Renderer diagnostics. These metrics are not stored or uploaded.

Producer imageToDisplay is applied exactly once. Conversion from top-left normalized coordinates to Core Image's bottom-left pixel space is explicit. RendererRequest overlays require exact displayed descriptor equality, context, orientation, viewport and freshness. Only original imageBounds enter projection; already transformed displayBounds are not transformed again. B3 owns live hazard overlays/output; B2 does not activate unvalidated Research sensing.

## Automated checks

- Swift package: aspect-fill fixture landmarks, projection/clipping, invalid values/output budget, stale frame/context/viewport rejection.
- Native simulator: image adjustments, original bypass, rotated/cropped color landmarks, lease invalidation, owned output after stop and missing confidence.
- UI: static preview toggle/reset and truthful unsupported live capture, plus existing B1 and producer journeys.

First hosted run 39703673122 (historical private CI), job 119578529663, at 8c0e372eca614ad68a458b9a5e4e426c26b0be32 passed: 75 Swift package tests, eight native tests, eight UI journeys, four Python tests, model tool compilation and unsigned simulator build. XcodeGen 2.46.0 generated the project on that runner; its exact generated project and scheme were retrieved and committed, without hand editing. The final revision adds the public overlay layer, a positive geometry-projection check, finite transform protection and a stable image-surface intrinsic size.

## Physical acceptance still required

On supported depth and camera-only iPhones: permission allow/deny/restrict, live original/enhanced behavior and edges, portrait/landscape overlay calibration, viewport changes, frame loss, interruption, background/foreground and rapid start/stop. Record device/OS, frame/render p50/p95, deadline drops, memory/thermal behavior over a sustained run, large text and VoiceOver controls. Missing confidence must remain unknown. M1 remains open until reviewed evidence exists.

## Final source evidence

Hosted run 39704115334 (historical private CI) at e2ca61a60437cdfaadf4b80ee5dd656e8cedf02d passed 76 Swift package tests, eight native tests, eight UI journeys, four Python tests, model-tool compilation and unsigned simulator build. XcodeGen 2.46.0 regeneration matches the committed project with git diff --exit-code. Both B2 runs completed successfully; no B2 test failure was suppressed.

Environment: GitHub macos-15-arm64 runner, macOS 15.7.9, Xcode 16.4, iPhone 16 Pro simulator on iOS 18.5. Commands were swift test; python3 -m unittest discover -s Research/Models -p 'test_*.py'; swiftc model-tool compilation and --help; xcodebuild generic iOS Simulator build; xcodebuild iPhone Simulator test with CODE_SIGNING_ALLOWED=NO and -parallel-testing-enabled NO. Local git diff --check passed. Documentation/evidence-only commits after this source revision do not change the tested Swift/project/workflow files.

Fixture SHA-256:

- synthetic-scene.png: 1c11587484ad75cefd05dbebb5ce43e272706cd2d04f67f67e9f29dbce52eeef
- frames.json: bedcafd5dec5c5760e822b820c8eec893fe8da4f198f6bc45b71c72d5812a56f
- aspect-fill-examples.json: 2f226f2df526d2709594555cfe53c9c99b9cd17231f38e553c425f11bb7d7641

No device performance or sensing benefit is established by these simulator/fixture passes.

Subsequent documentation-only CI run 39704575627 (historical private CI) at b7492c9 failed the unchanged A2 independentTimerDetectsAStreamThatNeverProducesAFrame assertion at CaptureCoordinatorTests.swift:223 after a scheduled wait. The final B2 source run above passed; this later failure matches the timer sensitivity already recorded in B1. No B2 code changed between those revisions. Yajat retains ownership of producer timer-test investigation. B3's first run passed that same package suite.
