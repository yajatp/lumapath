# B6 Find, commands and local attention — October 22, 2026

B6's local software consumer is implemented. Hosted validation of the final continuation passed; see the exact source and run below. Ordinary Find activation, trained door/elevator/handrail assets, physical speech/OCR timing, accessibility trials and Aarav/Yajat M5 review remain open. B7 spatial saved-landmark integration and B11 remote Jev integration are separate work.

## Delivered user flow

- Find replaces the placeholder with typed English input, common-target buttons, explicit command review/confirmation, clarification, Help and Stop. Entering Find ends the demo session. Saved place notes remain available from the Find toolbar without camera or speech.
- The existing closed parser permits door, exit sign, elevator indicator and handrail targets, saved landmarks, pause/resume/repeat/next/cancel and minimal/standard/descriptive detail. Case, whitespace, one leading “please” and trailing punctuation are the only normalization. Commands are bounded to 1,000 characters. Negation, ambiguous/compound requests, unsupported language and communication actions produce clarification without partial execution. No messaging, sharing or publishing implementation is present.
- A proposal is bound to capture session/generation/mode, goal UUID and profile revision, and consumed once. A replacement submission, pause, Stop, goal/profile change or session end invalidates obsolete review/optional decisions. Scene/report/remote provenance cannot create or replace a user proposal. No OCR text is passed to the parser or interpolated into candidate output.
- `PushToTalkModel` requests speech and microphone permission only after Speak. It checks runtime English on-device support and availability, and sets `requiresOnDeviceRecognition = true`. There is no network fallback. One utterance is limited to fifteen seconds. Partial/final text is never executed automatically: the user reviews and confirms it. Review, Cancel, Help, tab change, interruption/route change, Stop and background stop recording; late permission/recognition callbacks are token-rejected. Typed/buttons survive refusal. Stop/pause clear the temporary transcript; no audio/transcript is persisted.
- Speaking explicitly pauses the current search first, avoiding simultaneous guidance output and microphone recognition. Resume is explicit. Changing detail affects only this search's presentation and invalidates optional output; it does not rewrite the saved profile or hazard thresholds. Selecting a changed saved profile recreates the Find consumer.

## Evidence and camera boundary

`FindModel` consumes A6's real `VisionOCRAdapter`, `GoalResolver` and `DepthAssociator` through the existing `LiveRenderModel`/`CaptureCoordinator`. It does not open a second camera. Copy/encoding occurs only for an explicit Research search, after geometry and quality processing, in the balanced resource preset, with one inference in flight and a minimum two-second request interval. Cancellation retains the in-flight slot until the old task returns, preventing an unbounded queue on the serial OCR actor.

Rear-camera orientation is mapped to the existing quarter-turn contract. The owned image and any depth retain their original descriptor. Context, goal/profile revision, original envelope and cancellation are checked after inference. There is no deadline extension: late results are rejected at the original 300 ms expiry. Candidate display, Repeat/Next and feedback recheck freshness. Viewport/image loss clears candidates and pending optional work. A6's prior simulator OCR exceeded the deadline; this integration does not establish real-time recognition on a device.

Automatic camera-only fallback binds the existing requested target to the new producer generation, invalidates previous reviews/attention and cancels the old inference. Unsupported targets retain their unavailable explanation. A callback after Stop cannot restart the goal. The native regression injects producer callbacks; it does not claim a physical fallback trial. Idle snapshots publish only when meaningful state changes, while the freshness check remains at 40 Hz. Resource-state explanations remain visible when optional OCR is suppressed in lean mode.

Exit-sign OCR is the only installed Research target. Its visual context and confidence checks remain in A6. Ordinary Find stays unavailable. Door/elevator-indicator/handrail requests explain the missing licensed/evaluated detector before pretending to search. Saved-landmark requests explain that the selected spatial place/alignment consumer is not connected. Manual notes cannot become remembered detections.

Candidate details use fixed templates: Research uncertainty, **current camera**, displayed-image left/center/right/outside-view, and measured same-frame range only when the producer supports it. Camera-only/sparse/ambiguous depth remains **distance unknown**; no world bearing or reachable/accessible exit is invented. Remembered/map/remote sources do not masquerade as current-camera candidates. After twenty seconds without a fresh candidate, A6's not-observed state offers Continue, Change target and Stop. User-confirmed completion does not verify exit access.

## Attention handoff

`LumaPath/Attention/LocalAttention.swift` is a pure local selector over bounded validated nonurgent candidates. It returns one allowed observation UUID or nil, lexicographically preferring the supported goal, current camera before remembered/map, novel information, and measured bearing/distance. Remote hypotheses are excluded from this baseline. It retains at most 64 information keys for thirty seconds, examines at most 64 candidates, and enforces the profile's 5–30 second optional-announcement interval. A selection consumes a budget slot even if an output channel is unavailable. Explicit Repeat/Next bypass this automatic budget but still require a current candidate and original expiry.

Goal/profile changes reset the local attention context and remove only optional queued/current feedback. Mandatory hazard and quality ledgers remain independent, with their existing priorities, acknowledgements and original lifetime. The attention API cannot veto hazards. Search Stop/Help/background intentionally stop the whole active session. Candidate speech may be cut short by the original 300 ms lifetime; no fresh-evidence claim is prolonged to finish a sentence. Timeout speech describes local search state rather than a scene observation.

Provider-neutral handoff fields are existing `CommandReviewContext`, `CommandProposal`, `FindCommand`, `AttentionCandidate` and `ObservationEnvelope`: capture identity/generation/mode, goal/profile revision, observation UUID, source, target, information key, actual optional bearing/range and original timestamps. A future remote serializer must retain these meanings and the bounded allowlist; no remote request or response execution is implemented in B6.

## Validation

Final tested source: `aec1c6c41547fc999e45d16d0491271c8a4f0b87`. GitHub Actions run 39887543165 (historical private CI) passed:

- **169 Swift package tests**.
- **20 native simulator tests**, including six Find/permission/fallback cases.
- **17 UI journeys**, including two Find journeys and the revised demo handoff.
- Unsigned iPhone and watch simulator builds; pinned XcodeGen project consistency.
- **60 service tests**; Python model 4, fusion 3, study 3 and release-audit 7 tests; compiled model-training/inference tools.

The final evidence edits were also checked locally with seven release-audit regression tests and the complete 23-requirement/64-scenario audit. On Windows, the three hashed Fusion inputs were temporarily restored to their committed LF bytes for the audit and then restored byte-for-byte to their original working copies; evidence hashes were not rewritten to hide line-ending differences. `git diff --check` passed. The documentation/evidence-only handoff commit does not change the tested source or test tree.

New checks cover six attention/presentation/permission-policy fixtures, mandatory-output preservation during optional invalidation, six native command/permission/fallback cases, and two Find UI journeys. Existing command foundation tests cover the entire grammar, adversarial input and review revisions; A6 tests cover actual Vision OCR, deadline rejection, semantic association and resolver timeout/loss. Native permission tests inject authorization results and do not claim a real microphone trial. UI tests cover typed clarification/confirmation, unsupported targets, largest-text Help/Stop and handoff from demo; they do not establish physical VoiceOver/comprehension acceptance.

Earlier continuation checkpoint `321a1a2` passed run 39886399329 (historical private CI): 169 package tests, 19 native tests, 17 UI journeys, 60 service tests, both simulator builds and model/fusion/study/release checks. An earlier obsolete shell test was updated for the intentional demo-to-Find handoff. One saved-note simulator typing mismatch in the previous run did not repeat at this checkpoint; the exact note-content assertion remains in place. The final native count includes the additional fallback regression.

The initial hosted project-only run intentionally failed the retained XcodeGen consistency check until its generated output was committed. A package-test compilation issue with Swift Testing's mutating-call macro was fixed by evaluating the mutation before the assertion. The original consistency check is preserved in the final workflow; the temporary read-only generated-file diagnostic has been removed. Windows has no Xcode/Swift toolchain, so Apple builds and execution use hosted macOS.

Reproduce:

```sh
xcodegen generate
git diff --exit-code -- LumaPath.xcodeproj
swift test
xcodebuild -project LumaPath.xcodeproj -scheme LumaPathWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
# Use an available iPhone simulator ID:
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath -destination 'platform=iOS Simulator,id=DEVICE_ID' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO test
python3 -m unittest discover -s Tools/Release -p 'test_*.py' -v
python3 Tools/Release/audit.py
```

`Evaluation/B6-physical-protocol.md` records the remaining protected T23–T26/T40-local/T59 checks. No physical evidence, ordinary target activation, external provider success or human sign-off is inferred from software tests. Source baseline before this continuation was `9ac8325`, including the LumaPath rename and the earlier command foundation (`18ba68d`, 162 package tests and unsigned build recorded by its author).

Apple API references: [on-device capability](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition), [required on-device recognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition), [speech authorization](https://developer.apple.com/documentation/speech/sfspeechrecognizer/requestauthorization(_:)), [microphone authorization](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)).
