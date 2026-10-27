# B7 spatial scan library — October 22, 2026

The current increment extends the separately persisted manual-note fallback with a Research spatial-map library. Baseline: `8c67685`. B7/M6 and physical G5 remain open. Manual-note history and its original environment are retained below.

## Spatial scan behavior

Home or Find → Saved places → Spatial scans — Research lists protected A7 archives separately from manual notes. On supported physical AR hardware, an explicit Start requests camera access through the existing CaptureCoordinator. One ARKit driver owns the scan. It must report normal tracking and mapped world-map quality before a draft is captured. The draft contains a secure-coded actual ARWorldMap and up to 512 current raw feature positions; at least three distributed features are required. No landmark label or user confirmation is inferred from those points. Empty/collinear/tightly clustered/nonfinite feature sets and empty/oversized map payloads and invalid names are rejected.

The camera stops before review. Save is explicit; discard, Cancel, leaving the scan screen and app inactivity stop capture and clear temporary drafts. Late permission/map results cannot revive a cancelled scan. No automatic restart, network upload, guidance, speech, haptic output, or current-room claim is introduced. On the simulator or hardware without AR world tracking the UI explains the limit and keeps manual notes available.

Saved scans support rename, reviewed replacement with a new coordinate frame, one-revision rollback, and confirmed deletion. Name-only changes preserve the map/coordinate identities; replacement never mixes old landmarks with a new map. Every mutation checks the displayed revision, including the new revision-bound deletion API. A stale editor cannot delete a more recent map. Map/current/rollback derivatives share A7's single protected file, size/count budgets, checksum validation, atomic writes, private permissions and backup exclusion. Corrupt/future/unreadable records are preserved and block library writes until recovery. These are implemented storage policies, not physical locked-device or forensic-erasure evidence.

## Current validation

All **172 Swift package tests**, **22 native simulator tests**, the new **largest-text spatial-library journey** and both existing **manual-note UI journeys** passed. Three new package tests cover scan distribution/bounds and unlabeled provenance, rename/rescan coordinate identity, one-step rollback, stale review and deletion derivatives. Two new native tests exercise the actual library model with protected storage, revision conflicts, rollback/deletion and corruption preservation. The focused run passed 3 tests; the regression run passed 24 (22 native plus 2 UI). No complete UI suite rerun is claimed.

All **77 Python tests** passed (models 4, fusion 3, comparative accounting 3, release audit 7, service 60). The source release audit passed while retaining pending release acceptance. XcodeGen 2.46.0 regenerated the committed project; `git diff --check` passed. The native scheme test built the iOS app and embedded watch companion using Xcode 26.2 and iPhone 17 Pro / iOS 26.3.1 Simulator. Hosted CI for this increment remains pending at commit.

The first native compilation exposed a caught-error/property shadowing issue; `self.error` references corrected it. The first large-text UI run failed to find an offscreen lazy list link. Spatial navigation now lives in the Saved places toolbar, and the focused rerun passed. [Machine-readable checks](B7-checks.json) preserve source hashes, test summaries, initial failures and boundaries. Temporary local logs/results are under `/tmp/lumapath-b7-*`.

The AR map path requires physical hardware and has not been executed here. The paired iPhone is listed as unavailable. No physical protection/accessibility acceptance or current spatial alignment is claimed.

## Remaining B7 work

Current-correspondence/room-ambiguity presentation, alignment loss/timeout, remembered-goal selection, user-confirmed landmark labels and change review still require integration. Scan saving does not open any ordinary sensing or remembered-guidance gate. Run protected correct-room/similar-room/moved-object/occlusion/cancellation and physical file-protection/accessibility trials, then obtain G5/M6 pair review. B8–B14, model/data and release dependencies remain separate open work.

---

# B7 manual place notes / C2 fallback increment — October 22, 2026

Subsequent macOS/native revalidation is recorded in the [delivered-work audit](../docs/VALIDATION.md). The Linux-only results below describe this increment's original environment.

Baseline: `b18fa47`. This increment implements the camera-independent names/notes portion of B7/C2/T60. B7, M6, T60 and physical G5/G9 acceptance remain open. Ownership remains Aarav for B7 and Yajat for A7; no pair review or ownership transfer is inferred.

## Delivered behavior

Home or Find → Saved places → Add place note. A user can enter a name and optional notes, explicitly save, reopen/rename/edit, cancel an unsaved draft, and confirm deletion. The list and editor label entries as manual references without a spatial map. No camera/location/microphone permission, model, network service or accessory is needed. Entering the library ends an open shell demo; this screen starts no sensing or output.

A single app-owned actor persists a separate schema-1 `manual-places.json` in Application Support/LumaPathManualPlaces. It contains only UUID, revision, name, text and creation/update dates. No AR archive, coordinates, imagery, inferred landmark or goal evidence is produced or consumed. Files are written atomically with private directory/file permissions; iOS requests complete file protection and excludes the library folder from backup. These iOS attributes are implemented but have not been verified on physical hardware here.

Limits: 100 records, 80 characters per name, 2,000 per note and a 1 MiB archive. Edits/deletions check the displayed revision; stale editors cannot overwrite a newer note or resurrect a deleted one. Counters/timestamps are not spatial evidence. Corrupt, oversized, duplicate-ID and unsupported-version archives fail closed and are preserved; the UI offers retry and blocks creation until a successful load. Drafts remain visible on failed save; no automatic reset or success dismissal occurs. A deletion removes that record from the active archive, with no app-created thumbnail/rollback/cache derivative. This is not a forensic secure-erasure claim.

## Checks executed in this environment

- Swift 6.2.3/Linux isolated Domain/Sensors package: **47 tests passed**, including six new manual-place tests. The harness symlinks production source and test directories, excludes Apple-only unrelated model/memory targets, and changes no production package configuration.
- New cases cover persisted create/edit/reopen/delete, stale revision/delete protection, concurrent edits, rejected drafts, corrupt/future/oversized archives, duplicate IDs, record/library bounds, storage failure and absence of sensor fields.
- Seven release-audit regression tests and the source release audit passed.
- Swift frontend parse checks for the changed app files and UI journey file passed; `git diff --check` passed. Parsing does not establish iOS typechecking.

Two UI journeys were added to the existing ProfileJourneyTests source for normal save/cancel/relaunch/confirmed-delete behavior and largest Dynamic Type controls. **They have not run here.** XcodeGen source membership does not change: the new domain/test files are discovered by SwiftPM, and app/UI edits use existing generated-project sources. The full repository requires Apple Vision/CryptoKit/Xcode and cannot be validated end to end on this Linux host. GitHub run inspection returned Forbidden from the restricted API endpoint, so no hosted outcome is claimed.

## Still pending

Native compilation and simulator UI journeys, manual VoiceOver/Switch Control/rotation/small-screen checks, locked-device protection verification, and pair review remain pending. Full B7 still requires scan/save/rescan, A7 current-correspondence/room-ambiguity wiring, alignment-loss/deletion output invalidation, remembered-goal selection, reviewed map updates/rollback and protected mismatch/usability trials. T60 routes/manual reporting and other C2 fallback workflows remain unfinished. No spatial gate or ordinary guidance feature was enabled by this increment.
