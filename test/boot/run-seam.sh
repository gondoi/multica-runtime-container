#!/usr/bin/env bash
# Compose/boot seam: prove happy-path Ready vs intentional Crash fixtures.
#
# Crash cases run the real image entrypoint (expect non-zero exit).
# Happy path mounts a stub `multica` so gates + exec-daemon can be asserted
# without a live Multica cloud (see parent Testing Decisions).
#
# Usage (from repo root):
#   ./test/boot/run-seam.sh
#   IMAGE=multica-runtime:local ./test/boot/run-seam.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${IMAGE:-multica-runtime:local}"
FIX="$ROOT/test/boot/fixtures"
STUB="$ROOT/test/boot/stubs/multica"
TIMEOUT_CRASH="${TIMEOUT_CRASH:-20}"
TIMEOUT_READY="${TIMEOUT_READY:-30}"

cd "$ROOT"

pass=0
fail=0

ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

echo "==> Building $IMAGE"
docker build -t "$IMAGE" .

chmod +x "$STUB" "$ROOT/entrypoint.sh" \
  "$ROOT/bin/configure-git-auth.sh" "$ROOT/bin/ready.sh"

run_crash() {
  local name="$1" envfile="$2"
  echo "==> Crash fixture: $name"
  set +e
  docker run --rm --env-file "$envfile" "$IMAGE" >/tmp/multica-boot-crash."$name".out 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    ok "crash/$name (exit=$rc)"
  else
    bad "crash/$name expected non-zero exit, got 0"
    sed -n '1,40p' /tmp/multica-boot-crash."$name".out || true
  fi
}

echo "==> Crash fixtures (hard-fail secrets)"
run_crash no-multica "$FIX/crash-no-multica.env"
run_crash no-cursor "$FIX/crash-no-cursor.env"
run_crash no-git "$FIX/crash-no-git.env"

echo "==> Happy path (stub multica → Ready)"
cname="multica-boot-seam-$$"
cleanup() { docker rm -f "$cname" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$cname" \
  --env-file "$FIX/happy.env" \
  -v "$STUB:/usr/local/bin/multica:ro" \
  "$IMAGE" >/dev/null

ready=0
deadline=$((SECONDS + TIMEOUT_READY))
while [ "$SECONDS" -lt "$deadline" ]; do
  if docker exec "$cname" /usr/local/bin/ready.sh >/dev/null 2>&1; then
    ready=1
    break
  fi
  # Still running?
  if ! docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; then
    echo "container exited early:" >&2
    docker logs "$cname" >&2 || true
    break
  fi
  sleep 1
done

if [ "$ready" = 1 ]; then
  # Contract: ends in exec daemon start; no sync helper invocation.
  if docker exec "$cname" grep -Eq 'exec multica daemon start' /entrypoint.sh \
    && ! docker exec "$cname" grep -Eq '(^|[[:space:]])(/usr/local/bin/)?(sync-inventory|inventory-sync)($|[[:space:]])' /entrypoint.sh; then
    ok "happy Ready (ready.sh + exec daemon foreground, no inventory sync step)"
  else
    bad "happy: entrypoint missing exec daemon start or still calls inventory sync"
    docker exec "$cname" sed -n '1,120p' /entrypoint.sh >&2 || true
  fi
else
  bad "happy: ready.sh did not succeed within ${TIMEOUT_READY}s"
  docker logs "$cname" >&2 || true
fi

cleanup
trap - EXIT

echo
echo "Boot seam: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
