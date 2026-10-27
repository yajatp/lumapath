# A13 protected comparative-study protocol — not physically executed

Owner Yajat; Aarav protocol/results review pending. No participant or unguarded walking trial is authorized by this document. Use a protected stationary rig and reviewed setups; never ask someone to approach a drop. Existing detailed procedures: Evaluation/Sensing/A5-protocol.md, Evaluation/Sensing/A7-protocol.md and Evaluation/A8-validation.md. Required hardware, consented observations, surveyed routes and independent ground truth are unavailable.

## Freeze and collection

Freeze before capture with `python3 Research/Validation/analyze.py freeze /tmp/study-configuration.json`. Record source commit and file hashes, exact phone/depth capability/OS, capture geometry and quality configuration, rig calibration/height/mount, profile/clearance, units/orientation, source-frame IDs, measured illuminance/material/range and surveyed reference. Add the reviewed protocol identifier and dated consent references to private collection records. Preserve evidence hashes. Do not change thresholds after inspecting held-out outcomes; a change needs a new freeze and untouched test set.

Run both genuinely implemented methods against the same recorded input and independent ground truth. `deterministicBaseline` means the predeclared deterministic producer; `currentProducer` means the frozen candidate. If these are identical, record that fact; no improvement claim is available. A separate code/config identity per method belongs in the frozen study configuration. Never invent a baseline or infer independent raw camera/LiDAR measurements from processed ARKit depth. Keep train/calibration environments and sessions out of study trials. Trials must be marked heldOut only after the collector verifies this separation.

| Category / gate | Positive cases | Negative / mismatch cases | Required measures |
| --- | --- | --- | --- |
| Geometry / G1 | Measured ordinary objects at declared ranges | At least 60 minutes of negative scenes, glass, dark/thin/reflective surfaces | Recall target .95, false alerts ≤.2/min, p95 distance error ≤.25 m; all misses/unavailable |
| Quality / G1 | Controlled light, contrast, tracking/coverage loss | Bright but textureless and partial-region missing coverage | Regional unavailable counts, quality transition latency, geometry invariance |
| Overhead / G3 | Measured crossbars with calibrated floor support | Unsupported floor, upper-view object without measured height | Per-category recalls/errors at least as strict as G1 where applicable; retain generic geometry |
| Passage / G3 | Measured paired boundaries and interior support | One missing boundary or unknown interior | Width error, unavailable/false passage hypotheses; no traversability claim |
| Steps / G3 | Guarded measured curbs/up/down/stairs | Flat carpet, glass, missing depth/floor endings | Per-category recall/error, false alerts, exclusions; unsupported gaps remain unknown |
| Prediction / G4 | Measured crossing/approach/recede paths | Phone sweep, ego-motion, occlusion/relocalization | Miss/false event, lead-time and latency distributions, interval coverage and association/ID-switch review |
| Memory / G5 | Held-out same-room sessions | Look-alike/different rooms, changed maps/pose | Match/mismatch denominators, residual/error distribution, zero false spatial activations; no current obstacle override |
| Routing / G6 | Surveyed pilot routes with constraints | Expired/disputed/unknown report evidence, inaccessible edges | Zero hard violations, measured route completion/error/latency and provenance; reroute/fallback review |

## Trial accounting and analysis

Each JSONL row: trialID/category/method, configurationSHA256 (SHA256 of sorted-key JSON serialization of the frozen config), origin physical|synthetic, heldOut, sessionID/environmentID/device/os/groundTruthReference, exclusionReason (empty if included), available/expectedPositive/detected booleans, negativeMinutes, falseAlerts integer, latencyMs, errorMeters (number or null), intervalCovered (boolean or null), falseActivation/hardConstraintViolation booleans. Physical rows additionally require consent=true and consentReference. Keep extra raw measurements in a separately reviewed evidence artifact referenced by groundTruthReference; the analyzer summarizes rather than replaces interval/lead-time/room-residual distributions.

One row per actual method for each trial/category; pair denominators and exclusion reasons must agree. Negative exposure cannot be mixed into a positive trial. Include unavailable trials; don't discard a failed capture or timeout. Annotate exclusions before analysis and report counts/reasons. Report conditional and overall availability separately when interpreting results; analyzer recall counts unavailable positives as misses. p95 uses nearest-rank; missing error/interval measurements have explicit denominators and never become zeros.

`python3 Research/Validation/analyze.py analyze /tmp/study-configuration.json path/to/trials.jsonl /tmp/study-results.json`

The shipped physical-trials.jsonl is deliberately empty. The executed analysis produces origin=unavailable, zero pairs, null rates/errors, liveActivation=false and pending gates. Synthetic unittest cases exercise accounting, not field validity. The tool does not auto-promote even when numeric targets pass; expert/protocol review, required raw distributions, minimum scope and pair acceptance must be recorded separately. No physical G1/G3/G4/G5/G6 result exists.
