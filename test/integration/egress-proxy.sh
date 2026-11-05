#!/usr/bin/env bash
# Integration check (OPT-IN, needs Docker + internet): the iron-proxy egress
# example actually controls this container's egress.
#
#   ./test/integration/egress-proxy.sh
#   IMAGE=multica-runtime:local ./test/integration/egress-proxy.sh
#
# Not wired into CI on purpose: it pulls the upstream proxy image and performs
# real outbound HTTPS. The boot seam (test/boot/run-seam.sh) covers the
# container-side half offline (CA validation, fail-closed, env exports).
#
# It proves, end to end:
#   - the runtime boots Ready with MULTICA_EGRESS_PROXY=iron-proxy + its CA
#   - an allowlisted host is reachable through the proxy, with the proxy's
#     MITM certificate validated by the container's CA bundle
#   - TLS to the same host FAILS when the proxy CA is not trusted (i.e. the
#     proxy really is in the path — not a direct connection)
#   - a host outside the allowlist is rejected with 403 and logged by the proxy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${IMAGE:-multica-runtime:local}"
PROXY_IMAGE="${PROXY_IMAGE:-ironsh/iron-proxy:0.56.0}"
STUB="$ROOT/test/boot/stubs/multica"
SECRETS="$ROOT/test/boot/fixtures/secrets"
COMPOSE_EXAMPLE="$ROOT/examples/iron-proxy"
WORK="$(mktemp -d)"
NET="multica-egress-it-$$"
PROXY="multica-egress-proxy-$$"
RUNTIME="multica-egress-runtime-$$"
PROXY_IP="10.231.0.2"
# Allowlisted probe host (also in examples/iron-proxy/proxy.yaml).
ALLOWED_URL="${ALLOWED_URL:-https://api.github.com/zen}"
BLOCKED_URL="${BLOCKED_URL:-https://example.com/}"
CA_BUNDLE_IN_CONTAINER="/home/agent/.multica/egress-ca-bundle.crt"

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

cleanup() {
  docker rm -f "$RUNTIME" "$PROXY" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> CA + network"
mkdir -p "$WORK/certs"
chmod 700 "$WORK/certs"
"$COMPOSE_EXAMPLE/gen-ca.sh" "$WORK/certs" >/dev/null
docker network create --subnet 10.231.0.0/24 "$NET" >/dev/null

echo "==> iron-proxy sidecar ($PROXY_IMAGE)"
docker run -d --name "$PROXY" \
  --network "$NET" --ip "$PROXY_IP" \
  -v "$COMPOSE_EXAMPLE/proxy.yaml:/etc/iron-proxy/proxy.yaml:ro" \
  -v "$WORK/certs:/certs:ro" \
  "$PROXY_IMAGE" -config /etc/iron-proxy/proxy.yaml >/dev/null

# The proxy needs a moment to bind DNS + listeners before the runtime boots and
# immediately performs `multica login` / installs nothing — but its DNS must
# answer by then, so wait for a log line rather than sleeping blindly.
for _ in $(seq 1 20); do
  docker logs "$PROXY" 2>&1 | grep -qi 'listen\|started\|serving' && break
  sleep 0.5
done
if docker inspect -f '{{.State.Running}}' "$PROXY" | grep -q true; then
  ok "proxy started"
else
  bad "proxy exited at startup"
  docker logs "$PROXY" >&2 || true
  exit 1
fi

echo "==> runtime behind the proxy (DNS-routed, proxy CA trusted)"
docker run -d --name "$RUNTIME" \
  --network "$NET" \
  --dns "$PROXY_IP" \
  --env-file "$ROOT/test/boot/fixtures/happy-projected.env" \
  -e MULTICA_EGRESS_PROXY=iron-proxy \
  -e MULTICA_EGRESS_PROXY_CA=/run/certs/iron-proxy/ca.crt \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  -v "$WORK/certs/ca.crt:/run/certs/iron-proxy/ca.crt:ro" \
  "$IMAGE" >/dev/null

ready=0
for _ in $(seq 1 30); do
  if docker exec "$RUNTIME" /usr/local/bin/ready.sh >/dev/null 2>&1; then
    ready=1
    break
  fi
  docker inspect -f '{{.State.Running}}' "$RUNTIME" 2>/dev/null | grep -q true || break
  sleep 1
done
if [ "$ready" = 1 ]; then
  ok "runtime Ready behind the egress proxy"
else
  bad "runtime did not become Ready"
  docker logs "$RUNTIME" >&2 || true
  exit 1
fi

if docker logs "$RUNTIME" 2>&1 | grep -q 'egress proxy: iron-proxy'; then
  ok "boot reports iron-proxy mode"
else
  bad "boot did not report the egress proxy mode"
  docker logs "$RUNTIME" >&2 || true
fi

http_code() {
  # http_code <url> [extra curl args...]
  local url="$1"
  shift
  docker exec "$RUNTIME" curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 15 "$@" "$url" 2>/dev/null || true
}

echo "==> allowlisted egress"
code="$(http_code "$ALLOWED_URL" --cacert "$CA_BUNDLE_IN_CONTAINER")"
if [ "$code" = "200" ]; then
  ok "allowlisted host reachable through the proxy (HTTP $code $ALLOWED_URL)"
else
  bad "allowlisted host failed (HTTP '${code:-none}' $ALLOWED_URL)"
  docker logs "$PROXY" 2>&1 | tail -20 >&2 || true
fi

# If the proxy were not in the path, this direct-style request would succeed.
# It must fail: the proxy MITMs every TLS connection and only its CA is trusted.
if docker exec "$RUNTIME" curl -sS -o /dev/null --max-time 15 "$ALLOWED_URL" 2>/dev/null; then
  bad "TLS succeeded without the proxy CA — traffic is NOT going through the proxy"
else
  ok "TLS fails closed without the proxy CA (traffic really is MITM'd by the proxy)"
fi

echo "==> out-of-allowlist egress (default deny)"
code="$(http_code "$BLOCKED_URL" --cacert "$CA_BUNDLE_IN_CONTAINER")"
if [ "$code" = "403" ]; then
  ok "non-allowlisted host rejected with 403 ($BLOCKED_URL)"
else
  bad "expected HTTP 403 for $BLOCKED_URL, got '${code:-none}'"
  docker logs "$PROXY" 2>&1 | tail -20 >&2 || true
fi

proxy_logs="$(docker logs "$PROXY" 2>&1 || true)"
if printf '%s' "$proxy_logs" | grep -q '"rejected_by"'; then
  ok "proxy audit log records the rejection (rejected_by field)"
else
  bad "proxy audit log has no rejected_by entry"
  printf '%s\n' "$proxy_logs" | tail -20 >&2 || true
fi
if printf '%s' "$proxy_logs" | grep -q '"host":"api.github.com"'; then
  ok "proxy audit log records the allowed host"
else
  bad "proxy audit log has no entry for the allowed host"
  printf '%s\n' "$proxy_logs" | tail -20 >&2 || true
fi

echo
echo "Egress integration: $pass passed, $fail failed"
[ "$fail" = 0 ]
