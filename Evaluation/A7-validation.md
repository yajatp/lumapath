# A7 spatial-memory producer — October 21, 2026

Owner: Yajat. Baseline `c1b817f` plus this working-tree increment. Research producer software is implemented; physical G5 evidence, B7 integration and joint M6 acceptance remain pending. No ordinary live memory feature is enabled. A5 is revalidated; A6 still needs actual detector assets and held-out/device evaluation.

## Implementation

- `LumaPathMemory` supplies schema-1 place archives with explicit saved coordinate frame, revision, app version, timestamps, quality summary, bounded optional world map, geometric landmarks, confirmed labels and occupied/free/unknown cells. Session clocks are not persisted. At most 512 landmarks, 20,000 cells and 8 MiB world-map bytes are accepted.
- `PlaceStore` uses a caller-selected local directory, backup exclusion, directory mode 0700, file mode 0600 and iOS complete file protection. One checksummed atomic JSON envelope contains current data and one rollback revision. SHA256 detects corruption; it is not authentication or application-level encryption. Schema, identity, symlink, file size, total size and place-count checks fail closed. Use one shared store actor per directory. Defaults: 20 places, 100 MB total, 24 MB per encoded file. Base64/envelope overhead counts toward limits; storing two maximum maps can exceed the per-file cap and is rejected.
- Updates require the exact reviewed current revision. Rollback consumes its snapshot and issues a new revision. Deletion removes the entire envelope, including map, labels and rollback; this producer creates no other derivatives. B7 must also invalidate loaded objects/queued output and delete any derivatives it creates.
- `WorldMapArchive` uses secure keyed coding and typed `ARWorldMap` decode with error-return failure policy and bounded data. `ARKitDriver.captureWorldMap` requires mapped/normal tracking before and after asynchronous capture, checks the same driver run, and throws instead of reporting failed capture as saved. Restore securely decodes an initial-map hypothesis. Caller must establish a fresh capture generation and invalidate old processing before restore; restoring alone cannot enable memory output.
- `RelocalizationGate` binds selected place/revision, saved/current coordinate identities and capture context to a validated rigid transform. At least three distinct distributed, non-collinear landmark correspondences must remain consistent over one second and three frames. Maximum correspondence residual and transform displacement are 15 cm; gaps over 770 ms reset support. Wrong frame, ambiguous room, limited tracking, stale/out-of-order frames, duplicate/unknown matches, alignment jumps and the 20-second search timeout fail closed. Alignment expires with the source observation; `tick`/`invalidate` remove it on loss.
- `PlaceGeometryMatcher` supplies bounded unique nearest-feature correspondence with ambiguity margins, and the alignment adapter converts fresh confidence-backed A3 geometry into current world positions. Coordinate identity and archive revision are checked before association. Correspondences and room-ambiguity evidence must come from current observation matching. This increment does not infer room identity from tracking-normal or loaded AR anchors. B7 evidence wiring and physical false-alignment calibration remain acceptance dependencies; analytic fixture IDs are not physical room-recognition evidence.
- `PlaceChangeDetector` transforms saved cells into the current named frame and compares only supported observations from the current frame, at the same voxel resolution. Unknown/missing/occluded cells do not imply removal. Three consecutive fresh accepted observations confirm a new-object/layout-change candidate; moved landmark correspondence additionally requires at least 15 cm displacement. Truncation/alignment loss resets confirmation. Candidates never suppress live obstacles or automatically rewrite storage. Quantization and alignment uncertainty require physical calibration.
- `SavedLandmarkProvider` supplies only user-confirmed labels with source `rememberedLandmark`, place/revision/transform IDs and inherited expiry. `GoalResolver.beginSavedLandmark` requires explicit Research opt-in; its update takes the selected current archive and valid alignment. Revision/deletion invalidates the goal. Repeat/next/cancel/complete operate on remembered evidence separately from camera candidates. B7 must pass nil/invalidate immediately on deletion/loss and refresh current evidence before presentation.

## Verification

`swift test`: **77 passing tests**, including ten memory tests and two handrail tests. Memory fixtures cover corruption, schema rejection, symlinks, byte/count caps, reviewed updates/rollback/deletion, similar-room ambiguity, geometric mismatch, collinear/duplicate correspondences, coordinate mismatch, alignment jump/loss/expiry/gap/timeout, moved objects, unknown versus observed-free evidence, ordinary-live refusal, revision invalidation and cycling three remembered labels.

Four Python model-tool tests pass. Simulator build/native verification commands and outcomes are recorded in the final verification section below. These are software fixtures, not physical sensing or held-out target evaluation. Source hashes are in `Evaluation/A7-fixtures.json`.

## Acceptance still open

Execute [protected memory protocol](Sensing/A7-protocol.md) on a supported physical iPhone; calibrate thresholds and quantify false alignment in similar rooms. Wire the supplied current geometry adapter and room-ambiguity evidence, capture-generation changes, invalidation and B7 review/rollback presentation; obtain Aarav consumer review and joint M6 acceptance. No training corpus/target weights, phone/watch evidence, human acceptance, hosted CI run or actual hours is claimed. A7 retains its original provisional 5 points; no ownership transfer or re-estimate is implied.


## Final simulator verification

```sh
swift test
python3 -m unittest discover -s Research/Models -p 'test_*.py'
xcodebuild -project LumaPath.xcodeproj -scheme LumaPath \
  -destination 'platform=iOS Simulator,id=805CB9F9-E484-4D6A-938F-2418C3131D21' \
  -derivedDataPath /tmp/lumapath-a7-clean-derived \
  -resultBundlePath /tmp/lumapath-a7-final-check.xcresult \
  -only-testing:LumaPathNativeTests CODE_SIGNING_ALLOWED=NO test
```

Final result: **77 package tests, four Python tests and eight native tests pass**; the native test command builds the iOS app and test bundles. The three new native tests cover corrupt/oversized/wrong-class secure-map decode, stopped/invalid map capture/restore, archive permissions and deletion. The simulator omits protection metadata despite accepting complete-protection requests, so simulator assertions accept absent metadata while physical-device assertions require `.complete`. Locked-device enforcement remains unverified. No successful physical ARWorldMap roundtrip is claimed. Existing UI journeys were not rerun because this increment changes no product interface.

An earlier incremental Xcode run failed to find a newly added Domain symbol; a clean derived-data run and the final incremental run pass. Xcode still reports its existing package dependency-scan warnings (including Memory→Domain despite the explicit manifest dependency) and expected App Intents metadata notices; these were not suppressed. Local logs/result bundles under `/tmp` are temporary. Hosted CI was not run.
