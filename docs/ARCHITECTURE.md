# Architecture

LumaPath separates capture, evidence processing, presentation, and output. The app’s main entry is `LumaPath/App/LumaPathApp.swift`; `Package.swift` defines the reusable modules and their test targets.

## From camera to presentation

1. **Capture:** `LumaPath/Sensors/` selects an available backend, requests permission on explicit start, and supplies frame identity, bounded image leases, and available calibration/depth metadata.
2. **Perception:** `LumaPath/Perception/` processes geometry, quality, semantics, and experimental motion/occupancy. `LumaPath/Models/` verifies bundled model identity and runs local inference.
3. **Evidence:** shared contracts bind observations to the original frame, session, generation, and expiry. Missing depth stays unavailable. Risk and goal modules apply their own evidence and Research gates.
4. **Presentation:** `LumaPath/Rendering/` owns rendered pixels and matched overlays. SwiftUI screens select presentation styles independently of permissions and sensing activation.
5. **Feedback:** `LumaPath/Feedback/` arbitrates optional phone and accessory output. Pause, End, interruption, and expired evidence cancel stale output. Speech does not extend an observation’s lifetime.

Frame-backed observations expire after 300 ms. Session and generation checks reject late callbacks. Image enhancement never creates depth or changes a sensor measurement. Research access does not imply physical validation.

## Other modules

| Module | Responsibility |
| --- | --- |
| `Memory` | Protected place archives and experimental alignment/change handling. |
| `Goals` | Reviewed command parsing, goal resolution, and explicit unavailable targets. |
| `Personalization` | User-selected presentation and profile behavior. |
| `Routing` | Offline graph contracts and constrained route-planning infrastructure. |
| `Accessories` / `WatchApp` | Bounded Research messages and optional Watch controls. |
| `Attention` | Arbitration of optional interaction and feedback. |

## Optional service and offline research

`Server/` is separate from the local camera workflow. It implements authenticated community-report storage, moderation, public projections, and operations tooling. It requires operator configuration before identity exchange and is not a deployed production service.

`Research/` contains explicit offline experiments. Synthetic fixtures exercise software boundaries and support reproducibility; they do not establish detector accuracy, sensor calibration, or benefit to users. Learned-policy experiments do not automatically activate app capabilities.

## Project structure

`project.yml` owns Xcode target/resource configuration. Regenerate with XcodeGen 2.46.0 when changing it and review the generated `LumaPath.xcodeproj` diff. The checked-in project lets reviewers build without installing XcodeGen.
