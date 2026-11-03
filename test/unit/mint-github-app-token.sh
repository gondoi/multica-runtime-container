#!/usr/bin/env bash
# Unit check: mint-github-app-token.sh signs a JWT and exchanges it against a
# local fake GitHub API (no network / no real App).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MINT="$ROOT/bin/mint-github-app-token.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; kill "$SERVER_PID" 2>/dev/null || true' EXIT

chmod +x "$MINT"

openssl genrsa -out "$WORKDIR/app.pem" 2048 >/dev/null 2>&1

PORT_FILE="$WORKDIR/port"
python3 - "$WORKDIR" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

workdir = Path(sys.argv[1])

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path.endswith("/access_tokens"):
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer "):
                self.send_response(401)
                self.end_headers()
                return
            body = json.dumps({
                "token": "ghs_unit_test_token",
                "expires_at": "2099-01-01T00:00:00Z",
            }).encode()
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, *_args):
        return

httpd = HTTPServer(("127.0.0.1", 0), Handler)
port = httpd.server_address[1]
(workdir / "port").write_text(str(port))
httpd.handle_request()
PY
SERVER_PID=$!

# Wait for port file.
for _ in $(seq 1 50); do
  [ -f "$PORT_FILE" ] && break
  sleep 0.05
done
PORT="$(cat "$PORT_FILE")"

export GITHUB_APP_ID=42
export GITHUB_APP_INSTALLATION_ID=99
export GITHUB_APP_PRIVATE_KEY_FILE="$WORKDIR/app.pem"
export GITHUB_API_URL="http://127.0.0.1:${PORT}"

token="$("$MINT")"
if [ "$token" != "ghs_unit_test_token" ]; then
  echo "FAIL: expected ghs_unit_test_token, got: $token" >&2
  exit 1
fi
echo "PASS  mint-github-app-token against local fake API"
wait "$SERVER_PID" 2>/dev/null || true
