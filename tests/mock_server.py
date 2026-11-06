"""Tiny mock of the Runbook API (POST /api/v1/runs, GET /api/v1/runs/{id}) for testing start-run.sh.

Usage: python3 -I mock_server.py <port-file> <request-log-dir>
Binds 127.0.0.1 on a free port and writes the port to <port-file>.
Every request is recorded as <request-log-dir>/<n>.json (method, path, authorization, idempotency key, body).

Idempotency: a POST with an Idempotency-Key that this token already used returns the same run with 200
(like the real API within 24 hours).

The bearer token selects the scenario (response shapes mirror apps/runbook/internal/web/api.go):
  rb_ok      POST 201; GET returns "open" twice, then "completed"
  rb_open    POST 201; GET always "open" (timeout test)
  rb_flaky   POST 201; first GET 503, then "completed"
  rb_bad     401 {"error": "invalid or revoked token"}
  rb_5xx     500 {"error": "internal error"}
  rb_limit   402 {"error": "...", "resource", "limit", "used", ...} (plan limit with quota)
  rb_missing 404 {"error": "template not found"}
  rb_cancel  POST 201; first GET "open", then "cancelled" with a reason
  rb_replay  POST 200 (the run already exists for this Idempotency-Key), status "open"
  rb_flakypost  first POST 503, then normal (retry test)
  rb_down    POST always 503
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, log_dir = sys.argv[1], sys.argv[2]
state = {"n": 0, "polls": {}, "keys": {}, "posts": {}}


def run_json(run_id, status, title):
    out = {
        "id": run_id,
        "url": "https://runbook.example/runs/%d" % run_id,
        "title": title,
        "status": status,
        "template_id": 3,
        "variables": {},
        "created_at": "2026-11-04T10:00:00Z",
        "items_total": 5,
        "items_checked": 5 if status == "completed" else 2,
        "required_open": 0 if status == "completed" else 3,
        "ready_to_complete": False,
        "items": [{"id": 99, "section": "Prepare", "text": "nested id must not be picked", "required": True, "checked": False}],
    }
    if status == "cancelled":
        out["cancelled_at"] = "2026-11-04T10:05:00Z"
        out["cancel_reason"] = "release postponed"
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, obj, headers=None):
        data = json.dumps(obj, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def record(self, body):
        state["n"] += 1
        entry = {
            "method": self.command,
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "content_type": self.headers.get("Content-Type", ""),
            "user_agent": self.headers.get("User-Agent", ""),
            "idempotency_key": self.headers.get("Idempotency-Key"),
            "body": body,
        }
        with open("%s/%03d.json" % (log_dir, state["n"]), "w") as f:
            json.dump(entry, f)

    def token(self):
        auth = self.headers.get("Authorization", "")
        return auth[len("Bearer "):].strip() if auth.startswith("Bearer ") else ""

    def common_errors(self, token):
        if token == "rb_bad" or not token.startswith("rb_"):
            self.send(401, {"error": "invalid or revoked token"}, {"WWW-Authenticate": 'Bearer realm="runbook", error="invalid_token"'})
            return True
        if token == "rb_5xx":
            self.send(500, {"error": "internal error"})
            return True
        return False

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode()
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"_unparsable": raw}
        self.record(body)
        token = self.token()
        if self.common_errors(token):
            return
        if self.path != "/api/v1/runs":
            self.send(404, {"error": "not found"})
            return
        posts = state["posts"][token] = state["posts"].get(token, 0) + 1
        if token == "rb_down" or (token == "rb_flakypost" and posts == 1):
            self.send(503, {"error": "unavailable"})
            return
        if token == "rb_limit":
            self.send(402, {"error": "The Free plan allows 10 API-triggered runs per month. Upgrade to add more.", "plan": "free",
                            "plan_name": "Free", "resource": "api_runs", "limit": 10, "used": 10,
                            "upgrade_url": "https://runbook.example/billing", "resets_at": "2026-12-01T00:00:00Z"})
            return
        if token == "rb_missing":
            self.send(404, {"error": "template not found"})
            return
        run_id = {"rb_ok": 7, "rb_open": 8, "rb_flaky": 9, "rb_cancel": 10, "rb_replay": 11}.get(token, 7)
        title = body.get("title") or "Release v1.2.3"
        key = self.headers.get("Idempotency-Key")
        headers = {"Location": "/api/v1/runs/%d" % run_id}
        if token == "rb_replay" or (key and (token, key) in state["keys"]):
            headers["Idempotent-Replayed"] = "true"
            self.send(200, run_json(run_id, "open", title), headers)
            return
        if key:
            state["keys"][(token, key)] = run_id
        self.send(201, run_json(run_id, "open", title), headers)

    def do_GET(self):
        self.record(None)
        token = self.token()
        if self.common_errors(token):
            return
        prefix = "/api/v1/runs/"
        if not self.path.startswith(prefix) or not self.path[len(prefix):].isdigit():
            self.send(404, {"error": "run not found"})
            return
        run_id = int(self.path[len(prefix):])
        polls = state["polls"][run_id] = state["polls"].get(run_id, 0) + 1
        if token == "rb_flaky" and polls == 1:
            self.send(503, {"error": "unavailable"})
            return
        if token == "rb_cancel":
            status = "cancelled" if polls >= 2 else "open"
        elif token == "rb_open":
            status = "open"
        elif token == "rb_flaky":
            status = "completed"
        else:
            status = "completed" if polls >= 3 else "open"
        self.send(200, run_json(run_id, status, "Release v1.2.3"))


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
