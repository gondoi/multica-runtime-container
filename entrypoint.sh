#!/usr/bin/env bash
# Multica runtime home-base boot contract (minimal / Multica-native):
#   1. Source config / helpers
#   2. Materialize Secret-projected Multica home + Cursor/git tokens
#   3. Hard-fail gates (required binaries + Multica/Cursor/git-auth secrets)
#   4. Configure git HTTPS credential helper
#   5. exec multica daemon start --foreground
#
# Ready = daemon is up after gates. There is NO boot-time inventory sync —
# repos materialize lazily via `multica repo checkout` during tasks.
#
# Multica home (`config.json` + `daemon.id`) comes from Secret projection
# (or compose bind-mount of the same layout). There is NO Multica-home PVC —
# only the workspaces volume is durable.
#
# Missing secrets or binaries → non-zero exit (CrashLoop in K8s).
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

SERVER_URL="${MULTICA_SERVER_URL:-https://api.multica.ai}"
APP_URL="${MULTICA_APP_URL:-https://multica.ai}"

# ── 2. Secret projection → ephemeral Multica home + token env ─────────────
# shellcheck disable=SC1091
source /usr/local/bin/materialize-secrets.sh

export MULTICA_DAEMON_ID="${MULTICA_DAEMON_ID:-$MULTICA_AGENT_RUNTIME_NAME}"

# ── 3. Hard gates: binaries ───────────────────────────────────────────────
require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary not on PATH: $1"
}

require_bin multica
require_bin cursor-agent
require_bin git
require_bin jq
require_bin curl
require_bin asdf

# ── 3b. Hard gates: secrets (daemon Ready contract) ───────────────────────
[ -n "${MULTICA_TOKEN:-}" ] || die "Multica auth required: set MULTICA_TOKEN or project config.json under ${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home}"
[ -n "${CURSOR_API_KEY:-}" ] || die "CURSOR_API_KEY is required (env or ${CURSOR_API_KEY_FILE:-/run/secrets/cursor/CURSOR_API_KEY})"
[ -f "${MULTICA_HOME:-$HOME/.multica}/daemon.id" ] || [ -n "${MULTICA_DAEMON_ID:-}" ] \
  || die "daemon.id required: project under ${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home} or set MULTICA_DAEMON_ID"

have_git_token=0
[ -n "${GITHUB_TOKEN:-}" ] && have_git_token=1
[ -n "${GITLAB_TOKEN:-}" ] && have_git_token=1
[ -n "${GITEA_TOKEN:-}" ] && have_git_token=1
[ "$have_git_token" = 1 ] || die "git HTTPS auth required: set GITHUB_TOKEN and/or GITLAB_TOKEN and/or GITEA_TOKEN (env or /run/secrets/git/*)"

# ── 4. Git credential helper (hard-fail if helper cannot configure) ───────
/usr/local/bin/configure-git-auth.sh

# Export Cursor key for cursor-agent (Secret / env-file / file-mount parity).
export CURSOR_API_KEY

# ── 5. Multica activate → exec daemon foreground (no inventory sync) ──────
# Prefer already-projected config.json; only fill gaps from env.
if [ ! -f "${MULTICA_HOME}/config.json" ]; then
  multica config set server_url "$SERVER_URL"
  multica config set app_url "$APP_URL"
  if [ -n "${MULTICA_WORKSPACE_ID:-}" ]; then
    multica config set workspace_id "$MULTICA_WORKSPACE_ID"
  fi
  multica login --token "$MULTICA_TOKEN"
else
  # Ensure URLs / workspace from env overlay projected config when provided.
  if [ -n "${MULTICA_SERVER_URL:-}" ]; then
    multica config set server_url "$SERVER_URL" || true
  fi
  if [ -n "${MULTICA_APP_URL:-}" ]; then
    multica config set app_url "$APP_URL" || true
  fi
  if [ -n "${MULTICA_WORKSPACE_ID:-}" ]; then
    multica config set workspace_id "$MULTICA_WORKSPACE_ID" || true
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

log "gates passed; starting daemon (id=${MULTICA_DAEMON_ID} home=${MULTICA_HOME} workspaces=${MULTICA_WORKSPACES_ROOT})"
# Ready = this process stays up. No ConfigMap inventory clone-all step.
exec multica daemon start \
  --foreground \
  --daemon-id "$MULTICA_DAEMON_ID" \
  --runtime-name "$MULTICA_AGENT_RUNTIME_NAME" \
  --workspaces-root "$MULTICA_WORKSPACES_ROOT"
