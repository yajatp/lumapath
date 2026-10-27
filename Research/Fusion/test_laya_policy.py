import copy
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import unittest
from laya_policy import LocalLaya, POLICIES, THRESHOLD, allowed, baseline, evaluate, fixture, parse_answer, validate


def answer(policy="depthAndVision", confidence=0.9):
    return {"answers": {"sensorPolicy": {"type": "choice", "choice": policy,
             "probabilities": {p: confidence if p == policy else (1-confidence)/2 for p in POLICIES},
             "abstention": "passed", "abstention_threshold": THRESHOLD, "low_confidence": False}},
            "usage": {"truncated": False, "truncated_questions": []}}


class LayaPolicyTests(unittest.TestCase):
    def test_stale_missing_or_ambiguous_sensors_cannot_be_enabled_by_model(self):
        rows = fixture()
        report = evaluate(rows, True, lambda payload: answer())
        for result in report["results"]:
            features = next(row["features"] for row in rows if row["id"] == result["id"])
            self.assertIn(result["laya"], allowed(features))
        self.assertEqual(report["hardGateBlocks"], 7)
        self.assertFalse(report["liveActivation"])
        self.assertEqual(report["decision"], "pendingRealDataAndCalibration")

    def test_choice_order_instability_and_low_confidence_abstain(self):
        def order_sensitive(payload):
            first = next(iter(payload["questions"]["sensorPolicy"]["criteria"]))
            return answer(first)
        report = evaluate(fixture(), True, order_sensitive)
        self.assertEqual(report["orderFlips"], 8)
        self.assertTrue(all(row["laya"] == "abstain" for row in report["results"]))
        self.assertEqual(parse_answer(answer(confidence=0.5))[0], "abstain")
        response = answer(); response["answers"]["sensorPolicy"]["abstention"] = "unevaluated"
        self.assertEqual(parse_answer(response)[0], "abstain")

    def test_truncated_malformed_nan_and_external_actions_are_rejected(self):
        changes = [lambda r: r["usage"].update(truncated=True),
                   lambda r: r["answers"]["sensorPolicy"].update(choice="walkForward"),
                   lambda r: r["answers"]["sensorPolicy"]["probabilities"].update(abstain=float("nan")),
                   lambda r: r["answers"]["sensorPolicy"]["probabilities"].update(abstain=True)]
        for change in changes:
            response = answer(); change(response)
            with self.assertRaises(ValueError): parse_answer(response)
        report = evaluate(fixture(), True, lambda payload: {})
        self.assertEqual(report["unavailable"], 8)

    def test_consent_provenance_and_group_splits_are_enforced(self):
        validate(fixture(), True)
        with self.assertRaises(ValueError): validate(fixture(), False)
        for key in ("environmentID", "sessionID", "sourceID"):
            rows = fixture(); rows[-1][key] = rows[0][key]
            with self.assertRaises(ValueError): validate(rows, True)
        rows = fixture(); rows[0]["features"]["coverage"] = float("inf")
        with self.assertRaises(ValueError): validate(rows, True)
        rows = fixture(); rows[0]["features"]["resourcesOK"] = 1
        with self.assertRaises(ValueError): validate(rows, True)
        rows = fixture(); rows[0]["features"]["privateImage"] = "forbidden"
        with self.assertRaises(ValueError): validate(rows, True)

    def test_default_is_baseline_only_and_heldout_labels_do_not_change_policy(self):
        rows = fixture(); first = evaluate(rows, True)
        self.assertFalse(first["layaExecuted"])
        self.assertEqual(first["baselineAccuracy"], 1)
        changed = copy.deepcopy(rows)
        for row in changed: row["expectedPolicy"] = "abstain"
        second = evaluate(changed, True)
        self.assertEqual([r["baseline"] for r in first["results"]], [r["baseline"] for r in second["results"]])

    def test_http_contract_is_loopback_bounded_and_posts_only_structured_state(self):
        received = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                data = json.dumps(answer()).encode()
                self.send_response(200); self.end_headers(); self.wfile.write(data)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            client = LocalLaya(f"http://127.0.0.1:{server.server_port}/v1/systemone")
            report = evaluate(fixture(), True, client)
            self.assertEqual(len(received), 16)
            self.assertEqual(report["count"], 8)
            self.assertEqual(set(received[0]["state"]["sensors"]), set(fixture()[0]["features"]))
            self.assertNotIn("expectedPolicy", received[0]["state"])
        finally:
            server.shutdown(); server.server_close(); thread.join()
        for url in ["https://example.com/v1/systemone", "http://localhost:8000/v1/systemone", "http://127.0.0.1:8000/other", "http://user@127.0.0.1:8000/v1/systemone"]:
            with self.assertRaises(ValueError): LocalLaya(url)
