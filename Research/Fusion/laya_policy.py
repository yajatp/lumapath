"""Offline Laya policy comparison. No app import, raw images, live activation or learned safety score."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import re
import statistics
import time
import urllib.parse
import urllib.request
from pathlib import Path

UPSTREAM = "https://github.com/NandhaKishorM/laya/tree/b9fe351ce81e2d974bca2bf219c1e4030c0a05ea"
POLICIES = ("depthAndVision", "visionOnly", "abstain")
CRITERIA = {
    "depthAndVision": "Use confidence-backed current depth plus current object labels only when coverage, association and tracking are supported.",
    "visionOnly": "Use current object labels without metric distance when RGB is usable but depth or tracking is unsupported.",
    "abstain": "Do not offer an object description when the frame is stale, image is unusable, resources are constrained or evidence is insufficient.",
}
BOOLEAN_FEATURES = {"depthPresent", "confidenceKnown", "trackingNormal", "resourcesOK"}
UNIT_FEATURES = {"coverage", "contrast", "semanticScore", "associationSupport"}
FEATURES = BOOLEAN_FEATURES | UNIT_FEATURES | {"ageMs"}
WEIGHTS = {"depthAndVision": {"depth": 0.8, "vision": 0.2}, "visionOnly": {"depth": 0.0, "vision": 1.0}, "abstain": {"depth": 0.0, "vision": 0.0}}
THRESHOLD = 0.7  # Research hypothesis; not a calibrated sensor reliability threshold.


def number(value, low, high):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError("nonfinite or out-of-range number")
    return value


def validate(rows, synthetic=False):
    if not isinstance(rows, list) or not 1 <= len(rows) <= 1000:
        raise ValueError("expected 1–1000 rows")
    seen, groups = set(), {}
    keys = {"id", "split", "environmentID", "sessionID", "sourceID", "synthetic", "consent", "consentRecord", "license", "features", "expectedPolicy"}
    for row in rows:
        if not isinstance(row, dict) or set(row) != keys:
            raise ValueError("unknown or missing row fields")
        for key in ("id", "environmentID", "sessionID", "sourceID"):
            if not isinstance(row[key], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", row[key]):
                raise ValueError("anonymous bounded IDs required")
        if row["id"] in seen or row["split"] not in ("train", "validation", "test") or row["expectedPolicy"] not in POLICIES:
            raise ValueError("duplicate ID, split or policy")
        seen.add(row["id"])
        if type(row["synthetic"]) is not bool or row["synthetic"] != synthetic or type(row["consent"]) is not bool:
            raise ValueError("synthetic provenance mismatch")
        if not synthetic and (row["consent"] is not True or not row["consentRecord"] or not row["license"]):
            raise ValueError("consent and license required")
        for key in ("consentRecord", "license"):
            if not isinstance(row[key], str) or len(row[key]) > 160:
                raise ValueError("invalid provenance reference")
        for key in ("environmentID", "sessionID", "sourceID"):
            group = (key, row[key])
            if group in groups and groups[group] != row["split"]:
                raise ValueError("split leakage")
            groups[group] = row["split"]
        features = row["features"]
        if not isinstance(features, dict) or set(features) != FEATURES:
            raise ValueError("feature schema mismatch")
        if any(type(features[key]) is not bool for key in BOOLEAN_FEATURES):
            raise ValueError("boolean feature required")
        for key in UNIT_FEATURES:
            number(features[key], 0, 1)
        number(features["ageMs"], 0, 60_000)
    if not any(row["split"] == "test" for row in rows):
        raise ValueError("held-out test rows required")


def allowed(features):
    policies = {"abstain"}
    if features["ageMs"] >= 300 or not features["resourcesOK"] or features["contrast"] < 0.2 or features["semanticScore"] < 0.6:
        return policies
    policies.add("visionOnly")
    if (features["depthPresent"] and features["confidenceKnown"] and features["trackingNormal"]
            and features["coverage"] >= 0.5 and features["associationSupport"] >= 0.5):
        policies.add("depthAndVision")
    return policies


def baseline(features):
    eligible = allowed(features)
    return next(policy for policy in POLICIES if policy in eligible)


def request(features, reverse=False):
    criteria = dict(reversed(list(CRITERIA.items()))) if reverse else dict(CRITERIA)
    return {"model": "english", "lang": "en", "max_len": 512, "min_confidence": THRESHOLD,
            "state": {"task": "Optional Research object-description policy; never walking guidance or hazard suppression.", "sensors": features},
            "questions": {"sensorPolicy": {"type": "choice", "instructions": "Choose a bounded optional description policy from these sensor diagnostics. Missing depth cannot supply distance. Abstain if uncertain.", "criteria": criteria}}}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class LocalLaya:
    def __init__(self, url, timeout=5):
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "::1") or parsed.username or parsed.password
                or parsed.path != "/v1/systemone" or parsed.query or parsed.fragment or not parsed.port):
            raise ValueError("use a literal loopback Laya URL ending /v1/systemone, with explicit port")
        self.url, self.timeout = url, number(timeout, 0.1, 30)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def __call__(self, payload):
        body = json.dumps(payload, allow_nan=False).encode()
        req = urllib.request.Request(self.url, body, {"Content-Type": "application/json"}, method="POST")
        with self.opener.open(req, timeout=self.timeout) as response:
            data = response.read(65_537)
        if len(data) > 65_536:
            raise ValueError("Laya response budget exceeded")
        return json.loads(data)


def parse_answer(response):
    if not isinstance(response, dict) or not isinstance(response.get("answers"), dict) or set(response["answers"]) != {"sensorPolicy"}:
        raise ValueError("answer schema")
    usage = response.get("usage")
    if not isinstance(usage, dict) or usage.get("truncated") is not False or usage.get("truncated_questions") != []:
        raise ValueError("truncated or unknown token coverage")
    answer = response["answers"]["sensorPolicy"]
    if not isinstance(answer, dict) or answer.get("type") != "choice" or answer.get("choice") not in POLICIES:
        raise ValueError("unsupported policy answer")
    probabilities = answer.get("probabilities")
    if not isinstance(probabilities, dict) or set(probabilities) != set(POLICIES):
        raise ValueError("probability schema")
    for value in probabilities.values():
        number(value, 0, 1)
    if abs(sum(probabilities.values()) - 1) > 0.001 or probabilities[answer["choice"]] < max(probabilities.values()) - 0.0001:
        raise ValueError("inconsistent probability distribution")
    if (answer.get("abstention") != "passed" or answer.get("low_confidence") is not False
            or number(answer.get("abstention_threshold"), 0, 1) != THRESHOLD
            or probabilities[answer["choice"]] < THRESHOLD):
        return "abstain", "lowConfidenceOrUnevaluated"
    return answer["choice"], "modelChoice"


def evaluate(rows, synthetic=False, transport=None):
    validate(rows, synthetic)
    results, timings = [], []
    for row in rows:
        if row["split"] != "test":
            continue
        result = {"id": row["id"], "expected": row["expectedPolicy"], "baseline": baseline(row["features"])}
        if transport is not None:
            started = time.perf_counter()
            try:
                first, reason = parse_answer(transport(request(row["features"])))
                second, _ = parse_answer(transport(request(row["features"], reverse=True)))
                result.update(proposed=first, orderFlip=first != second, blocked=first not in allowed(row["features"]))
                final = first if not result["orderFlip"] and not result["blocked"] else "abstain"
                result.update(laya=final, reason="orderSensitive" if result["orderFlip"] else "hardGate" if result["blocked"] else reason,
                              illustrativeWeights=WEIGHTS[final])
            except (ValueError, TypeError, KeyError, OSError) as error:
                result.update(laya="abstain", reason="unavailableOrMalformed", errorType=type(error).__name__,
                              orderFlip=False, blocked=False, illustrativeWeights=WEIGHTS["abstain"])
            timings.append((time.perf_counter() - started) * 1000)
        results.append(result)
    count = len(results)
    report = {"schemaVersion": 1, "synthetic": synthetic, "count": count, "liveActivation": False,
              "decision": "pendingRealDataAndCalibration" if synthetic else "pendingIndependentReview",
              "upstream": UPSTREAM, "baselineAccuracy": sum(r["baseline"] == r["expected"] for r in results) / count,
              "layaExecuted": transport is not None, "results": results}
    if transport is not None:
        report.update(layaAccuracy=sum(r["laya"] == r["expected"] for r in results) / count,
                      abstentions=sum(r["laya"] == "abstain" for r in results), orderFlips=sum(r["orderFlip"] for r in results),
                      hardGateBlocks=sum(r["blocked"] for r in results),
                      unavailable=sum(r["reason"] == "unavailableOrMalformed" for r in results),
                      twoRequestLatencyMs={"median": statistics.median(timings), "p95": sorted(timings)[math.ceil(count * 0.95)-1]})
    return report


def fixture():
    good = dict(depthPresent=True, confidenceKnown=True, trackingNormal=True, resourcesOK=True, coverage=0.9,
                contrast=0.8, semanticScore=0.9, associationSupport=0.9, ageMs=30)
    cases = [("supported", {}, "depthAndVision"), ("no-depth", {"depthPresent": False}, "visionOnly"),
             ("dark", {"contrast": 0.1}, "abstain"), ("expired", {"ageMs": 300}, "abstain"),
             ("confidence-unknown", {"confidenceKnown": False}, "visionOnly"),
             ("resource-limit", {"resourcesOK": False}, "abstain"),
             ("ambiguous-depth", {"associationSupport": 0.1}, "visionOnly"),
             ("tracking-limited", {"trackingNormal": False}, "visionOnly")]
    return [dict(id=f"{split}-{name}", split=split, environmentID=f"room-{split}", sessionID=f"session-{split}", sourceID=f"source-{split}-{name}",
                 synthetic=True, consent=False, consentRecord="synthetic-no-participants", license="synthetic-project-fixture",
                 features=good | change, expectedPolicy=expected)
            for split in ("train", "validation", "test") for name, change, expected in cases]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--laya-url", help="Explicit opt-in to local Laya, e.g. http://127.0.0.1:8000/v1/systemone")
    args = parser.parse_args()
    if args.manifest.stat().st_size > 4 * 1024 * 1024:
        parser.error("manifest exceeds 4 MiB")
    data = args.manifest.read_bytes()
    rows = [json.loads(line) for line in data.decode("utf-8").splitlines() if line.strip()]
    report = evaluate(rows, args.synthetic, LocalLaya(args.laya_url) if args.laya_url else None)
    report["manifestSHA256"] = hashlib.sha256(data).hexdigest()
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "results"}, indent=2))


if __name__ == "__main__":
    main()
