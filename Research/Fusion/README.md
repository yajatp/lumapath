# Bounded fusion research

Task: estimate whether an associated semantic label is supported. This offline model cannot clear geometry, suppress local alerts, waive coverage or produce a safety percentage. There is no runtime import or automatic promotion.

Run `python3 Research/Fusion/experiment.py run path/to/manifest.jsonl /tmp/fusion-result` for consented data. Each JSONL row contains a unique id, split (train/validation/test), environmentID, sessionID, sourceID, synthetic=false, consent=true, consentRecord, license, binary annotated supported label, lighting/surface and normalized features coverage/contrast/semanticScore/associationScore/disagreement. Derive features from quality and association diagnostics and independently label semantic support; retain private consent records outside Git. The extractor selects features in that fixed order with an intercept. It rejects nonfinite/range errors, missing consent and environment/session/source leakage. Split before observing outcomes; use new environments as well as new sessions. Human reviewers must check provenance/duplicate content and label reliability: IDs alone cannot prove those facts.

Training is deterministic batch logistic regression (1,000 epochs, learning rate .2, L2 .001); validation selects temperature by Brier score over a fixed grid. Test labels never influence training or calibration. Baseline uses declared fixed coverage/semantic/association/disagreement thresholds. Outputs: model and script/dataset hashes, held-out probabilities, Brier/confusion/abstention counts, reliability bins, lighting/surface breakdowns, and a reject/pending-review decision. Abstention is reported alongside a .5 diagnostic classifier threshold; it does not remove errors from the denominator. Review false positives as well as false negatives before any future decision.

Executed synthetic check:

```sh
python3 Research/Fusion/experiment.py fixture /tmp/fusion-synthetic.jsonl
python3 Research/Fusion/experiment.py run /tmp/fusion-synthetic.jsonl /tmp/fusion-check --synthetic
python3 -m unittest discover -s Research/Fusion -v
python3 -m venv /tmp/fusion-plot-env
/tmp/fusion-plot-env/bin/pip install -r Research/Fusion/plot-requirements.lock
/tmp/fusion-plot-env/bin/python Research/Fusion/plot.py /tmp/fusion-check
```

`Evaluation/Fusion/synthetic-result` records the executed smoke experiment; do not interpret it as sensor/model effectiveness. The plotting lock was resolved on Python 3.14/macOS; core training/tests use only the standard library. Physical collection, independent annotations, appropriate consent/license review and Aarav review remain open.
