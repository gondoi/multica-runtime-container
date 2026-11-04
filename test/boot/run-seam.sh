#!/usr/bin/env bash
# Compose/boot seam: prove happy-path Ready vs intentional Crash fixtures.
#
# Crash cases run the real image entrypoint (expect non-zero exit).
# Happy paths mount a stub `multica` so gates + exec-daemon can be asserted
# without a live Multica cloud (see parent Testing Decisions).
#
# Covers:
#   - env-file secrets (override path)
#   - Secret-projected Multica home + Cursor/git file mounts (K8s parity)
#   - login workspace_id clobber → re-pin from Secret / MULTICA_WORKSPACE slug
#
# Usage (from repo root):
#   ./test/boot/run-seam.sh
#   IMAGE=multica-runtime:local ./test/boot/run-seam.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${IMAGE:-multica-runtime:local}"
FIX="$ROOT/test/boot/fixtures"
STUB="$ROOT/test/boot/stubs/multica"
SECRETS="$FIX/secrets"
TIMEOUT_READY="${TIMEOUT_READY:-30}"

cd "$ROOT"

pass=0
fail=0
cname_env=""
cname_proj=""
cname_slug=""
cname_pwd=""

ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

cleanup() {
  [ -n "$cname_env" ] && docker rm -f "$cname_env" >/dev/null 2>&1 || true
  [ -n "$cname_proj" ] && docker rm -f "$cname_proj" >/dev/null 2>&1 || true
  [ -n "$cname_slug" ] && docker rm -f "$cname_slug" >/dev/null 2>&1 || true
  [ -n "$cname_pwd" ] && docker rm -f "$cname_pwd" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building $IMAGE"
docker build -t "$IMAGE" .

chmod +x "$STUB" "$ROOT/entrypoint.sh" \
  "$ROOT/bin/configure-git-auth.sh" "$ROOT/bin/materialize-secrets.sh" \
  "$ROOT/bin/mint-github-app-token.sh" "$ROOT/bin/github-app-credential-helper.sh" \
  "$ROOT/bin/ready.sh"

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

assert_ready_container() {
  local cname="$1" label="$2"
  local ready=0
  local deadline=$((SECONDS + TIMEOUT_READY))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if docker exec "$cname" /usr/local/bin/ready.sh >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; then
      echo "container exited early:" >&2
      docker logs "$cname" >&2 || true
      break
    fi
    sleep 1
  done

  if [ "$ready" != 1 ]; then
    bad "$label: ready.sh did not succeed within ${TIMEOUT_READY}s"
    docker logs "$cname" >&2 || true
    return 0
  fi

  if docker exec "$cname" grep -Eq 'exec multica daemon start' /entrypoint.sh \
    && ! docker exec "$cname" grep -Eq '(^|[[:space:]])(/usr/local/bin/)?(sync-inventory|inventory-sync)($|[[:space:]])' /entrypoint.sh; then
    ok "$label (ready.sh + exec daemon foreground, no inventory sync)"
  else
    bad "$label: entrypoint missing exec daemon start or still calls inventory sync"
    docker exec "$cname" sed -n '1,140p' /entrypoint.sh >&2 || true
  fi
}

echo "==> Crash fixtures (hard-fail secrets)"
run_crash no-multica "$FIX/crash-no-multica.env"
run_crash no-cursor "$FIX/crash-no-cursor.env"
run_crash no-git "$FIX/crash-no-git.env"
run_crash github-password-public "$FIX/crash-github-password-public.env"

echo "==> Happy path — env-file secrets (stub multica → Ready)"
cname_env="multica-boot-seam-env-$$"
docker run -d --name "$cname_env" \
  --env-file "$FIX/happy.env" \
  -v "$STUB:/usr/local/bin/multica:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_env" "happy/env Ready"

echo "==> Happy path — Secret-projected Multica home + Cursor/git files"
cname_proj="multica-boot-seam-proj-$$"
docker run -d --name "$cname_proj" \
  --env-file "$FIX/happy-projected.env" \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_proj" "happy/projected Ready"

# Projected daemon.id must land in ephemeral Multica home (no Multica-home PVC).
if docker exec "$cname_proj" test -f /home/agent/.multica/daemon.id \
  && docker exec "$cname_proj" grep -qx 'multica-runtime-boot-seam-projected' /home/agent/.multica/daemon.id; then
  ok "projected daemon.id → ephemeral ~/.multica (no Multica-home PVC)"
else
  bad "projected daemon.id missing or wrong in /home/agent/.multica"
  docker exec "$cname_proj" ls -la /home/agent/.multica >&2 || true
fi

# Projected config.json copied (token lifted for Multica gate — Ready already implies).
if docker exec "$cname_proj" test -f /home/agent/.multica/config.json \
  && docker exec "$cname_proj" grep -q 'mul_boot_seam_projected' /home/agent/.multica/config.json; then
  ok "projected config.json → ephemeral ~/.multica"
else
  bad "projected config.json missing in ephemeral Multica home"
  docker exec "$cname_proj" ls -la /home/agent/.multica >&2 || true
fi

# Git credential helper from projected GITHUB_TOKEN (non-interactive HTTPS).
if docker exec "$cname_proj" test -s /home/agent/.git-credentials \
  && docker exec "$cname_proj" grep -q 'ghp_boot_seam_projected' /home/agent/.git-credentials; then
  ok "projected GITHUB_TOKEN → git credential helper (non-interactive HTTPS)"
else
  bad "git credentials not configured from projected GITHUB_TOKEN"
  docker logs "$cname_proj" >&2 || true
fi

# Ready with projected Cursor key (no CURSOR_API_KEY in env-file) proves file mount worked.
if docker logs "$cname_proj" 2>&1 | grep -q 'gates passed'; then
  ok "CURSOR_API_KEY gate passed via projected file mount"
else
  bad "projected Cursor key path did not reach gates-passed"
  docker logs "$cname_proj" >&2 || true
fi

# Compose contract: no Multica-home named volume at ~/.multica.
if grep -Eq 'multica-home:/home/agent/\.multica' "$ROOT/docker-compose.yml"; then
  bad "compose still mounts a Multica-home volume at ~/.multica"
else
  ok "compose has no Multica-home volume (Secret bind-mounts only)"
fi

# Login clobber regression: stub login flips workspace_id to Homelab; entrypoint
# must re-pin from projected Secret (or MULTICA_WORKSPACE slug) after login.
live_ws="$(docker exec "$cname_proj" jq -r '.workspace_id // empty' /home/agent/.multica/config.json 2>/dev/null || true)"
if [ "$live_ws" = "00000000-0000-0000-0000-000000000001" ]; then
  ok "workspace pin after login (Secret workspace_id survives stub login clobber)"
else
  bad "workspace pin after login failed: live='$live_ws' want Secret Fuel Labs UUID"
  docker exec "$cname_proj" cat /home/agent/.multica/config.json >&2 || true
  docker logs "$cname_proj" >&2 || true
fi

echo "==> Happy path — MULTICA_WORKSPACE slug overrides Secret UUID after login"
cname_slug="multica-boot-seam-slug-$$"
docker run -d --name "$cname_slug" \
  --env-file "$FIX/happy-projected.env" \
  -e MULTICA_WORKSPACE=fuel-labs \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  "$IMAGE" >/dev/null

assert_ready_container "$cname_slug" "happy/slug Ready"
slug_ws="$(docker exec "$cname_slug" jq -r '.workspace_id // empty' /home/agent/.multica/config.json 2>/dev/null || true)"
if [ "$slug_ws" = "00000000-0000-0000-0000-000000000001" ] \
  && docker logs "$cname_slug" 2>&1 | grep -q "workspace pin: default workspace_id=00000000-0000-0000-0000-000000000001 (from 'fuel-labs')"; then
  ok "MULTICA_WORKSPACE=fuel-labs resolves + pins after login"
else
  bad "MULTICA_WORKSPACE slug pin failed: live='$slug_ws'"
  docker logs "$cname_slug" >&2 || true
fi

echo "==> Happy path — GitHub Enterprise Server password tier (lowest priority)"
cname_pwd="multica-boot-seam-pwd-$$"
docker run -d --name "$cname_pwd" \
  --env-file "$FIX/happy-github-password.env" \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git-password:/run/secrets/git-password:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_pwd" "happy/github-password Ready"
if docker exec "$cname_pwd" grep -q 'https://boot-seam-agent:boot-seam-password@ghes.boot-seam.invalid' /home/agent/.git-credentials; then
  ok "password tier: User/Password/Host Secret files → git credential helper"
else
  bad "password tier: .git-credentials missing GHES host entry"
  docker exec "$cname_pwd" cat /home/agent/.git-credentials >&2 || true
  docker logs "$cname_pwd" >&2 || true
fi
if docker logs "$cname_pwd" 2>&1 | grep -q 'GitHub password auth configured'; then
  ok "password tier: boot logs the chosen tier"
else
  bad "password tier: boot did not log the chosen tier"
fi

cleanup
trap - EXIT

echo
echo "Boot seam: $pass passed, $fail failed"
[ "$fail" = 0 ]
