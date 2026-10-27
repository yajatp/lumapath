# C2 feature-boundary increment — October 22, 2026

Software increment, checkpoint still in progress. The shared evaluator now accepts actual validated, current frame evidence and a capture context. Stale/replaced frames, absent pose/depth, missing model authorization and closed evidence gates stay unavailable. Capture descriptors carry the context generation as capability revision. Live Research geometry uses this evaluator before processing; explicit Research authorization never enables ordinary guidance.

Camera-only GoalResolver candidates preserve camera/model/frame provenance and display-relative left/center/right/outside-view positioning after the producer transform. Even a caller-supplied metric association is discarded when the originating frame has no depth/calibration. A handrail structural claim cannot be supplied from image-only evidence. Candidate expiry and model evidence gates are unchanged. Camera-only selection persists locally across Live view instances/relaunches. Limitation copy names the product screens still awaiting integration instead of promising nonexistent manual workflows.

Validation: `swift test` (133 tests) and unsigned generic simulator build. New fixtures inject a fabricated association, missing model/pose/depth, stale frame and replaced generation; ordinary OCR activation remains unavailable. Research OCR remains Research-only. This is partial T58/T59/T64 software evidence, not product or physical acceptance.

Open: complete B5–B11 output/accessory, Find, saved notes/Places, manual route/report workflows and their missing-input UI journeys; real non-LiDAR OCR, VoiceOver and human review. T58–T60 and C2 are not passed. Manual domain eligibility means no sensor prerequisite, not a claim that its screen exists.

B7 manual-fallback continuation (October 22): names/notes CRUD is now implemented independently of camera/depth/location/models. See ../B7-validation.md for 47 isolated Linux tests and the explicit native/UI/physical gaps. Spatial B7 workflows, manual routes/reports and the rest of B5–B11 remain open; T60 is partial software only.
