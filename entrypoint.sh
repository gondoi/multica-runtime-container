#!/usr/bin/env bash
# Multica runtime home-base boot contract (minimal / Multica-native):
#   1. Source config / helpers
#   2. Materialize Secret-projected Multica home + Cursor/git tokens
#   3. Hard-fail gates (required binaries + Multica/Cursor/git-auth secrets)
#   4. Configure git HTTPS credential helper
#   5. login → pin workspace (env/Secret) → exec multica daemon start --foreground
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
# GitHub App trio (App ID + installation ID + PEM) satisfies the git gate without a PAT.
have_github_app=0
if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]; then
  if [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ] || [ -f "${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}" ]; then
    have_github_app=1
    have_git_token=1
  fi
fi
[ "$have_git_token" = 1 ] || die "git HTTPS auth required: set GITHUB_TOKEN and/or GITLAB_TOKEN and/or GITEA_TOKEN, or GitHub App credentials (GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + PEM) under /run/secrets/git/"

# ── 4. Git credential helper (hard-fail if helper cannot configure) ───────
/usr/local/bin/configure-git-auth.sh

# Export Cursor key for cursor-agent (Secret / env-file / file-mount parity).
export CURSOR_API_KEY

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

log "gates passed; starting daemon (id=${MULTICA_DAEMON_ID} home=${MULTICA_HOME} workspaces=${MULTICA_WORKSPACES_ROOT})"
# Ready = this process stays up. No ConfigMap inventory clone-all step.
exec multica daemon start \
  --foreground \
  --daemon-id "$MULTICA_DAEMON_ID" \
  --runtime-name "$MULTICA_AGENT_RUNTIME_NAME" \
  --workspaces-root "$MULTICA_WORKSPACES_ROOT"
