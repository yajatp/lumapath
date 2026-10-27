# A5 Research implementation — October 21, 2026

Owner: Yajat. Baseline HEAD `96b17a0` plus the existing uncommitted A4 increment. A5's Research producer implementation is delivered; **physical validation, Aarav review/B5 integration and joint M4 acceptance are pending.** All six families remain unavailable in ordinary live use.

## Implementation and evidence

- Sparse rolling world occupancy distinguishes occupied, sampled observed-free and unknown cells. It filters high-confidence finite/range-supported depth, caps rays/cells, expires history and clears on tracking loss, abrupt pose change, invalid origin or generation change. Free samples do not establish traversability. No missing-return ray creates a drop.
- Overhead, narrow-passage, positive/negative step and stair candidates require current measured cells, calibrated confirmed ground and two temporally consistent frames with at most 5 cm translation and 0.08 radians of pose rotation between confirmations. Passage candidates require two measured boundaries and sampled intervening cells. Step candidates require contiguous coarse lateral support with overlap across the two measured patches. Down-step candidates require two supported height levels; missing depth alone is insufficient. Historical cells cannot renew a current candidate's deadline. Stair candidates require three consistent height transitions across measured patches.
- Camera-compensated association samples component interiors and uses world positions, unique nearest-neighbor/extent gates, ambiguity abstention, short bounded histories and velocity uncertainty. Insufficient baseline, excessive residual/uncertainty, tracking loss and abrupt turn suppress prediction. Static geometry remains static during tested translation/slow sweep; moving fixtures produce bounded encounter estimates. This is generic moving geometry, not a trained person model.
- Each family has a separate Research activation record. Explicit profile width/clearance and earlier notice affect evidence/priority; they cannot weaken a close event. Prediction never removes generic proximity events. Advanced event references are separate from A3 component IDs, and remain Research scoped on the acknowledged ledger with inherited measurement deadlines.
- Existing **Geometry research** and opt-in **Analyze depth in Research** now invoke the advanced processor. Synthetic ground-calibrated fixtures use the declared rig assumption; arbitrary live handheld capture has no floor calibration and cannot produce precise height/terrain categories. These diagnostics play no feedback and do not implement B5.

`swift test` passes **65 tests**, including eight advanced tests and seven semantic tests alongside the prior 50. Static-family tests replay explicit analytic world voxels; an additional raw depth → calibrated floor → rolling occupancy → overhead candidate → event test exercises integrated processing. These do not replace held-out raw-depth tests for every category. `Evaluation/Prediction/A5-fixture-results.json` records actual synthetic interpolation residual/encounter output from the passing run. Five native tests pass, including real OCR and lease encoding; the three existing UI journeys also pass (the full run preceded final native-only assertions/diagnostics changes). No physical accuracy, collision probability or worst-case performance is claimed.

```sh
swift test
xcodegen generate
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'platform=iOS Simulator,id=805CB9F9-E484-4D6A-938F-2418C3131D21' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -derivedDataPath /tmp/lumapath-a5a6-derived \
  -resultBundlePath /tmp/lumapath-a5a6-full.xcresult test
```

Final native-only run uses `/tmp/lumapath-a5a6-complete-check.xcresult`; source/fixture hashes are in `Evaluation/A5-A6-fixtures.json`. Logs are temporary local artifacts. Xcode reports dependency-scan warnings for Domain dependencies despite explicit Package.swift declarations, plus expected App Intents notices; warnings are recorded and not suppressed. Package tests and tooling build without compiler warnings.

See [protected protocol](Sensing/A5-protocol.md) for reflective/absorbing/thin surfaces, missing ground, camera sweep, moving adults, guarded steps and category promotion. The paired iPhone is reported unavailable by `devicectl`; no device or watch experiment ran. Initial thresholds, voxel quantization, sparse sampling, floor assumptions, object shape/occlusion changes and association switches remain substantial limits. A5 retains its provisional 7-point estimate; actual hours and human review are not recorded.


A5–A7 continuation: the existing A5 suite, including the raw-depth integrated replay and camera-motion cases, passes in the 77-test package run. No A5 detector thresholds or activation gates changed. See `Evaluation/A7-validation.md` for the new increment; physical/B5/M4 acceptance remains pending.
