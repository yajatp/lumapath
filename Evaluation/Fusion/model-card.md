# A12 model card

Research-only logistic semantic-association support classifier. Five bounded features, intercept, separate validation temperature. Full weights and exact hashes: synthetic-result/model.json. Deterministic baseline thresholds are fixed in experiment.py. No local runtime consumes this model.

Executed synthetic test: 96 held-out rows. Baseline Brier .243333, 28 false negatives, 0 false positives; calibrated model Brier .051576, 6 false negatives, 2 false positives, 5 probabilities in abstention band [.4,.6]. All errors retain their denominators; see metrics.json for positives/negatives and condition/reliability bins. This deliberately generated task favors an interpretable feature model and cannot establish physical benefit. Reliability bins are small and noisy. No independent uncertainty/generalization claim is justified.

Decision: **pendingRealData**. Live activation false; geometry authority false. Real consented collection, held-out conditions, independent baseline/annotation review and M11 pair acceptance remain incomplete. Better synthetic scores never permit promotion. Real experiments with worse Brier or more false negatives record rejection; improvements still require independent review, including false-positive tradeoffs.
