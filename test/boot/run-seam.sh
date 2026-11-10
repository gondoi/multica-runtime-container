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
#   - OpenAI Codex harness: env key projected into $CODEX_HOME/auth.json (0600),
#     a Secret-mounted auth.json projected instead, and its Linux sandbox usable
#   - Harness PATH mask: harnesses MULTICA_AGENT_CLI did not select are
#     unresolvable in the daemon/task PATH (BOX-112)
#   - login workspace_id clobber → re-pin from Secret / MULTICA_WORKSPACE slug
#   - AWS ConfigMap mounts → PVC provider homes; operator-only login guard
#   - optional egress control: iron-proxy MITM CA trusted + fail-closed when the
#     CA is missing (default off = zero change to existing boots)
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
CERTS="$FIX/certs"
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
cname_codex=""
cname_codexproj=""
cname_machine=""
cname_nolog=""
cname_wedged=""
cname_egress=""
cname_both=""

ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

cleanup() {
  [ -n "$cname_env" ] && docker rm -f "$cname_env" >/dev/null 2>&1 || true
  [ -n "$cname_proj" ] && docker rm -f "$cname_proj" >/dev/null 2>&1 || true
  [ -n "$cname_slug" ] && docker rm -f "$cname_slug" >/dev/null 2>&1 || true
  [ -n "$cname_pwd" ] && docker rm -f "$cname_pwd" >/dev/null 2>&1 || true
  [ -n "$cname_lvl" ] && docker rm -f "$cname_lvl" >/dev/null 2>&1 || true
  [ -n "$cname_machine" ] && docker rm -f "$cname_machine" >/dev/null 2>&1 || true
  [ -n "$cname_aws" ] && docker rm -f "$cname_aws" >/dev/null 2>&1 || true
  [ -n "$cname_claude" ] && docker rm -f "$cname_claude" >/dev/null 2>&1 || true
  [ -n "$cname_codex" ] && docker rm -f "$cname_codex" >/dev/null 2>&1 || true
  [ -n "$cname_codexproj" ] && docker rm -f "$cname_codexproj" >/dev/null 2>&1 || true
  [ -n "$cname_nolog" ] && docker rm -f "$cname_nolog" >/dev/null 2>&1 || true
  [ -n "$cname_wedged" ] && docker rm -f "$cname_wedged" >/dev/null 2>&1 || true
  [ -n "$cname_egress" ] && docker rm -f "$cname_egress" >/dev/null 2>&1 || true
  [ -n "$cname_both" ] && docker rm -f "$cname_both" >/dev/null 2>&1 || true
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
  "$ROOT/bin/egress-proxy.sh" \
  "$ROOT/bin/ready.sh"

log_has() {
  # log_has <container> <grep-pattern> — SIGPIPE-safe `docker logs | grep -q`.
  #
  # `docker logs "$c" | grep -q PAT` is a trap under `set -o pipefail`: grep
  # exits on the first match, docker logs takes EPIPE and reports 141, and the
  # pipeline therefore looks like a MISS even though the pattern matched (the
  # line is even visible in the failure dump taken right after). Capture the
  # logs first, then grep the buffer — no pipe, no SIGPIPE.
  local cname="$1" pattern="$2" out
  out="$(docker logs "$cname" 2>&1 || true)"
  grep -q -- "$pattern" <<<"$out"
}

wait_log() {
  # wait_log <container> <grep-pattern> [tries] — docker's log driver can lag the
  # container by a beat, so a single `docker logs` right after an exec-based
  # readiness check is racy. Poll instead of failing on a partial flush.
  local cname="$1" pattern="$2" tries="${3:-10}" i
  for i in $(seq 1 "$tries"); do
    if log_has "$cname" "$pattern"; then
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

daemon_env_path() {
  # PATH as the daemon (and every task it spawns) sees it. `docker exec` starts
  # from the *image* env, not the boot env, so a boot-time PATH rewrite (harness
  # mask) is only observable here. The stub daemon is `sleep infinity`.
  local cname="$1" pid
  pid="$(docker exec "$cname" pgrep -f 'sleep infinity' 2>/dev/null | head -1 || true)"
  [ -n "$pid" ] || return 1
  docker exec "$cname" bash -c "tr '\\0' '\\n' < /proc/${pid}/environ | sed -n 's/^PATH=//p'" 2>/dev/null | head -1
}

daemon_command_v() {
  # daemon_command_v <container> <binary> → resolved path, non-zero when masked.
  local cname="$1" bin="$2" dpath
  dpath="$(daemon_env_path "$cname")" || return 1
  [ -n "$dpath" ] || return 1
  docker exec "$cname" bash -c "PATH='${dpath}'; export PATH; command -v '${bin}'" 2>/dev/null
}

daemon_has_bin() { daemon_command_v "$1" "$2" >/dev/null 2>&1; }

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

assert_stays_up() {
  # assert_stays_up <container> <label> [seconds]
  #
  # Regression guard for BOX-94: the entrypoint attached
  # `multica daemon logs --follow` before the daemon had written
  # $MULTICA_HOME/daemon.log, got "no log file found …", and exited 1 — a
  # CrashLoop on a perfectly healthy daemon. The stub models the real 0.8.0
  # ordering (daemon.log + status=running only after preflight), so a boot that
  # races the log file dies here instead of in production.
  local cname="$1" label="$2" secs="${3:-3}" i
  for i in $(seq 1 "$secs"); do
    if ! docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; then
      bad "$label: container exited ${i}s after boot (log-stream exit?)"
      docker logs "$cname" >&2 || true
      return 0
    fi
    sleep 1
  done
  ok "$label (still running ${secs}s after 'daemon up; streaming')"
}

echo "==> Crash fixtures (hard-fail secrets)"
run_crash no-multica "$FIX/crash-no-multica.env"
run_crash no-cursor "$FIX/crash-no-cursor.env"
run_crash no-claude-auth "$FIX/crash-no-claude-auth.env"
run_crash no-codex-auth "$FIX/crash-no-codex-auth.env"
run_crash unknown-harness "$FIX/crash-unknown-harness.env"
run_crash no-git "$FIX/crash-no-git.env"
run_crash bad-log-level "$FIX/crash-bad-log-level.env"
run_crash github-password-public "$FIX/crash-github-password-public.env"
run_crash machine-name-conflict "$FIX/crash-machine-name-conflict.env"
run_crash egress-proxy-no-ca "$FIX/crash-egress-proxy-no-ca.env"

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

# BOX-94 regression: the log follower must attach only once the daemon owns
# daemon.log, and its own failure must never take the container down.
if log_has "$cname_proj" 'no log file found'; then
  bad "log follower raced the daemon and hit 'no log file found'"
  docker logs "$cname_proj" >&2 || true
else
  ok "log follower waited for daemon.log (no 'no log file found' race)"
fi
assert_stays_up "$cname_proj" "happy/projected daemon survives log-stream attach"

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

echo "==> Happy path — MULTICA_MACHINE_NAME names the runtime in Multica's list"
cname_machine="multica-boot-seam-machine-$$"
docker run -d --name "$cname_machine" \
  --env-file "$FIX/happy-projected.env" \
  -e MULTICA_MACHINE_NAME=fuel-general \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_machine" "happy/machine-name Ready"
if docker exec "$cname_machine" grep -q -- '--device-name fuel-general' /tmp/multica-runtime.ready.args; then
  ok "MULTICA_MACHINE_NAME → daemon --device-name (runtime list shows 'Cursor (fuel-general)')"
else
  bad "daemon was not started with --device-name from MULTICA_MACHINE_NAME"
  docker exec "$cname_machine" cat /tmp/multica-runtime.ready.args >&2 || true
  docker logs "$cname_machine" >&2 || true
fi
if wait_log "$cname_machine" "runtime machine name: 'fuel-general'"; then
  ok "boot reports the resolved machine name"
else
  bad "entrypoint did not report the resolved machine name"
  docker logs "$cname_machine" >&2 || true
fi
# Unset → no --device-name override, so the CLI keeps its own (hostname) default.
if docker exec "$cname_proj" grep -q -- '--device-name' /tmp/multica-runtime.ready.args; then
  bad "daemon got a --device-name override without MULTICA_MACHINE_NAME"
else
  ok "unset MULTICA_MACHINE_NAME leaves the daemon's hostname default alone"
fi
# Trap guard: this fixture overrides MULTICA_AGENT_RUNTIME_NAME but not
# MULTICA_MACHINE_NAME — boot must say the former does not name the runtime.
if wait_log "$cname_proj" "WARN: MULTICA_AGENT_RUNTIME_NAME='multica-runtime-boot-seam-projected' does not change the runtime-list name"; then
  ok "boot warns when only MULTICA_AGENT_RUNTIME_NAME is set (runtime-list name unchanged)"
else
  bad "boot did not warn about the MULTICA_AGENT_RUNTIME_NAME trap"
  docker logs "$cname_proj" >&2 || true
fi
# ... and stays quiet when MULTICA_MACHINE_NAME is set (warning would be noise).
if log_has "$cname_machine" 'does not change the runtime-list name'; then
  bad "trap warning fired even though MULTICA_MACHINE_NAME was set"
else
  ok "no trap warning when MULTICA_MACHINE_NAME is set"
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

if log_has "$cname_claude" 'sk-ant-boot_seam_claude_fixture'; then
  bad "claude credential leaked into the boot log"
else
  ok "claude credential never appears in container logs"
fi

echo "==> Happy path — OpenAI Codex harness (env key → \$CODEX_HOME/auth.json)"
cname_codex="multica-boot-seam-codex-$$"
# bubblewrap — which codex's Linux sandbox uses for workspace-write — needs to
# create user, mount and *network* namespaces (it brings up loopback inside
# them). What a container runtime permits varies by host and kernel: this
# repo's dev host needs `--security-opt seccomp=unconfined --security-opt
# apparmor=unconfined`, and a GitHub-hosted runner refuses even with
# `--privileged`. `--privileged` gives the assertion a real run wherever the
# runtime allows it; the assertion below tolerates a namespace-policy refusal
# but still fails on an image-side defect. Boot and the gate need none of it.
docker run -d --name "$cname_codex" \
  --env-file "$FIX/happy-codex.env" \
  --privileged \
  -v "$STUB:/usr/local/bin/multica:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_codex" "happy/codex Ready"

# The pinned native binary must actually execute as the non-root agent user on
# this base image (musl static build), not only as root during the build.
if codex_ver="$(docker exec "$cname_codex" codex --version 2>&1)"; then
  ok "codex CLI runs as non-root agent user ($(printf '%s' "$codex_ver" | tail -1))"
else
  bad "codex CLI failed to run in the container: $codex_ver"
fi

if wait_log "$cname_codex" 'harness codex: ok'; then
  ok "codex harness gate passed"
else
  bad "codex harness gate did not report ok"
  docker logs "$cname_codex" >&2 || true
fi

if wait_log "$cname_codex" 'agent harnesses: codex'; then
  ok "codex-only boot needs no Cursor/Anthropic credential (harnesses: codex)"
else
  bad "boot did not report the codex-only harness selection"
  docker logs "$cname_codex" >&2 || true
fi

# Codex ignores OPENAI_API_KEY in the environment (codex-cli 0.167.0 sends no
# bearer and fails "Missing bearer or basic authentication") and authenticates
# from $CODEX_HOME/auth.json, so this projection is the difference between
# "gate passed" and "a task can actually authenticate".
codex_auth_mode="$(docker exec "$cname_codex" sed -n 's/.*"auth_mode"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' /home/agent/.codex/auth.json 2>/dev/null | head -1)"
codex_auth_perm="$(docker exec "$cname_codex" stat -c '%a' /home/agent/.codex/auth.json 2>/dev/null || true)"
if [ "$codex_auth_mode" = "apikey" ] && [ "$codex_auth_perm" = "600" ] \
  && docker exec "$cname_codex" grep -q 'sk-codex-boot_seam_fixture' /home/agent/.codex/auth.json; then
  ok "OPENAI_API_KEY projected into ~/.codex/auth.json (auth_mode=apikey, mode 600)"
else
  bad "codex auth.json missing or wrong (auth_mode='${codex_auth_mode}', mode='${codex_auth_perm}')"
  docker exec "$cname_codex" ls -la /home/agent/.codex >&2 || true
  docker logs "$cname_codex" >&2 || true
fi

# The pinned binary itself must accept the projected credential — cheap proof
# that the projection format is the one codex actually reads.
if docker exec "$cname_codex" codex login status 2>&1 | grep -q 'API key configured'; then
  ok "codex CLI accepts the projected credential (codex login status)"
else
  bad "codex CLI does not see the projected credential"
  docker exec "$cname_codex" codex login status >&2 || true
fi

codex_daemon_pid="$(docker exec "$cname_codex" pgrep -f 'sleep infinity' 2>/dev/null | head -1 || true)"
if [ -n "$codex_daemon_pid" ] \
  && docker exec "$cname_codex" bash -c "tr '\\0' '\\n' < /proc/${codex_daemon_pid}/environ | grep -qx 'MULTICA_CODEX_PATH=/usr/local/bin/codex'" \
  && docker exec "$cname_codex" bash -c "tr '\\0' '\\n' < /proc/${codex_daemon_pid}/environ | grep -qx 'OPENAI_API_KEY=sk-codex-boot_seam_fixture'"; then
  ok "daemon env pins MULTICA_CODEX_PATH and carries OPENAI_API_KEY"
else
  bad "daemon environment is missing the codex path/key"
fi

if log_has "$cname_codex" 'sk-codex-boot_seam_fixture'; then
  bad "codex credential leaked into the boot log"
else
  ok "codex credential never appears in container logs"
fi

# workspace-write (the daemon's codex sandbox policy) needs bubblewrap, which
# needs user, mount and network namespaces. Docker grants that differently per
# host/kernel: this repo's dev host needs
# `--security-opt seccomp=unconfined --security-opt apparmor=unconfined`, the
# GitHub-hosted runner refuses even with `--privileged`
# (`bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`). So the
# assertion splits the two halves:
#   - image half (ours): bwrap present, `codex-linux-sandbox` helper resolvable,
#     and no "bubblewrap is unavailable"/"codex-linux-sandbox executable not
#     found" error → a sandbox *failure* below that names one of those is a
#     real regression and fails the suite.
#   - runtime half (the operator's): whether namespaces are permitted here. A
#     namespace-policy refusal is reported, not failed — see docs/docker.md.
sandbox_out="$(docker exec "$cname_codex" codex sandbox -- /bin/echo codex-sandbox-ok 2>&1 || true)"
if printf '%s' "$sandbox_out" | grep -q 'codex-sandbox-ok'; then
  ok "codex Linux sandbox runs in the container (bubblewrap usable in this runtime)"
elif printf '%s' "$sandbox_out" | grep -qE 'bwrap: (No permissions to create new namespace|Failed to make / slave|loopback: Failed RTM_NEWADDR)'; then
  ok "codex sandbox wiring present; this runtime blocks bwrap namespaces ($(printf '%s' "$sandbox_out" | grep -o 'bwrap: .*' | head -1)) — see docs/docker.md"
else
  bad "codex sandbox failed in a way that points at the image, not the runtime: $sandbox_out"
fi

echo "==> Happy path — Codex login projected from a Secret (auth.json mount)"
cname_codexproj="multica-boot-seam-codexproj-$$"
docker run -d --name "$cname_codexproj" \
  --env-file "$FIX/happy-codex-projected.env" \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/codex:/run/secrets/codex:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_codexproj" "happy/codex-projected Ready"
if wait_log "$cname_codexproj" 'codex: projected auth.json' \
  && docker exec "$cname_codexproj" grep -q 'sk-codex-boot_seam_projected_fixture' /home/agent/.codex/auth.json \
  && [ "$(docker exec "$cname_codexproj" stat -c '%a' /home/agent/.codex/auth.json 2>/dev/null || true)" = "600" ]; then
  ok "mounted auth.json → ~/.codex/auth.json (0600, no OPENAI_API_KEY needed)"
else
  bad "mounted codex auth.json was not projected"
  docker exec "$cname_codexproj" ls -la /home/agent/.codex >&2 || true
  docker logs "$cname_codexproj" >&2 || true
fi

echo "==> Harness PATH mask — unselected harnesses leave the daemon/task PATH"
# BOX-112: the image ships cursor-agent *and* claude, so a deployment that
# selected only one must not find the other on the PATH the daemon (and every
# task it spawns) inherits. Asserted against the daemon env: `docker exec`
# shells inherit the image env, where both binaries stay installed.
proj_daemon_path="$(daemon_env_path "$cname_proj" || true)"
if [ -n "$proj_daemon_path" ] && daemon_has_bin "$cname_proj" cursor-agent \
  && ! daemon_has_bin "$cname_proj" claude \
  && ! daemon_has_bin "$cname_proj" codex; then
  ok "cursor-only daemon PATH: cursor-agent resolvable, claude + codex masked"
else
  bad "cursor-only daemon PATH still exposes claude/codex (PATH='${proj_daemon_path}')"
fi
if printf '%s' "${proj_daemon_path:-}" | grep -q 'multica-harness-mask/entry-'; then
  ok "cursor-only daemon PATH points at the boot-time harness mask mirror"
else
  bad "cursor-only daemon PATH was not rewritten (PATH='${proj_daemon_path}')"
fi
if [ -n "$proj_daemon_path" ] \
  && docker exec "$cname_proj" bash -c "PATH='${proj_daemon_path}'; export PATH; cursor-agent --version" >/dev/null 2>&1; then
  ok "selected cursor-agent still runs through the masked daemon PATH"
else
  bad "cursor-agent does not run through the masked daemon PATH"
fi

claude_daemon_path="$(daemon_env_path "$cname_claude" || true)"
if [ -n "$claude_daemon_path" ] && daemon_has_bin "$cname_claude" claude \
  && ! daemon_has_bin "$cname_claude" cursor-agent \
  && ! daemon_has_bin "$cname_claude" agent \
  && ! daemon_has_bin "$cname_claude" codex; then
  ok "claude-only daemon PATH: claude resolvable, cursor-agent + 'agent' alias + codex masked"
else
  bad "claude-only daemon PATH still exposes cursor-agent/agent/codex (PATH='${claude_daemon_path}')"
fi
if [ -n "$claude_daemon_path" ] \
  && docker exec "$cname_claude" bash -c "PATH='${claude_daemon_path}'; export PATH; claude --version" >/dev/null 2>&1; then
  ok "claude still runs through the masked daemon PATH"
else
  bad "claude does not run through the masked daemon PATH"
fi

# Injection guard: masking must never disturb a selected harness's hard gate.
# crash-no-claude-auth.env selects claude without an Anthropic credential and
# still has to CrashLoop (run above), and the claude-only boot reached Ready.
if wait_log "$cname_claude" 'harness claude: ok' \
  && ! log_has "$cname_claude" 'required binary not on PATH: claude'; then
  ok "selected-harness gate unaffected by the mask (binary still gated as before)"
else
  bad "masking interfered with the selected-harness binary gate"
  docker logs "$cname_claude" >&2 || true
fi

echo "==> Happy path — all harnesses selected (mask is a no-op)"
cname_both="multica-boot-seam-both-$$"
docker run -d --name "$cname_both" \
  --env-file "$FIX/happy-both.env" \
  -v "$STUB:/usr/local/bin/multica:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_both" "happy/all-harnesses Ready"
both_daemon_path="$(daemon_env_path "$cname_both" || true)"
if [ -n "$both_daemon_path" ] && daemon_has_bin "$cname_both" cursor-agent \
  && daemon_has_bin "$cname_both" claude \
  && daemon_has_bin "$cname_both" codex \
  && ! printf '%s' "$both_daemon_path" | grep -q 'multica-harness-mask'; then
  ok "cursor,claude,codex daemon PATH: all resolvable, no mask mirror (mask is a no-op)"
else
  bad "all-selected boot masked a selected harness (PATH='${both_daemon_path}')"
fi

# Without AWS mounts, daemon still Ready (continue-on-degrade).
if wait_log "$cname_proj" 'AWS profiles: no ConfigMap mounts'; then
  ok "AWS absent → continue degraded (projected happy path)"
else
  bad "expected degrade log when AWS ConfigMaps are not mounted"
  docker logs "$cname_proj" >&2 || true
fi

echo "==> Happy path — AWS ConfigMap mounts + SSO cache on workspaces + login guard"
cname_aws="multica-boot-seam-aws-$$"
docker run -d --name "$cname_aws" \
  --env-file "$FIX/happy-projected.env" \
  -e AWS_SSO_FILE_PASSWORD_FILE=/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  -v "$SECRETS/aws-sso:/run/secrets/aws-sso:ro" \
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

# aws-sso SecureStore passphrase (BOX-124): lifted from the mounted Secret file
# into the daemon env so a non-TTY `credential_process` can unlock the encrypted
# store. Asserted against the daemon env (`docker exec` starts from the image
# env, not the boot env), and the value must never reach the boot log.
aws_daemon_pid="$(docker exec "$cname_aws" pgrep -f 'sleep infinity' 2>/dev/null | head -1 || true)"
if [ -n "$aws_daemon_pid" ] \
  && docker exec "$cname_aws" bash -c "tr '\\0' '\\n' < /proc/${aws_daemon_pid}/environ | grep -qx 'AWS_SSO_FILE_PASSWORD=boot-seam-fake-passphrase'"; then
  ok "aws-sso passphrase Secret lifted into the daemon env (AWS_SSO_FILE_PASSWORD)"
else
  bad "AWS_SSO_FILE_PASSWORD not in the daemon env from /run/secrets/aws-sso"
fi

if docker logs "$cname_aws" 2>&1 | grep -q 'boot-seam-fake-passphrase'; then
  bad "boot log leaked the aws-sso passphrase"
else
  ok "aws-sso passphrase never logged"
fi

echo "==> Happy path — optional egress proxy (iron-proxy): MITM CA trusted, default off"
# Egress policy itself lives in the proxy (allowlist, audit log); this image only
# trusts its MITM CA and fails closed without it. The fixture mounts the
# throwaway CA at the documented compose/k8s path and asserts the daemon env
# carries the exported bundle, so every task the daemon spawns inherits it.
cname_egress="multica-boot-seam-egress-$$"
docker run -d --name "$cname_egress" \
  --env-file "$FIX/happy-projected.env" \
  -e MULTICA_EGRESS_PROXY=iron-proxy \
  -e MULTICA_EGRESS_PROXY_CA=/run/certs/iron-proxy/ca.crt \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  -v "$CERTS/iron-proxy:/run/certs/iron-proxy:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_egress" "happy/egress-proxy Ready"

if wait_log "$cname_egress" 'egress proxy: iron-proxy'; then
  ok "boot reports the iron-proxy mode it enabled"
else
  bad "boot did not report the enabled egress proxy"
  docker logs "$cname_egress" >&2 || true
fi

if wait_log "$cname_egress" 'DNS routing is deployment-side'; then
  ok "boot states DNS routing is the deployment's job (no false 'enforced' claim)"
else
  bad "boot did not describe the DNS-routing division of labour"
  docker logs "$cname_egress" >&2 || true
fi

egress_bundle="/home/agent/.multica/egress-ca-bundle.crt"
egress_bundle_body="$(docker exec "$cname_egress" cat "$egress_bundle" 2>/dev/null || true)"
fixture_body="$(sed -n '3p' "$CERTS/iron-proxy/ca.crt")"
cert_count="$(printf '%s' "$egress_bundle_body" | grep -c -- '-----BEGIN CERTIFICATE-----' || true)"
if printf '%s' "$egress_bundle_body" | grep -qF -- "$fixture_body" \
  && [ "${cert_count:-0}" -gt 1 ]; then
  ok "combined bundle = system CAs + proxy CA ($cert_count certs)"
else
  bad "combined CA bundle missing the proxy CA or the system CAs (count='${cert_count:-0}')"
  docker exec "$cname_egress" ls -l "$egress_bundle" >&2 || true
fi

egress_pid="$(docker exec "$cname_egress" pgrep -f 'sleep infinity' 2>/dev/null | head -1 || true)"
if [ -n "$egress_pid" ] \
  && docker exec "$cname_egress" bash -c "tr '\\0' '\\n' < /proc/${egress_pid}/environ | grep -qx 'SSL_CERT_FILE=${egress_bundle}'" \
  && docker exec "$cname_egress" bash -c "tr '\\0' '\\n' < /proc/${egress_pid}/environ | grep -qx 'NODE_EXTRA_CA_CERTS=${egress_bundle}'" \
  && docker exec "$cname_egress" bash -c "tr '\\0' '\\n' < /proc/${egress_pid}/environ | grep -qx 'GIT_SSL_CAINFO=${egress_bundle}'"; then
  ok "daemon env carries SSL_CERT_FILE/NODE_EXTRA_CA_CERTS/GIT_SSL_CAINFO (harnesses + git inherit CA trust)"
else
  bad "daemon environment is missing the egress CA env vars"
fi

# Rollback contract: the default boot (no MULTICA_EGRESS_PROXY) must be exactly
# today's behaviour — no CA override in the daemon env at all.
proj_pid="$(docker exec "$cname_proj" pgrep -f 'sleep infinity' 2>/dev/null | head -1 || true)"
if wait_log "$cname_proj" 'egress proxy: off'; then
  ok "default boot reports egress proxy: off"
else
  bad "default boot did not report egress proxy: off"
  docker logs "$cname_proj" >&2 || true
fi
if [ -n "$proj_pid" ] \
  && ! docker exec "$cname_proj" bash -c "tr '\\0' '\\n' < /proc/${proj_pid}/environ | grep -q '^SSL_CERT_FILE='"; then
  ok "egress off exports no CA override (flip the flag back = today's behaviour)"
else
  bad "egress-off boot still exported SSL_CERT_FILE"
fi

echo "==> Happy path — daemon with no daemon.log (TTY-style stderr) still stays up"
# A daemon attached to a terminal keeps its records on that terminal and never
# writes daemon.log (CLI 0.8.0 runDaemonForeground). `daemon logs --follow`
# cannot work there; boot must degrade with a warning instead of CrashLooping.
cname_nolog="multica-boot-seam-nolog-$$"
docker run -d --name "$cname_nolog" \
  --env-file "$FIX/happy-projected.env" \
  -e MULTICA_STUB_NO_LOG_FILE=1 \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  "$IMAGE" >/dev/null
assert_ready_container "$cname_nolog" "happy/no-daemon-log Ready"
if wait_log "$cname_nolog" 'no daemon log at .*daemon.log after 5s' 20; then
  ok "missing daemon.log degrades to a warning (level filter skipped)"
else
  bad "boot did not warn about the missing daemon log"
  docker logs "$cname_nolog" >&2 || true
fi
assert_stays_up "$cname_nolog" "happy/no-daemon-log daemon survives (no log file)"

echo "==> Happy path — daemon alive but never reports running: not Ready, no CrashLoop"
# `multica daemon status` exits 0 for a stopped daemon, so a probe that reads
# only its exit code reports Ready forever (that is what made the liveness probe
# useless). Gate on the reported state: alive process, status "stopped" →
# ready.sh must fail, and boot must keep supervising instead of exiting.
cname_wedged="multica-boot-seam-wedged-$$"
docker run -d --name "$cname_wedged" \
  --env-file "$FIX/happy-projected.env" \
  -e MULTICA_STUB_NEVER_RUNNING=1 \
  -v "$STUB:/usr/local/bin/multica:ro" \
  -v "$SECRETS/multica-home:/run/secrets/multica-home:ro" \
  -v "$SECRETS/cursor:/run/secrets/cursor:ro" \
  -v "$SECRETS/git:/run/secrets/git:ro" \
  "$IMAGE" >/dev/null
if wait_log "$cname_wedged" 'has not reported status=running after 10s' 20; then
  ok "boot does not fake readiness when the daemon never reports running"
else
  bad "boot never reported the missing running status"
  docker logs "$cname_wedged" >&2 || true
fi
if docker exec "$cname_wedged" /usr/local/bin/ready.sh >/dev/null 2>&1; then
  bad "ready.sh reported Ready while daemon status was 'stopped'"
else
  ok "ready.sh not Ready while daemon status is 'stopped' (probe is not vacuous)"
fi
assert_stays_up "$cname_wedged" "daemon-alive-but-not-running survives (no CrashLoop)"

cleanup
trap - EXIT

echo
echo "Boot seam: $pass passed, $fail failed"
[ "$fail" = 0 ]
