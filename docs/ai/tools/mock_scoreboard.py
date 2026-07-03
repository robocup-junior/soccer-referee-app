#!/usr/bin/env python3
"""Stdlib mock of the rcj-scoreboard referee API for on-device PR #15 testing.

Endpoints (exact path match, trailing slash required):
  GET  /api/v1/soccer/match/         -> match config (needs Bearer auth)
  POST /api/v1/soccer/match/result/  -> record result (single-use token)

Env-var error injection:
  PORT          listen port (default 8000)
  RESULT_STATUS force POST status (e.g. 409, 401, 422, 500)
  MATCH_STATUS  force GET status (e.g. 401, 500)
  HANG          seconds to sleep before responding (test 15s timeout)
  TOKEN         expected bearer token (default: accept any non-empty)

Run:  python3 -u mock_scoreboard.py
"""
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8000"))
RESULT_STATUS = int(os.environ.get("RESULT_STATUS", "200"))
MATCH_STATUS = int(os.environ.get("MATCH_STATUS", "200"))
HANG = float(os.environ.get("HANG", "0"))
EXPECTED_TOKEN = os.environ.get("TOKEN", "")

# In-memory match. version bumps on successful result record.
MATCH = {
    "match_code": "RR-vs-BB-01",
    "home_team": {"name": "Red Robots"},
    "away_team": {"name": "Blue Bots"},
    "home_is_left": True,
    "venue": "Field 1",
    "scheduled_start": "2026-07-01T13:30:00Z",
    "duration_seconds": 30,
    "timezone": "UTC",
    "version": 1,
    "status": "SCHEDULED",
    # Per-robot comm-module MACs (rcj-scoreboard #70 / app #85 read path). Ordered
    # by robot number; the app auto-pairs these onto each side's module slots, so
    # the result POST's actual_modules can be diffed against them after a swap.
    "home_module_macs": ["AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02"],
    "away_module_macs": ["AA:BB:CC:DD:EE:03", "AA:BB:CC:DD:EE:04"],
    # Per-robot inspection (rcj-scoreboard #116 / app #78). Mix of every badge
    # case: ok, failed+note, missing, ok+note. Team-level keys kept for compat.
    "home_inspection_status": "ok",
    "away_inspection_status": "failed",
    "home_inspection_robots": [
        {"robot": 1, "status": "ok",
         "note": "Front-left dribbler motor connector was reseated during "
                 "inspection because an intermittent dropout was observed under "
                 "load on the test bench. The team resoldered the joint and it "
                 "held for the remainder of the check, but the inspector asked "
                 "the referee to keep an eye on the left wheel behaviour during "
                 "play and to re-check the connector at halftime if the robot "
                 "starts drifting. Otherwise the robot passed all size, weight "
                 "and light-emission tests without further issue."},
        {"robot": 2, "status": "failed",
         "note": "Battery pack measured below the 10.5V minimum under load and "
                 "the kicker capacitor exceeded the allowed maximum voltage on "
                 "two separate measurements. In addition the top light-shield "
                 "was 3mm over the legal height and one exposed wire on the "
                 "underside was not properly insulated. All three issues must "
                 "be corrected and the robot must be brought back for a full "
                 "re-inspection before it is allowed to play its next match."},
    ],
    "away_inspection_robots": [
        {"robot": 1, "status": "missing",
         "note": "Robot was not presented for inspection today. A team member "
                 "told the inspection desk that it is still being repaired in "
                 "the pit area after a collision in the previous round bent the "
                 "chassis, and that they hope to bring it for inspection before "
                 "their next scheduled match. Until it is inspected it may not "
                 "be fielded, so the referee should confirm its status at the "
                 "table before kickoff."},
        {"robot": 2, "status": "ok",
         "note": "Wheels were re-seated and the light shield was trimmed to the "
                 "legal height after it failed on the first attempt. On the "
                 "second attempt the robot passed every check: dimensions, "
                 "weight, battery voltage under load, kicker energy and the "
                 "infrared light-emission limits were all within spec, so it is "
                 "cleared to play with no further conditions attached."},
    ],
}
SEEN_IDEMPOTENCY = {}  # idempotency_key -> stored response (single-use replay)
TOKEN_CONSUMED = {"done": False}


def _auth_ok(handler):
    h = handler.headers.get("Authorization", "")
    if not h.startswith("Bearer "):
        return False
    tok = h[len("Bearer "):].strip()
    if not tok:
        return False
    if EXPECTED_TOKEN and tok != EXPECTED_TOKEN:
        return False
    return True


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("[mock] %s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_GET(self):
        if HANG:
            time.sleep(HANG)
        if self.path != "/api/v1/soccer/match/":
            return self._send(404, {"reason": "not_found", "path": self.path})
        if not _auth_ok(self):
            return self._send(401, {"reason": "invalid_token"})
        if MATCH_STATUS != 200:
            return self._send(MATCH_STATUS, {"reason": "forced_%d" % MATCH_STATUS})
        print("[mock] GET match -> version=%d" % MATCH["version"], flush=True)
        return self._send(200, MATCH)

    def do_POST(self):
        if HANG:
            time.sleep(HANG)
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw or b"{}")
        except Exception:
            payload = {}
        print("[mock] POST %s body=%s" % (self.path, payload), flush=True)
        if self.path != "/api/v1/soccer/match/result/":
            return self._send(404, {"reason": "not_found", "path": self.path})
        if not _auth_ok(self):
            return self._send(401, {"reason": "invalid_token"})

        # Surface the #85 actual-modules report on its own line so device-test
        # evidence is a single grep. Absent on pre-#85 / non-referee submissions.
        actual_modules = payload.get("actual_modules")
        if actual_modules is not None:
            print("[mock] actual_modules=%s" % json.dumps(actual_modules),
                  flush=True)

        idem = payload.get("idempotency_key")
        if idem and idem in SEEN_IDEMPOTENCY:
            print("[mock] idempotent replay for %s" % idem, flush=True)
            return self._send(200, SEEN_IDEMPOTENCY[idem])

        if RESULT_STATUS != 200:
            return self._send(RESULT_STATUS, {"reason": "forced_%d" % RESULT_STATUS})

        if TOKEN_CONSUMED["done"]:
            return self._send(409, {"reason": "already_recorded"})

        MATCH["version"] += 1
        MATCH["status"] = "COMPLETED"
        TOKEN_CONSUMED["done"] = True
        resp = {
            "ok": True,
            "version": MATCH["version"],
            "home_goals": payload.get("home_goals"),
            "away_goals": payload.get("away_goals"),
            "comment": payload.get("comment"),
            "actual_modules": actual_modules,
        }
        if idem:
            SEEN_IDEMPOTENCY[idem] = resp
        print("[mock] RECORDED -> version=%d  %s-%s" % (
            MATCH["version"], resp["home_goals"], resp["away_goals"]), flush=True)
        return self._send(200, resp)


if __name__ == "__main__":
    print("[mock] listening on 0.0.0.0:%d  RESULT_STATUS=%d MATCH_STATUS=%d HANG=%s"
          % (PORT, RESULT_STATUS, MATCH_STATUS, HANG), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
