import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ENV_ID = os.environ.get("ENV_ID", "unknown")
ENV_NAME = os.environ.get("ENV_NAME", "sandbox")
PORT = int(os.environ.get("PORT", "8000"))


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, payload):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            self._json(200, {"status": "ok", "env_id": ENV_ID, "ts": int(time.time())})
            return

        self._json(
            200,
            {
                "message": "Hello from devops-sandbox",
                "env_id": ENV_ID,
                "name": ENV_NAME,
                "health": "/health",
            },
        )

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"demo app listening on :{PORT} for {ENV_ID}", flush=True)
    server.serve_forever()
