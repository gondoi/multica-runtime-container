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
#   - Agent CLI harness gate: cursor (default) and claude (Secret-projected
#     credential, binary usable as the non-root user, env reaching the daemon)
#   - login workspace_id clobber → re-pin from Secret / MULTICA_WORKSPACE slug
#   - AWS ConfigMap mounts → PVC provider homes; operator-only login guard
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
AWS_EX="$ROOT/examples/aws"
TIMEOUT_READY="${TIMEOUT_READY:-30}"

cd "$ROOT"

pass=0
fail=0
cname_env=""
cname_proj=""
cname_slug=""
cname_aws=""
cname_pwd=""
cname_lvl=""
cname_claude=""

ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

cleanup() {
  [ -n "$cname_env" ] && docker rm -f "$cname_env" >/dev/null 2>&1 || true
  [ -n "$cname_proj" ] && docker rm -f "$cname_proj" >/dev/null 2>&1 || true
  [ -n "$cname_slug" ] && docker rm -f "$cname_slug" >/dev/null 2>&1 || true
  [ -n "$cname_pwd" ] && docker rm -f "$cname_pwd" >/dev/null 2>&1 || true
  [ -n "$cname_lvl" ] && docker rm -f "$cname_lvl" >/dev/null 2>&1 || true
  [ -n "$cname_aws" ] && docker rm -f "$cname_aws" >/dev/null 2>&1 || true
  [ -n "$cname_claude" ] && docker rm -f "$cname_claude" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building $IMAGE"
docker build -t "$IMAGE" .

chmod +x "$STUB" "$ROOT/entrypoint.sh" \
  "$ROOT/bin/agent-harness.sh" \
  "$ROOT/bin/configure-git-auth.sh" "$ROOT/bin/materialize-secrets.sh" \
  "$ROOT/bin/materialize-aws.sh" "$ROOT/bin/aws-sso-guard.sh" \
  "$ROOT/bin/mint-github-app-token.sh" "$ROOT/bin/github-app-credential-helper.sh" \
  "$ROOT/bin/gh-wrapper.sh" "$ROOT/bin/log-level-filter.sh" \
  "$ROOT/bin/aws-credential-source.sh" \
  "$ROOT/bin/ready.sh"

wait_log() {
  # wait_log <container> <grep-pattern> [tries] — docker's log driver can lag the
  # container by a beat, so a single `docker logs` right after an exec-based
  # readiness check is racy. Poll instead of failing on a partial flush.
  local cname="$1" pattern="$2" tries="${3:-10}" i
  for i in $(seq 1 "$tries"); do
    if docker logs "$cname" 2>&1 | grep -q -- "$pattern"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

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

  # Daemon is started as a child (log streamer is foreground); require the
  # start invocation and no inventory sync — do not require a literal `exec`.
  if docker exec "$cname" grep -Eq 'multica daemon start' /entrypoint.sh \
    && ! docker exec "$cname" grep -Eq '(^|[[:space:]])(/usr/local/bin/)?(sync-inventory|inventory-sync)($|[[:space:]])' /entrypoint.sh; then
    ok "$label (ready.sh + daemon foreground, no inventory sync)"
  else
    bad "$label: entrypoint missing daemon start or still calls inventory sync"
    docker exec "$cname" sed -n '1,140p' /entrypoint.sh >&2 || true
  fi
}

echo "==> Crash fixtures (hard-fail secrets)"
run_crash no-multica "$FIX/crash-no-multica.env"
run_crash no-cursor "$FIX/crash-no-cursor.env"
run_crash no-claude-auth "$FIX/crash-no-claude-auth.env"
run_crash unknown-harness "$FIX/crash-unknown-harness.env"
run_crash no-git "$FIX/crash-no-git.env"
run_crash bad-log-level "$FIX/crash-bad-log-level.env"
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
if wait_log "$cname_proj" 'gates passed'; then
  ok "CURSOR_API_KEY gate passed via projected file mount"
else
  bad "projected Cursor key path did not reach gates-passed"
  docker logs "$cname_proj" >&2 || true
fi

# gh CLI: shipped in the image and authenticated from the daemon environment
# (configure-git-auth.sh seeds git-auth.env; entrypoint exports it).
if docker exec "$cname_proj" gh --version >/dev/null 2>&1; then
  ok "gh CLI present in image (wrapper → gh-real, no mint without App creds)"
else
  bad "gh CLI missing from image"
fi

# AWS CLI: shipped with no baked-in credentials; the boot log names the
# credential source the SDK chain resolved. The fixture wires none, so the
# line must say so — and the container still goes Ready (informational only).
if docker exec "$cname_proj" aws --version >/dev/null 2>&1; then
  ok "aws CLI (v2) present in image"
else
  bad "aws CLI missing from image"
fi
if wait_log "$cname_proj" 'aws auth: none detected'; then
  ok "boot reports resolved AWS credential source (none wired in fixture)"
else
  bad "entrypoint did not log the AWS credential source"
  docker logs "$cname_proj" >&2 || true
fi
if docker exec "$cname_proj" grep -qx 'GH_TOKEN=ghp_boot_seam_projected' /home/agent/.multica/git-auth.env; then
  ok "git-auth.env seeds GH_TOKEN for gh from the resolved tier"
else
  bad "git-auth.env missing GH_TOKEN seed"
  docker exec "$cname_proj" cat /home/agent/.multica/git-auth.env >&2 || true
fi
daemon_pid="$(docker exec "$cname_proj" pgrep -f 'sleep infinity' 2>/dev/null | head -1 || true)"
if [ -n "$daemon_pid" ] \
  && docker exec "$cname_proj" bash -c "tr '\\0' '\\n' < /proc/${daemon_pid}/environ | grep -qx 'GH_TOKEN=ghp_boot_seam_projected'"; then
  ok "daemon environment carries GH_TOKEN (gh usable inside tasks)"
else
  bad "daemon environment is missing GH_TOKEN"
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
  && wait_log "$cname_slug" "workspace pin: default workspace_id=00000000-0000-0000-0000-000000000001 (from 'fuel-labs')"; then
  ok "MULTICA_WORKSPACE=fuel-labs resolves + pins after login"
else
  bad "MULTICA_WORKSPACE slug pin failed: live='$slug_ws'"
  docker logs "$cname_slug" >&2 || true
fi

# Container stdout daemon-log level: default INFO must drop DBG records and keep
# INF/WRN/ERR (collection-side filter — daemon.log itself stays DEBUG).
lvl_logs=""
for _ in 1 2 3 4 5; do
  lvl_logs="$(docker logs "$cname_proj" 2>&1 || true)"
  grep -q 'INF stub info line' <<<"$lvl_logs" && break
  sleep 1
done
if grep -q 'INF stub info line' <<<"$lvl_logs" \
  && grep -q 'WRN stub warn line' <<<"$lvl_logs" \
  && grep -q 'ERR stub error line' <<<"$lvl_logs" \
  && ! grep -q 'DBG stub debug line' <<<"$lvl_logs"; then
  ok "default MULTICA_LOG_LEVEL=INFO (DBG filtered, INF/WRN/ERR kept)"
else
  bad "default log level did not filter DBG from container stdout"
  printf '%s\n' "$lvl_logs" >&2 || true
fi

if wait_log "$cname_proj" 'daemon log stream level: INFO'; then
  ok "entrypoint reports applied log level"
else
  bad "entrypoint did not report applied log level"
  docker logs "$cname_proj" >&2 || true
fi

echo "==> Happy path — MULTICA_LOG_LEVEL=DEBUG keeps DBG records"
cname_lvl="multica-boot-seam-lvl-$$"
docker run -d --name "$cname_lvl" \
  --env-file "$FIX/happy-projected.env" \
  -e MULTICA_LOG_LEVEL=DEBUG \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_lvl" "happy/log-level DEBUG Ready"
dbg_logs=""
for _ in 1 2 3 4 5; do
  dbg_logs="$(docker logs "$cname_lvl" 2>&1 || true)"
  grep -q 'DBG stub debug line' <<<"$dbg_logs" && break
  sleep 1
done
if grep -q 'DBG stub debug line' <<<"$dbg_logs"; then
  ok "MULTICA_LOG_LEVEL=DEBUG passes DBG through the filter"
else
  bad "MULTICA_LOG_LEVEL=DEBUG did not surface DBG records"
  printf '%s\n' "$dbg_logs" >&2 || true
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
if wait_log "$cname_pwd" 'GitHub password auth configured'; then
  ok "password tier: boot logs the chosen tier"
else
  bad "password tier: boot did not log the chosen tier"
fi


echo "==> Happy path — Claude Code harness (Secret-projected credential)"
cname_claude="multica-boot-seam-claude-$$"
docker run -d --name "$cname_claude" \
  --env-file "$FIX/happy-claude.env" \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/claude:/run/secrets/claude:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_claude" "happy/claude Ready"

# The pinned native binary must actually execute as the non-root agent user on
# this base image (glibc/lib deps) — the build proves it as root, this proves it
# for the runtime identity and env.
if claude_ver="$(docker exec "$cname_claude" claude --version 2>&1)"; then
  ok "claude CLI runs as non-root agent user ($claude_ver)"
else
  bad "claude CLI failed to run in the container: $claude_ver"
fi

if wait_log "$cname_claude" 'harness claude: ok'; then
  ok "claude harness gate passed from projected credential file"
else
  bad "claude harness gate did not report ok"
  docker logs "$cname_claude" >&2 || true
fi

if wait_log "$cname_claude" 'agent harnesses: claude'; then
  ok "claude-only boot needs no CURSOR_API_KEY (harnesses: claude)"
else
  bad "boot did not report the claude-only harness selection"
  docker logs "$cname_claude" >&2 || true
fi

# Auth passthrough: the daemon (and therefore every CLI it spawns) inherits the
# credential — never printed to the boot log.
claude_daemon_pid="$(docker exec "$cname_claude" pgrep -f 'sleep infinity' 2>/dev/null | head -1 || true)"
if [ -n "$claude_daemon_pid" ] \
  && docker exec "$cname_claude" bash -c "tr '\\0' '\\n' < /proc/${claude_daemon_pid}/environ | grep -qx 'ANTHROPIC_API_KEY=sk-ant-boot_seam_claude_fixture'"; then
  ok "daemon environment carries ANTHROPIC_API_KEY (Claude CLI auth passthrough)"
else
  bad "daemon environment is missing ANTHROPIC_API_KEY"
fi

if [ -n "$claude_daemon_pid" ] \
  && docker exec "$cname_claude" bash -c "tr '\\0' '\\n' < /proc/${claude_daemon_pid}/environ | grep -qx 'MULTICA_CLAUDE_PATH=/usr/local/bin/claude'" \
  && docker exec "$cname_claude" bash -c "tr '\\0' '\\n' < /proc/${claude_daemon_pid}/environ | grep -qx 'DISABLE_AUTOUPDATER=1'"; then
  ok "daemon environment pins MULTICA_CLAUDE_PATH + DISABLE_AUTOUPDATER"
else
  bad "daemon environment missing claude path/autoupdater pin"
fi

if docker logs "$cname_claude" 2>&1 | grep -q 'sk-ant-boot_seam_claude_fixture'; then
  bad "claude credential leaked into the boot log"
else
  ok "claude credential never appears in container logs"
fi

# Without AWS mounts, daemon still Ready (continue-on-degrade).
if docker logs "$cname_proj" 2>&1 | grep -q 'AWS profiles: no ConfigMap mounts'; then
  ok "AWS absent → continue degraded (projected happy path)"
else
  bad "expected degrade log when AWS ConfigMaps are not mounted"
  docker logs "$cname_proj" >&2 || true
fi

echo "==> Happy path — AWS ConfigMap mounts + SSO cache on workspaces + login guard"
cname_aws="multica-boot-seam-aws-$$"
docker run -d --name "$cname_aws" \
  --env-file "$FIX/happy-projected.env" \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  -v "$AWS_EX/config:/run/config/aws/config:ro" \
  -v "$AWS_EX/config.yaml:/run/config/aws-sso/config.yaml:ro" \
  "$IMAGE" >/dev/null

assert_ready_container "$cname_aws" "happy/aws Ready"

if docker exec "$cname_aws" test -L /home/agent/.aws \
  && docker exec "$cname_aws" test -L /home/agent/.config/aws-sso \
  && docker exec "$cname_aws" readlink /home/agent/.aws | grep -q '/workspaces/.provider-homes/aws$' \
  && docker exec "$cname_aws" readlink /home/agent/.config/aws-sso | grep -q '/workspaces/.provider-homes/aws-sso$'; then
  ok "AWS homes symlinked onto workspaces PVC provider-homes"
else
  bad "AWS provider-home symlinks missing or not on workspaces PVC"
  docker exec "$cname_aws" ls -la /home/agent/.aws /home/agent/.config/aws-sso >&2 || true
fi

if docker exec "$cname_aws" test -L /home/agent/workspaces/.provider-homes/aws/config \
  && docker exec "$cname_aws" test -L /home/agent/workspaces/.provider-homes/aws-sso/config.yaml \
  && docker exec "$cname_aws" grep -q 'my-org.awsapps.com' /home/agent/workspaces/.provider-homes/aws-sso/config.yaml; then
  ok "AWS ConfigMap files linked into PVC-backed provider homes"
else
  bad "AWS ConfigMap → PVC link failed"
  docker exec "$cname_aws" ls -la /home/agent/workspaces/.provider-homes/aws /home/agent/workspaces/.provider-homes/aws-sso >&2 || true
fi

ver_out="$(docker exec "$cname_aws" /usr/local/bin/aws-sso version 2>&1 || true)"
if docker exec "$cname_aws" test -x /usr/local/bin/aws-sso \
  && docker exec "$cname_aws" test -x /usr/local/libexec/aws-sso \
  && printf '%s' "$ver_out" | grep -q 'AWS SSO CLI'; then
  ok "aws-sso guard + real binary on PATH"
else
  bad "aws-sso binary/guard missing"
  printf '%s\n' "$ver_out" >&2
  docker exec "$cname_aws" ls -la /usr/local/bin/aws-sso /usr/local/libexec/aws-sso >&2 || true
fi

set +e
docker exec "$cname_aws" aws-sso login --url-action=print >/tmp/multica-boot-aws-login.out 2>&1
login_rc=$?
set -e
if [ "$login_rc" -ne 0 ] && grep -q 'operator-exec only' /tmp/multica-boot-aws-login.out; then
  ok "aws-sso login blocked without AWS_SSO_OPERATOR_LOGIN=1"
else
  bad "aws-sso login guard failed (rc=$login_rc)"
  sed -n '1,40p' /tmp/multica-boot-aws-login.out >&2 || true
fi

set +e
docker exec -e AWS_SSO_OPERATOR_LOGIN=1 "$cname_aws" \
  aws-sso login --url-action=print >/tmp/multica-boot-aws-login-op.out 2>&1
op_rc=$?
set -e
if ! grep -q 'operator-exec only' /tmp/multica-boot-aws-login-op.out; then
  ok "AWS_SSO_OPERATOR_LOGIN=1 bypasses login guard (rc=$op_rc)"
else
  bad "operator login still blocked by guard"
  sed -n '1,40p' /tmp/multica-boot-aws-login-op.out >&2 || true
fi

if docker exec "$cname_aws" printenv AWS_PROFILE >/dev/null 2>&1; then
  bad "AWS_PROFILE unexpectedly set in container env"
else
  ok "AWS_PROFILE unset (fail closed default)"
fi

cleanup
trap - EXIT

echo
echo "Boot seam: $pass passed, $fail failed"
[ "$fail" = 0 ]
