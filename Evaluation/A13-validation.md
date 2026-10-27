# A13 comparative-validation tooling — October 21, 2026

Delivered protected category protocol, source/config hash freeze, paired-trial ingestion and explicit denominators/exclusions/unavailability, recall/false-alert/error/latency/interval/memory/route summaries and nonactivating gate report. Exact commands/schema: Studies/protocol.md. Frozen source reference is the A12 commit; no sensing code changed in A13.

Executed `python3 -m unittest discover -s Research/Validation -v`: **3 tests pass** covering unavailable-positive misses, missing metrics, exclusions, unpaired/duplicate/mixed/config-mismatched trials and nonfinite data. Executed `swift test`: **88 tests pass**, synthetic producer regression evidence only. Executed empty physical-manifest analysis: **0 physical trials**, origin unavailable, no physical rates inferred; see Studies/physical-results.json.

Required physical geometry/quality/prediction/memory/surveyed-route studies and actual paired baseline runs remain unavailable. No physical performance, thermal or sensing effectiveness claim is made. G1/G3/G4/G5/G6 and A13/M12 acceptance remain pending. B13 participant/rendering/watch studies and human review are outside this implementation and remain pending.
