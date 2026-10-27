# A12 learned-fusion local tooling — October 21, 2026

Implemented and executed dataset validation, grouped splits, fixed feature extraction/baseline, logistic training, validation-only temperature calibration, held-out metrics/reliability plot/model/data cards and explicit activation decision. Synthetic output has **pendingRealData**, never promoted. Run commands and dependencies: Research/Fusion/README.md. Dataset/model cards and raw aggregate counts: Evaluation/Fusion/.

Executed 3 unittest cases: feature/consent/group leakage validation, bit-identical repeated model training, and held-out-label mutation proving test labels cannot tune coefficients or temperature. Executed 288-row synthetic training/evaluation and rendered/visually inspected calibration.png with matplotlib 3.10.8. Core tools use Python 3.14.7 standard library; plot dependencies have a resolved lock.

Consented real observations and independent labels are unavailable. This is local experiment tooling plus a synthetic smoke run, not the complete R19 research result. Actual learned-fusion experiment, human review and A12/M11 acceptance remain pending. No geometry/runtime authority changed.
