# C0 compatibility audit — October 22, 2026

This audit records the initial compatibility baseline; later C1–C4 records describe subsequent changes.

## API and deployment inventory

Current build: Xcode 26.2 (17C52), Swift 6 package, provisional iOS 17/macOS 14. `project.yml` has no UIRequiredDeviceCapabilities or AR/depth/accessory installation filter; target family is iPhone. ARKitDriver uses rear ARWorldTrackingConfiguration and individually probes raw/smoothed scene depth. CaptureCoordinator currently rejects worldTrackingUnsupported even for image-only requests. FrameDescriptor currently requires intrinsics and a world matrix. These are C1 migration blockers. Renderer consumes only image/display metadata, while unprojection, pose bases, quality depth metrics, world occupancy/motion, handrail verification and relocalization consume calibration/pose and must fail closed on absence.

Native image inference uses Vision/Core ML and explicit image orientation. Accepted door/elevator/handrail weights and physical accuracy remain unavailable. Model presence is not evidence authorization. Output availability is separately checked by existing PhoneOutputSink; speech/haptics cannot be automatically substituted for a muted selection.

| Floor | Required substitutions / work | Evidence and decision |
| --- | --- | --- |
| iOS 17 | Current two-argument SwiftUI onChange and existing native modules compile here; no UI rewrite needed | Retain provisionally, pending install/device matrix |
| iOS 16 | Replace two-argument onChange throughout UI; audit SDK availability by actual lowered-target build and rerun persistence/render/output tests | Unmeasured added work; no iOS 16 runtime/device available |
| iOS 15 | iOS 16 work plus replace NavigationStack, ViewThatFits and presentation APIs, review concurrency/runtime backdeployment and model deployment targets | Unmeasured added work; no iOS 15 runtime/device available |

No floor is lowered without a successful actual build/install and maintained baseline journeys. Current toolchain availability does not establish physical compatibility or security support of any older OS. The final oldest maintainable/testable floor is an open pair decision. This retains, rather than raises, the current provisional floor.

## Available matrix

- Xcode Simulator iOS 26.3: iPhone 17 Pro booted, iPhone Air/17/16e and others installed. Simulators provide UI/software evidence, not sensors.
- `xcrun devicectl list devices`: paired iPhone 17 (iPhone18,3) is unavailable. OS and usable hardware state were not supplied.
- Missing: available real non-LiDAR rear camera phone, available depth phone, smallest supported display, OS-floor installation runtime/device, named operators and participant/accessory access. No row passed physically.

## Contract increment

CompatibilityContracts provides revisioned probes, D/T/C/N profiles, independent operation/authorization/evidence inputs and one feature evaluator. Its Cartesian tests cover hardware/permission/operation/forced-mode combinations. Defaults keep models, geometry and spatial memory disabled; manual notes/routes/reports remain eligible without camera. This evaluator expresses eligibility, not completion of B6–B11 workflows.

C1 will migrate optional calibration/pose, backend identity/revision and live consumers together. C2 will consume eligibility in existing processing; unopened product screens remain with Aarav. C3 will add bounded resource policy and actual timing collection. C4 will extend release accounting to R23/T49–T64 and retain all missing physical gates.

C0 remains in progress pending pair review, final OS-floor decision and actual device/operator inventory. No release/support claim is established by this audit.
