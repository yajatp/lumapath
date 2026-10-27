# B1 validation and pending acceptance

Date: October 21, 2026 (America/Chicago). Baseline `c1b817f015b34471cd2c5f5a953ae987e14c4686`; branch `codex/b1-accessible-shell`. Capture contract/config 2/2 unchanged. Human reviewer: pending Yajat. M0/G0/G2 joint acceptance remains open.

## Executed local checks

- `git --version`: 2.55.0.windows.2.
- `Get-Command swift,xcodebuild,gh -ErrorAction SilentlyContinue`: none available. No local Swift, simulator, device or Xcode build was executed.
- `git diff --check`: passed for implementation (only checkout line-ending notices).
- SHA256 checks of bundled fixtures executed with `Get-FileHash`; values below are Windows working-copy bytes, including checkout line endings. Git blob IDs identify canonical repository objects.
- Connected GitHub access and authenticated clone/push succeeded. No service/provider credentials or model assets were requested.

## Hosted checks

The existing macOS workflow now also runs native and UI tests on an available iPhone simulator. It does not substitute for a physical phone or watch.

- Initial run 39699904022 (historical private CI) at `7e77cae`: failed during compilation of new Swift Testing assertions. The shared interaction contracts compiled; mutating `shell.receive` calls inside `#expect` needed explicit Boolean comparisons. Fixed in `063bd29`. Later steps were skipped; no pass is claimed for that run.
- Run 39700033729 (historical private CI) at `063bd29`: 71 package tests, four Python tests, both model-tool compilation/help checks, unsigned simulator build, five native tests and five of six UI journeys passed. The cross-tab journey failed: a session footer outside `TabView` overlapped tab controls. Fixed by moving the footer to each tab's navigation container; nested Sensing details gained a regression check too.
- Run 39700496283 (historical private CI) at `988b06c`: existing producer test `independentTimerDetectsAStreamThatNeverProducesAFrame` failed at `LumaPathSensorTests/CaptureCoordinatorTests.swift:223`. Its 160 ms real-time sleep is sensitive to scheduling on the shared runner (inference, not a proven cause). Other tests passed. The test and producer were not changed by B1; Yajat should investigate an eventual-condition assertion with a bounded deadline. No sensor behavior fix or ownership transfer is claimed.
- Run 39700581957 (historical private CI) at `d90f1872f6bf70f099ca947aeb495b8e85357b64`: **passed**. All 71 package tests (including six B1 consumer tests and the unchanged timer test), four Python tests, both model-tool compilation/help checks, unsigned simulator build, five native tests and all six UI journeys passed. The cross-tab/nested-screen and largest-text regressions pass. Final evidence/documentation edits change no tested Swift, workflow, project or fixtures.

Hosted environment observed in logs: macOS 15.7.9 arm64, Xcode 16.4, iPhone 16 Pro simulator with iOS 18.5. This differs from Yajat's Xcode 26.2 baseline. No claim of a physical iOS 17 compatibility result is made.

## Automated scenarios added

Six domain tests in `LumaPathTests/InteractionTests.swift` use A1's actual fixture loader/stream and an injected fixed clock: replay through ordinary/limited/paused/unavailable/end; expiry and stale-generation rejection; new-session/restart rejection; unchanged hazard evidence under profile/tab changes; frame/viewport/orientation/expiry renderer rejection; sequence ordering.

The existing UI sources now cover four tabs and nested sensing details retaining session controls, Help and background requiring explicit resume, largest text control reachability, demo restart, simulator capture unavailability and Research navigation under Settings. UI text/state tests are not a VoiceOver or visual-layout audit.

## Fixture identities

| Path under `LumaPath/Shared/Fixtures/` | Git blob | Windows SHA256 |
| --- | --- | --- |
| `ordinary-to-unavailable.json` | `020c10a26da62a0b7e41967c28ffa89e8ae114c0` | `529d266e7c57025ebc4301328be496e55614319027ac227d9fa493d098ce8b35` |
| `frames.json` | `4f8482969993fab4bcda211f2bcbc023e12fc227` | `bedcafd5dec5c5760e822b820c8eec893fe8da4f198f6bc45b71c72d5812a56f` |
| `synthetic-scene.png` | `2d15db37fd1ce68462ebe288384a8d9cb2ba9334` | `1c11587484ad75cefd05dbebb5ce43e272706cd2d04f67f67e9f29dbce52eeef` |

The fixture set is unchanged; no recorded surroundings, provider response, live camera or target detector is simulated as real.

## Manual/device acceptance still required

1. On the reviewed commit, run `swift test`, unsigned simulator build, and `xcodebuild ... test` using the README commands. Record exact Xcode/Swift/runtime and result.
2. In portrait and landscape at largest Dynamic Type, inspect clipping/scrolling and reach Pause/Help/End on every tab. Exercise VoiceOver, Switch Control, Bold Text, increased contrast and Reduce Motion. Verify focus is stable as fixture evidence expires.
3. Inject a throwing service factory: confirm failure explanation/disabled Start/Retry; restore a valid fixture and verify recovery. Check a missing reference image leaves controls usable.
4. Skip/reset/keep preview choices, reopen preview, then restart app. No change may suppress/alter hazard evidence; restart must retain no session observations. B4 persistence remains out of scope.
5. Run stationary physical phone and later B3 cue tests before claiming output/accessibility G2. No physical capture, watch, spatial audio, participant, service, provider or research result was collected for B1.

R22/T46/T48 are partial foundation coverage, not full release/replay-export/persistence-migration completion. B1 stays in progress pending review and remaining acceptance evidence.
