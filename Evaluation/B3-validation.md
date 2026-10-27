# B3 phone output and session integration

Owner: Aarav. B3/M2, R04 baseline and R07, T01/T02/T20/T46. Baseline b7492c9c38a2e461cdf019dc59b1c8ba8e2a3733. Direct main commits under HexboxRC are authorized. Implementation and automated validation are delivered; physical acceptance remains pending. M0/M1 review and physical evidence remain open; this work does not close G1/G2/M2.

## Scope and activation

Ordinary live view remains image-only. A3 emits research-scoped events and its physical G1 evidence is pending. Explicit Research opt-in in Live view connects the existing single A2 provider through GeometryPipeline to aligned B2 overlays, accessible text and independently chosen speech/haptics. Changing Research mode stops capture; Start is explicit. No advanced A5 categories are activated. Camera-only capture reports unknown obstacles, with no invented depth.

Settings → Phone cue preview plays all five proposed patterns/texts using the real phone sink. Both channels initially off; custom haptic support and failures are visible. The synthetic obstacle demo uses A3 fixtures and its actual pipeline/ledger, with a labeled analytic depth diagram. Full cue previews have their own explicit preview lifetime and are never current scene observations.

## Ownership, ordering and cancellation

FeedbackCoordinator reads and acknowledges HazardEventLedger separately from display snapshots. Acknowledgment means the consumer accepted responsibility or recorded an explicit muted/suppressed/rejected disposition; it does not certify audible delivery. Queue-full events stay in the ledger for retry, and a producer overflow stops the Research run visibly. The pending queue is bounded at 16 plus one suspended limitation slot; one item may play. Recent cue meanings and timing trace are bounded at 128 and handled IDs at 512. A full pending queue cannot block urgent interruption. Output has ID, context/generation, timestamps, source and cancellation reason.

Urgency and direction come from A3, with no distance-to-risk recomputation. Priority: urgent (6), ordinary warning (5), limitation (4), informational side obstacle (3), requested goal (2), optional/preview (1). The optional and limitation inputs are integration APIs; A4's real limitation-event producer remains unfinished. An interrupted limitation stays queued until its original deadline, while optional descriptions are discarded. Same cue meaning/direction repeats are suppressed for three seconds; severity increases bypass suppression. A3 observation IDs change per frame, so this is semantic cue coalescing, not stable object tracking. Multiple objects with the same directional meaning may coalesce; physical review must assess this limitation. All optional descriptions share a ten-second start interval, even when their text/key differs.

AVSpeechSynthesizer and one Core Haptics player provide actual output. Speech uses the available English voice and normal rate; no volume override or spatial claim. Core Haptics support is checked; no non-cancellable delayed UIKit pulse queue is used. Engine/voice callbacks are tied to the current item identity. Pause/Help/End/background/route interruption, channel change, frame/viewport loss and generation changes cancel current and queued output. Explicit restart is required after interruption; no old queue is resumed.

## Timing limit

Scene evidence keeps A3's original 300 ms deadline, checked before enqueue and playback; the native sink owns an independent cancellation deadline. Live integration also drains/ticks every 25 ms. Timers share the main actor and are not hard realtime guarantees. Engine setup is rechecked against expiry. The short two/three-pulse patterns fit within 290 ms, but full spoken sentences generally do not fit a 300 ms scene lifetime and may be truncated. This unresolved physical usability/latency issue is recorded rather than extending evidence expiry. The stationary preview allows eight seconds for a complete example, explicitly separate from scene evidence.

## Validation plan and limits

Windows host has no Swift/Xcode; hosted macOS ran package, native and UI checks and regenerated with XcodeGen 2.46.0. Tests use an injected sink/monotonic clock for first ledger delivery independent of snapshots, producer urgency ordering, urgent interruption, retained limitations, repeat suppression, expiry, late completions, pause/generation/viewport invalidation, backpressure, channel capability/muting and bounded trace. Native tests exercise actual pattern construction and stale/muted sink rejection. UI journeys exercise preview controls/background and default-off Research.

No physical iPhone output, VoiceOver coordination, earphone route fallback, render-to-cue p50/p95, participant cue comprehension, protected obstacle trial or battery/thermal measurement is claimed. G2 requires the documented consented stationary comprehension study (at least 20 randomized presentations per participant and the predeclared target), or remains explicitly pending. Physical G1 geometry and G2 output validation are needed before ordinary live activation.

Apple API references: [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer), [CHHapticPatternPlayer](https://developer.apple.com/documentation/corehaptics/chhapticpatternplayer). No microphone/speech-recognition permission, cloud service, target model, Watch output or message sending is introduced.

## First hosted execution

Run 39709136809 (historical private CI), job 119596019007, at e20fbda9a5842ef15a0809f7698e03ff2adac2aa passed 86 package tests, ten native tests, ten UI journeys, four Python tests, model-tool compilation and unsigned simulator build. The exact XcodeGen 2.46.0 generated project/scheme were retrieved and committed without manual project editing. Logs contain simulator voice-asset lookup errors; these are not proof of audible speech. The UI test exercises playback only when an English voice is available, and always verifies muted/stop/background controls. Native tests validate pattern construction and stale/muted requests; physical audible/vibration delivery remains pending.

The final refinement adds global optional-speech throttling across different descriptions, per-play callback tokens, explicit ability to turn off a failed channel, and avoids idle 40 Hz UI invalidations. Final source CI is recorded below.

## Final automated evidence

Run 39709759864 (historical private CI) at ccacece096d63c031757563adb7e54eb3f31e586 passed 87 Swift package tests, ten native tests, ten UI journeys, four Python tests, model-tool compilation, unsigned simulator build and XcodeGen generated-project consistency. Both B3 source runs passed; no failing B3 check was suppressed. Subsequent evidence-only commits do not modify tested Swift/project/workflow files.

Hosted environment: macOS 15.7.9 arm64, Xcode 16.4, iPhone 16 Pro simulator on iOS 18.5. Commands: swift test; Python unittest discovery; swiftc compilation and --help for model tools; xcodebuild generic iOS Simulator build; xcodebuild iPhone Simulator test with CODE_SIGNING_ALLOWED=NO and -parallel-testing-enabled NO. Local git diff --check passed. A3-scenes.json SHA-256: f7b59768d19175e108afedd5d8d9844609f3af0c1661157fa16747d57e9348fd.

Controlled-clock trace asserted by the pipeline consumer test (synthetic scheduling evidence, not measured physical latency): at t=100.000 the first A3 event starts and is acknowledged without reading its presentation snapshot; at t=100.300 the playing item is expired and the sink receives cancel(expired). Separate tests assert priority cancellation, original-context rejection, late-completion protection and queue-full retention.

Physical output, protected G1 obstacle trials, G2 comprehension and M2 acceptance remain unperformed.
