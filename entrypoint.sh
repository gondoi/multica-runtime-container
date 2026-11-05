#!/usr/bin/env bash
# Multica runtime home-base boot contract (minimal / Multica-native):
#   1. Source config / helpers
#   1b. Resolve machine name (runtime-list display name)
#   2. Materialize Secret-projected Multica home + Cursor/git tokens
#   2a. Wire optional AWS ConfigMaps + SSO cache onto workspaces PVC
#   3. Hard-fail gates (required binaries + Multica/git-auth secrets, plus the
#      agent CLI harness(es) named by MULTICA_AGENT_CLI)
#   4. Configure git HTTPS credential helper
#   4b. Validate MULTICA_LOG_LEVEL + export it (log-stream filter, see below)
#   4c. Report the resolved AWS credential source (informational; no creds)
#   5. login → pin workspace (env/Secret) → daemon start --foreground
#
# Ready = daemon is up after gates. There is NO boot-time inventory sync —
# repos materialize lazily via `multica repo checkout` during tasks.
#
# Multica home (`config.json` + `daemon.id`) comes from Secret projection
# (or compose bind-mount of the same layout). There is NO Multica-home PVC —
# only the workspaces volume is durable (also holds AWS SSO cache).
#
# Missing Multica/git secrets, a missing selected-harness binary/credential, or
# an unknown MULTICA_AGENT_CLI → non-zero exit (CrashLoop).
# Missing AWS ConfigMaps → continue degraded (daemon still Ready).
# Scratch shell: docker run --entrypoint /bin/bash ...
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ── 1. Config / env helpers ───────────────────────────────────────────────
for env_file in /app/.env /.env /run/secrets/multica.env; do
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
done

export MULTICA_AGENT_RUNTIME_NAME="${MULTICA_AGENT_RUNTIME_NAME:-multica-runtime}"
export MULTICA_WORKSPACES_ROOT="${MULTICA_WORKSPACES_ROOT:-/home/agent/workspaces}"
mkdir -p "$MULTICA_WORKSPACES_ROOT"

# ── 1b. Machine name → runtime-list display name ──────────────────────────
# Multica names each runtime "<Provider> (<device-name>)" (e.g. "Cursor
# (fuel-general)"), where the device name is the daemon's `--device-name`
# (env MULTICA_DAEMON_DEVICE_NAME) and defaults to the OS hostname — which in
# Kubernetes is the pod name (multica-runtime-6cc749d9f7-dr2gh).
# MULTICA_MACHINE_NAME is this image's knob for it; the native CLI env is
# accepted as an alias. `--runtime-name` (MULTICA_AGENT_RUNTIME_NAME) does NOT
# feed that name for built-in providers — verified against the CLI 0.8.0
# registration payload (device_name is sent, runtime_name is not).
MULTICA_MACHINE_NAME="${MULTICA_MACHINE_NAME:-}"
MULTICA_DAEMON_DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME:-}"
if [ -n "$MULTICA_MACHINE_NAME" ] && [ -n "$MULTICA_DAEMON_DEVICE_NAME" ] \
  && [ "$MULTICA_MACHINE_NAME" != "$MULTICA_DAEMON_DEVICE_NAME" ]; then
  die "MULTICA_MACHINE_NAME='${MULTICA_MACHINE_NAME}' conflicts with MULTICA_DAEMON_DEVICE_NAME='${MULTICA_DAEMON_DEVICE_NAME}' — set only one"
fi
MULTICA_MACHINE_NAME="${MULTICA_MACHINE_NAME:-$MULTICA_DAEMON_DEVICE_NAME}"
if [ -n "$MULTICA_MACHINE_NAME" ]; then
  case "$MULTICA_MACHINE_NAME" in
    *[[:cntrl:]]*) die "MULTICA_MACHINE_NAME must not contain control characters (got '${MULTICA_MACHINE_NAME}')" ;;
  esac
  case "$MULTICA_MACHINE_NAME" in
    " "*|*" ") die "MULTICA_MACHINE_NAME must not start or end with whitespace (got '${MULTICA_MACHINE_NAME}')" ;;
  esac
  [ "${#MULTICA_MACHINE_NAME}" -le 64 ] \
    || die "MULTICA_MACHINE_NAME must be 64 characters or fewer (got ${#MULTICA_MACHINE_NAME})"
  MULTICA_DAEMON_DEVICE_NAME="$MULTICA_MACHINE_NAME"
  export MULTICA_DAEMON_DEVICE_NAME
  log "runtime machine name: '${MULTICA_MACHINE_NAME}' (runtime list shows '<Provider> (${MULTICA_MACHINE_NAME})')"
else
  log "runtime machine name: default (OS hostname) — set MULTICA_MACHINE_NAME for a readable runtime-list name"
  # The most common mistake this image has produced: setting
  # MULTICA_AGENT_RUNTIME_NAME (the daemon's --runtime-name, which the image also
  # defaults to "multica-runtime") and expecting the runtime list to show it.
  # It does not — so point at the knob that works, but only when the value was
  # actually overridden away from the image default (otherwise every laptop
  # would get a warning on a normal boot).
  if [ "$MULTICA_AGENT_RUNTIME_NAME" != "multica-runtime" ]; then
    log "WARN: MULTICA_AGENT_RUNTIME_NAME='${MULTICA_AGENT_RUNTIME_NAME}' does not change the runtime-list name (it is the daemon's --runtime-name, not its device name) — set MULTICA_MACHINE_NAME='${MULTICA_AGENT_RUNTIME_NAME}' to show that name in Multica's runtime list"
  fi
fi

SERVER_URL="${MULTICA_SERVER_URL:-https://api.multica.ai}"
APP_URL="${MULTICA_APP_URL:-https://multica.ai}"

# ── 2. Secret projection → ephemeral Multica home + token env ─────────────
# shellcheck disable=SC1091
source /usr/local/bin/materialize-secrets.sh

export MULTICA_DAEMON_ID="${MULTICA_DAEMON_ID:-$MULTICA_AGENT_RUNTIME_NAME}"

# ── 2a. Optional AWS ConfigMaps + SSO cache on workspaces PVC ─────────────
# shellcheck disable=SC1091
source /usr/local/bin/materialize-aws.sh


# ── 2b. Daemon log level (collection-side) ────────────────────────────────
# `multica daemon start` has no --log-level flag and there is no log-level
# env/config key (CLI 0.8.0); its handler level is fixed at debug and writes
# DBG records to $MULTICA_HOME/daemon.log unconditionally. So MULTICA_LOG_LEVEL
# does not change what the daemon emits — it filters the daemon log stream we
# mirror to container stdout (docker logs / kubectl logs). DEBUG = show all.
# Upstream ask: a real --log-level/env on `multica daemon start`.
MULTICA_LOG_LEVEL="$(printf '%s' "${MULTICA_LOG_LEVEL:-INFO}" | tr '[:lower:]' '[:upper:]')"
case "$MULTICA_LOG_LEVEL" in
  DEBUG|INFO|WARN|ERROR) ;;
  *) die "MULTICA_LOG_LEVEL must be DEBUG|INFO|WARN|ERROR (got '${MULTICA_LOG_LEVEL}')" ;;
esac
log "daemon log stream level: $MULTICA_LOG_LEVEL (filter on container stdout; daemon.log stays DEBUG)"

# ── 3. Hard gates: binaries ───────────────────────────────────────────────
require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary not on PATH: $1"
}

require_bin multica
require_bin gh
require_bin git
require_bin jq
require_bin curl
require_bin asdf
require_bin aws
require_bin aws-sso
require_bin awk
require_bin grep
# cursor-agent / claude are gated per selected harness in 3b (agent-harness.sh)
# so a Claude-only deployment is not forced to hold a Cursor key, and vice versa.

# ── 3b. Hard gates: secrets (daemon Ready contract) ───────────────────────
[ -n "${MULTICA_TOKEN:-}" ] || die "Multica auth required: set MULTICA_TOKEN or project config.json under ${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home}"

# Agent CLI harness gate: every harness named by MULTICA_AGENT_CLI must have
# its binary on PATH and a credential in env (Secret files are lifted into env
# by materialize-secrets.sh). Default MULTICA_AGENT_CLI=cursor keeps the exact
# pre-existing boot contract for Cursor-only deployments.
# shellcheck disable=SC1091
source /usr/local/bin/agent-harness.sh
harness_gate || die "agent CLI harness gate failed (MULTICA_AGENT_CLI='${MULTICA_AGENT_CLI:-cursor}')"

[ -f "${MULTICA_HOME:-$HOME/.multica}/daemon.id" ] || [ -n "${MULTICA_DAEMON_ID:-}" ] \
  || die "daemon.id required: project under ${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home} or set MULTICA_DAEMON_ID"

have_git_token=0
[ -n "${GITHUB_TOKEN:-}" ] && have_git_token=1
[ -n "${GITLAB_TOKEN:-}" ] && have_git_token=1
[ -n "${GITEA_TOKEN:-}" ] && have_git_token=1
# GitHub App trio (App ID + installation ID + PEM) satisfies the git gate without a PAT.
have_github_app=0
if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]; then
  if [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ] || [ -f "${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}" ]; then
    have_github_app=1
    have_git_token=1
  fi
fi
# Lowest-priority tier: GitHub Enterprise Server username + password (see configure-git-auth.sh).
if [ -n "${GITHUB_USER:-}" ] && [ -n "${GITHUB_PASSWORD:-}" ]; then
  have_git_token=1
fi
[ "$have_git_token" = 1 ] || die "git HTTPS auth required: set GITHUB_TOKEN and/or GITLAB_TOKEN and/or GITEA_TOKEN, GitHub App credentials (GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + PEM), or GitHub Enterprise Server username + password (GITHUB_USER + GITHUB_PASSWORD) under /run/secrets/git/"

# ── 4. Git credential helper (hard-fail if helper cannot configure) ───────
/usr/local/bin/configure-git-auth.sh

# gh CLI reads GH_TOKEN/GITHUB_TOKEN (+ GH_HOST for GHES) from the daemon
# environment. configure-git-auth.sh writes them to a 0600 file so the token is
# never logged; source it here to hand them to the daemon and child tasks.
GIT_AUTH_ENV="${MULTICA_HOME:-$HOME/.multica}/git-auth.env"
if [ -r "$GIT_AUTH_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$GIT_AUTH_ENV"
  set +a
fi

# ── 4c. AWS credential source (informational only) ────────────────────────
# The image ships AWS CLI + aws-sso with no baked credentials. SDK default chain
# may resolve IRSA / instance role / mounted config; ConfigMap aws-sso profiles
# land via materialize-aws.sh on the workspaces PVC. Log which source wins so
# "Unable to locate credentials" is debuggable from docker logs. Never fatal;
# helper prints no credential values (bin/aws-credential-source.sh).
if [ -x /usr/local/bin/aws-credential-source.sh ]; then
  log "aws auth: $(/usr/local/bin/aws-credential-source.sh 2>/dev/null || printf 'source detection failed')"
fi

# Export Cursor key for cursor-agent (Secret / env-file / file-mount parity).
export CURSOR_API_KEY
# ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_AUTH_TOKEN are
# exported by materialize-secrets.sh and inherited by the daemon, which passes
# them to the Claude Code CLI it spawns. Never logged.

# Resolve workspace ref (UUID / slug / display name) → UUID.
# Returns empty string if unresolved (caller decides whether to die).
resolve_workspace_id() {
  local ref="$1"
  local list id
  [ -n "$ref" ] || return 0

  # UUID (8-4-4-4-12 hex) — use as-is.
  if printf '%s' "$ref" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
    printf '%s\n' "$ref"
    return 0
  fi

  list="$(multica workspace list --output json 2>/dev/null || true)"
  [ -n "$list" ] || return 0

  id="$(printf '%s' "$list" | jq -r --arg ref "$ref" '
    (. // [])
    | map(select(
        (.id // "") == $ref
        or (.slug // "") == $ref
        or ((.name // "") | ascii_downcase) == ($ref | ascii_downcase)
      ))
    | .[0].id // empty
  ' 2>/dev/null || true)"

  printf '%s\n' "$id"
}

# Pin default workspace AFTER login (login can clobber Secret/env workspace).
# Preference: MULTICA_WORKSPACE → MULTICA_WORKSPACE_ID → projected Secret config.json.
pin_workspace_after_login() {
  local desired resolved secret_cfg live
  secret_cfg="${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home}/config.json"

  desired="${MULTICA_WORKSPACE:-}"
  if [ -z "$desired" ]; then
    desired="${MULTICA_WORKSPACE_ID:-}"
  fi
  if [ -z "$desired" ] && [ -f "$secret_cfg" ]; then
    desired="$(jq -r '.workspace_id // empty' "$secret_cfg" 2>/dev/null || true)"
  fi

  if [ -z "$desired" ]; then
    log "workspace pin: no MULTICA_WORKSPACE / MULTICA_WORKSPACE_ID / Secret workspace_id — leaving login default"
    return 0
  fi

  resolved="$(resolve_workspace_id "$desired")"
  if [ -z "$resolved" ]; then
    die "workspace pin: cannot resolve '$desired' to a workspace UUID (check slug/name or MULTICA_WORKSPACE)"
  fi

  multica config set workspace_id "$resolved" || die "workspace pin: multica config set workspace_id failed"
  live="$(jq -r '.workspace_id // empty' "$MULTICA_HOME/config.json" 2>/dev/null || true)"
  if [ "$live" != "$resolved" ]; then
    die "workspace pin: live workspace_id='$live' != intended '$resolved'"
  fi
  log "workspace pin: default workspace_id=$resolved (from '$desired')"
}

# ── 5. Multica activate → exec daemon foreground (no inventory sync) ──────
# Prefer already-projected config.json; only fill gaps from env.
if [ ! -f "${MULTICA_HOME}/config.json" ]; then
  multica config set server_url "$SERVER_URL"
  multica config set app_url "$APP_URL"
  if [ -n "${MULTICA_WORKSPACE:-${MULTICA_WORKSPACE_ID:-}}" ]; then
    # Best-effort pre-login; pin_workspace_after_login is authoritative.
    resolved="$(resolve_workspace_id "${MULTICA_WORKSPACE:-$MULTICA_WORKSPACE_ID}" || true)"
    if [ -n "$resolved" ]; then
      multica config set workspace_id "$resolved"
    fi
  fi
  multica login --token "$MULTICA_TOKEN"
else
  # Ensure URLs from env overlay projected config when provided.
  if [ -n "${MULTICA_SERVER_URL:-}" ]; then
    multica config set server_url "$SERVER_URL" || true
  fi
  if [ -n "${MULTICA_APP_URL:-}" ]; then
    multica config set app_url "$APP_URL" || true
  fi
  # Refresh token into home when MULTICA_TOKEN was supplied via env (not only file).
  if [ -n "${MULTICA_TOKEN:-}" ]; then
    multica login --token "$MULTICA_TOKEN" || true
  fi
fi

# Keep Secret daemon.id authoritative across login side-effects.
if [ -f "${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home}/daemon.id" ]; then
  cp -f "${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home}/daemon.id" "$MULTICA_HOME/daemon.id"
elif [ -n "${MULTICA_DAEMON_ID:-}" ]; then
  printf '%s\n' "$MULTICA_DAEMON_ID" >"$MULTICA_HOME/daemon.id"
fi

# Keep intended workspace authoritative across login side-effects.
pin_workspace_after_login

log "gates passed; starting daemon (id=${MULTICA_DAEMON_ID} machine=${MULTICA_MACHINE_NAME:-<hostname>} home=${MULTICA_HOME} workspaces=${MULTICA_WORKSPACES_ROOT})"

# Ready = this process stays up. No ConfigMap inventory clone-all step.
#
# The daemon's real operational log (task/run activity, not just the boot
# banner) lands in $MULTICA_HOME/daemon.log whenever the process has no
# terminal on stderr — CLI 0.8.0 runDaemonForeground picks its sink that way
# (TTY → its own stderr, non-TTY → the rotating daemon.log) — which is the
# case in every container. Run it as a child and stream
# `multica daemon logs --follow` as the container's foreground process so task
# activity is visible without shelling in to tail files.
daemon_args=(
  --foreground
  --daemon-id "$MULTICA_DAEMON_ID"
  --runtime-name "$MULTICA_AGENT_RUNTIME_NAME"
  --workspaces-root "$MULTICA_WORKSPACES_ROOT"
)
# Only pass --device-name when a machine name was configured; otherwise the CLI
# keeps its own default (OS hostname), which is the right thing for laptops.
if [ -n "${MULTICA_DAEMON_DEVICE_NAME:-}" ]; then
  daemon_args+=(--device-name "$MULTICA_DAEMON_DEVICE_NAME")
fi

multica daemon start "${daemon_args[@]}" &
DAEMON_PID=$!

# Forward termination to the daemon so it can shut down gracefully; tini
# (PID 1) delivers the signal to this script.
forward_term() { kill -TERM "$DAEMON_PID" 2>/dev/null || true; }
trap forward_term TERM INT

# Wait for the daemon to actually come up before attaching the log follower.
#
# `multica daemon status` is a *report*, not an assertion: it prints
# {"status":"stopped"} and still exits 0 when no daemon is running (CLI
# 0.8.0 runDaemonStatus), so testing its exit code passes on the very first
# iteration and waits for nothing. Gate on the status field instead;
# "starting" means the health port answered but preflight is still in flight.
# Bounded, and never fatal while the daemon process itself is alive.
daemon_state="unknown"
for _ in $(seq 1 50); do
  kill -0 "$DAEMON_PID" 2>/dev/null || die "daemon exited during startup"
  status_json="$(multica daemon status --output json 2>/dev/null || true)"
  if [ -n "$status_json" ]; then
    daemon_state="$(printf '%s' "$status_json" | jq -r '.status // "unknown"' 2>/dev/null || printf 'unknown')"
    if [ "$daemon_state" = "running" ]; then
      break
    fi
  fi
  sleep 0.2
done

if [ "$daemon_state" = "running" ]; then
  log "daemon up; streaming daemon logs to container stdout (level=$MULTICA_LOG_LEVEL)"
else
  log "WARN: daemon has not reported status=running after 10s (last state '${daemon_state}') — supervising it anyway; the log stream attaches once ${MULTICA_HOME}/daemon.log exists"
fi

# `multica daemon logs` stats the file first and hard-fails when it is absent
# ("no log file found … may not have been started in background mode"), and the
# file only appears once the daemon has emitted its first record — after auth /
# preflight, i.e. later than the container's first status answer. Wait for it
# (bounded) rather than racing it. A daemon that *does* have a TTY on stderr
# never writes the file at all; then the stream is simply unavailable and boot
# continues, because this container exists to keep the daemon alive, not a tail.
daemon_log="${MULTICA_HOME}/daemon.log"
for _ in $(seq 1 25); do
  if [ -f "$daemon_log" ]; then
    break
  fi
  kill -0 "$DAEMON_PID" 2>/dev/null || die "daemon exited during startup"
  sleep 0.2
done

LOGS_PID=""
if [ -f "$daemon_log" ]; then
  multica daemon logs --follow 2>&1 | /usr/local/bin/log-level-filter.sh "$MULTICA_LOG_LEVEL" &
  LOGS_PID=$!
  # Report a dead stream without taking a healthy daemon down with it (the
  # BOX-94 CrashLoop: the follower's non-zero exit used to be the container's
  # exit, so any log-stream mishap looked like a daemon crash).
  (
    while kill -0 "$DAEMON_PID" 2>/dev/null; do
      if ! kill -0 "$LOGS_PID" 2>/dev/null; then
        log "WARN: daemon log follower exited; container stdout no longer mirrors ${daemon_log} (daemon itself is still supervised)"
        break
      fi
      sleep 5
    done
  ) &
else
  log "WARN: no daemon log at ${daemon_log} after 5s (a daemon attached to a TTY keeps its records on that terminal) — container stdout carries boot output only; MULTICA_LOG_LEVEL=${MULTICA_LOG_LEVEL} filtering is not applied"
fi

# The daemon's exit is the container's exit. Exit (CrashLoop in K8s if
# unexpected) when it dies so a crashed daemon is never masked by a still-live
# tail.
set +e
wait "$DAEMON_PID"
exit_code=$?
set -e
kill "$DAEMON_PID" 2>/dev/null || true
if [ -n "$LOGS_PID" ]; then
  kill "$LOGS_PID" 2>/dev/null || true
fi
exit "$exit_code"
