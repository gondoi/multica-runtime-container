#!/usr/bin/env bash
# Multica runtime home-base boot contract (minimal / Multica-native):
#   1. Source config / helpers
#   2. Hard-fail gates (required binaries + Multica/Cursor/git-auth secrets)
#   3. Configure git HTTPS credential helper
#   4. exec multica daemon start --foreground
#
# Ready = daemon is up after gates. There is NO boot-time inventory sync —
# repos materialize lazily via `multica repo checkout` during tasks.
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
export MULTICA_DAEMON_ID="${MULTICA_DAEMON_ID:-$MULTICA_AGENT_RUNTIME_NAME}"
export MULTICA_WORKSPACES_ROOT="${MULTICA_WORKSPACES_ROOT:-/home/agent/workspaces}"
mkdir -p "$MULTICA_WORKSPACES_ROOT"

SERVER_URL="${MULTICA_SERVER_URL:-https://api.multica.ai}"
APP_URL="${MULTICA_APP_URL:-https://multica.ai}"

# ── 2. Hard gates: binaries ───────────────────────────────────────────────
require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary not on PATH: $1"
}

require_bin multica
require_bin cursor-agent
require_bin git
require_bin jq
require_bin curl
require_bin asdf

# ── 2b. Hard gates: secrets (daemon Ready contract) ───────────────────────
[ -n "${MULTICA_TOKEN:-}" ] || die "MULTICA_TOKEN is required (Multica PAT)"
[ -n "${CURSOR_API_KEY:-}" ] || die "CURSOR_API_KEY is required (Cursor agent)"

have_git_token=0
[ -n "${GITHUB_TOKEN:-}" ] && have_git_token=1
[ -n "${GITLAB_TOKEN:-}" ] && have_git_token=1
[ -n "${GITEA_TOKEN:-}" ] && have_git_token=1
[ "$have_git_token" = 1 ] || die "git HTTPS auth required: set GITHUB_TOKEN and/or GITLAB_TOKEN and/or GITEA_TOKEN"

# ── 3. Git credential helper (hard-fail if helper cannot configure) ───────
/usr/local/bin/configure-git-auth.sh

# Export Cursor key for cursor-agent (Secret / env-file mount parity).
export CURSOR_API_KEY

# ── 4. Multica activate → exec daemon foreground (no inventory sync) ──────
multica config set server_url "$SERVER_URL"
multica config set app_url "$APP_URL"

if [ -n "${MULTICA_WORKSPACE_ID:-}" ]; then
  multica config set workspace_id "$MULTICA_WORKSPACE_ID"
fi

multica login --token "$MULTICA_TOKEN"

log "gates passed; starting daemon (id=${MULTICA_DAEMON_ID} workspaces=${MULTICA_WORKSPACES_ROOT})"
# Ready = this process stays up. No ConfigMap inventory clone-all step.
exec multica daemon start \
  --foreground \
  --daemon-id "$MULTICA_DAEMON_ID" \
  --runtime-name "$MULTICA_AGENT_RUNTIME_NAME" \
  --workspaces-root "$MULTICA_WORKSPACES_ROOT"
