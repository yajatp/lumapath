# Laya adaptive sensing experiment

This uses the **ConvAI Innovations Laya** Jev-compatible decision engine, not a liquid neural network. The adapter is an offline comparison tool with no import into the iPhone app or local hazard pipeline. It proposes a bounded optional description policy, not learned metric fusion or sensor truth.

API source inspected at [upstream revision b9fe351](https://github.com/NandhaKishorM/laya/tree/b9fe351ce81e2d974bca2bf219c1e4030c0a05ea), Apache-2.0. See its [HTTP contract](https://github.com/NandhaKishorM/laya/blob/b9fe351ce81e2d974bca2bf219c1e4030c0a05ea/docs/http-api.md). Do not substitute a commercial hosted service or send camera images to it.

## What is implemented

`laya_policy.py` compares a deterministic quality-gated baseline with an optional local Laya `/v1/systemone` choice. Only structured numeric/boolean diagnostics are sent. Choices are depthAndVision, visionOnly (no metric distance), or abstain. The 80/20 and 0/100 maps in the report are **illustrative fixed policy weights**, not fitted or calibrated sensor weights. Raw IMU is absent; pose/tracking is a gate. No model choice can make stale, missing, ambiguous or unsupported depth usable. Mandatory hazard feedback is outside this tool and cannot be suppressed.

Requests name the English checkpoint, cap token budget and request abstention reporting. Responses must have the exact bounded choice/probability keys, an untruncated state and an evaluated confidence gate; malformed/unavailable/low-confidence results abstain. Each state is queried twice with reversed choice order; disagreement abstains and is counted. Laya entropy confidence, Jev confidence and chosen-class mass are different quantities. This experiment gates on the probability mass and explicit Laya abstention report, not a copied Jev entropy threshold. All thresholds remain research hypotheses.

The HTTP client permits only an explicitly supplied literal loopback address, disables system proxies and redirects, caps response size and has a timeout. It makes no network calls by default. It does not install, download, start or call model weights automatically.

## Run

Baseline and tests (Python standard library only):

```powershell
python -m unittest discover -s Research/Fusion -v
python Research/Fusion/laya_policy.py Evaluation/Laya/synthetic-policy-manifest.jsonl baseline.json --synthetic
```

For a real Laya experiment, use a separate Python environment on Windows or Mac. Following the pinned upstream installation instructions, install `laya[serve]` from revision b9fe351ce81e2d974bca2bf219c1e4030c0a05ea. Starting it downloads model weights if not cached. Keep it local:

```powershell
$env:LAYA_HOST = '127.0.0.1'
$env:LAYA_MODELS = 'english'
$env:LAYA_DEFAULT_MODEL = 'english'
$env:LAYA_DEVICE = 'cpu'
laya-serve
```

In another terminal at the LumaPath repository:

```powershell
python Research/Fusion/laya_policy.py Evaluation/Laya/synthetic-policy-manifest.jsonl laya-synthetic.json --synthetic --laya-url http://127.0.0.1:8000/v1/systemone
```

Save the installed dependency lock, upstream code revision, model checkpoint revisions and actual computing device from Laya's local `/health` output alongside a real evaluation. Pinning API code alone does not pin dependencies or downloaded weights. Latency in the report covers **both** requests and transport. Synthetic results cannot establish model effectiveness or iPhone performance.

## Real data and acceptance

Use a separate JSONL manifest with the same explicit schema, synthetic=false, consent=true, private consent references and permitted license. Collect independent expected-policy annotations; do not automatically label every row with the baseline. Split by room/session/source before fitting and reject cross-split identities. The initial RGB-D recorder provides source/calibration/pose/quality data; semantic confidence, depth association and resource features require independently reviewed derivation and matching instrumentation. Its export is **not automatically a fully annotated policy manifest**.

Evaluate wrong depth promotion, false object associations, forced abstentions, missing responses, choice-order flips, latency and calibration on unseen rooms. Include all failures in the denominator. The existing A12 logistic fusion experiment is a separate baseline, not Laya training. No live activation is permitted by this report; physical data, evaluation and independent review remain pending.

## Executed evidence

Nine combined Fusion/Python tests passed, including six adapter tests and an HTTP loopback fixture. That fixture is a protocol stub, **not execution of Laya weights**. `Evaluation/Laya/synthetic-baseline.json` records eight synthetic held-out policy cases with `layaExecuted=false` and `liveActivation=false`. The perfect baseline score is by construction of the smoke fixture. Real Laya model execution and real-data calibration were not performed in this environment.
