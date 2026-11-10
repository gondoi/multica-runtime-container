#!/usr/bin/env bash
# Materialize Secret-projected Multica home + provider tokens into the
# container-local filesystem / environment.
#
# Multica home is NOT a PVC. Identity (`config.json` + `daemon.id`) comes from
# a Secret (or compose bind-mount of the same layout). The daemon still needs a
# writable `$MULTICA_HOME` for logs/lock/pid, so we copy projected files into
# an ephemeral directory under $HOME.
#
# Layout (compose + K8s mount parity):
#   ${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home}/config.json
#   ${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home}/daemon.id
#   ${CURSOR_API_KEY_FILE:-/run/secrets/cursor/CURSOR_API_KEY}
#   ${ANTHROPIC_API_KEY_FILE:-/run/secrets/claude/ANTHROPIC_API_KEY}
#   ${CLAUDE_CODE_OAUTH_TOKEN_FILE:-/run/secrets/claude/CLAUDE_CODE_OAUTH_TOKEN}
#   ${ANTHROPIC_AUTH_TOKEN_FILE:-/run/secrets/claude/ANTHROPIC_AUTH_TOKEN}
#   ${OPENAI_API_KEY_FILE:-/run/secrets/codex/OPENAI_API_KEY}
#   ${CODEX_AUTH_JSON_FILE:-/run/secrets/codex/auth.json}
#   ${GITHUB_TOKEN_FILE:-/run/secrets/git/GITHUB_TOKEN}
#   ${GITHUB_USER_FILE:-/run/secrets/git/GITHUB_USER}
#   ${GITHUB_PASSWORD_FILE:-/run/secrets/git/GITHUB_PASSWORD}
#   ${GITHUB_HOST_FILE:-/run/secrets/git/GITHUB_HOST}
#   ${GITLAB_TOKEN_FILE:-/run/secrets/git/GITLAB_TOKEN}
#   ${GITEA_TOKEN_FILE:-/run/secrets/git/GITEA_TOKEN}
#   ${GITHUB_APP_ID_FILE:-/run/secrets/git/GITHUB_APP_ID}
#   ${GITHUB_APP_INSTALLATION_ID_FILE:-/run/secrets/git/GITHUB_APP_INSTALLATION_ID}
#   ${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}
#   ${AWS_SSO_FILE_PASSWORD_FILE:-/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD}
#
# Env vars already set win over files. Exit 1 on unrecoverable misconfig.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

read_secret_file() {
  # $1=var name  $2=path — export var from file when unset/empty and file exists.
  local var="$1" path="$2" val
  if [ -n "${!var:-}" ]; then
    return 0
  fi
  if [ -f "$path" ]; then
    val="$(tr -d '\r\n' <"$path")"
    if [ -n "$val" ]; then
      printf -v "$var" '%s' "$val"
      export "$var"
    fi
  fi
}

MULTICA_HOME="${MULTICA_HOME:-$HOME/.multica}"
SECRET_DIR="${MULTICA_HOME_SECRET_DIR:-/run/secrets/multica-home}"
export MULTICA_HOME

mkdir -p "$MULTICA_HOME"
chmod 700 "$MULTICA_HOME" 2>/dev/null || true

# ── Multica home projection → ephemeral writable copy ────────────────────
if [ -f "$SECRET_DIR/config.json" ]; then
  cp -f "$SECRET_DIR/config.json" "$MULTICA_HOME/config.json"
  chmod 600 "$MULTICA_HOME/config.json" 2>/dev/null || true
  log "multica home: projected config.json → $MULTICA_HOME/config.json"
fi

if [ -f "$SECRET_DIR/daemon.id" ]; then
  cp -f "$SECRET_DIR/daemon.id" "$MULTICA_HOME/daemon.id"
  chmod 600 "$MULTICA_HOME/daemon.id" 2>/dev/null || true
  # Prefer Secret identity over env default when MULTICA_DAEMON_ID unset.
  if [ -z "${MULTICA_DAEMON_ID:-}" ]; then
    MULTICA_DAEMON_ID="$(tr -d '\r\n' <"$MULTICA_HOME/daemon.id")"
    export MULTICA_DAEMON_ID
  fi
  log "multica home: projected daemon.id → $MULTICA_HOME/daemon.id"
fi

# If config.json carries a token and MULTICA_TOKEN is unset, lift it for gates.
if [ -z "${MULTICA_TOKEN:-}" ] && [ -f "$MULTICA_HOME/config.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    tok="$(jq -r '.token // empty' "$MULTICA_HOME/config.json" 2>/dev/null || true)"
    if [ -n "$tok" ] && [ "$tok" != "null" ]; then
      export MULTICA_TOKEN="$tok"
    fi
  fi
fi

# ── Cursor + git token / GitHub App files ─────────────────────────────────
# (Claude Code + OpenAI Codex harness credentials are read in the blocks below.)
read_secret_file CURSOR_API_KEY "${CURSOR_API_KEY_FILE:-/run/secrets/cursor/CURSOR_API_KEY}"
# ── Claude Code harness credentials (one of the three satisfies the gate) ──
# API key (long-lived secret) or OAuth token from `claude setup-token`; the
# third is the bearer token used with a gateway (pair with ANTHROPIC_BASE_URL,
# which is non-secret plain env, not a file). Lifted into env only — the daemon
# passes them to the Claude Code CLI it spawns and they are never logged.
read_secret_file ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY_FILE:-/run/secrets/claude/ANTHROPIC_API_KEY}"
read_secret_file CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN_FILE:-/run/secrets/claude/CLAUDE_CODE_OAUTH_TOKEN}"
read_secret_file ANTHROPIC_AUTH_TOKEN "${ANTHROPIC_AUTH_TOKEN_FILE:-/run/secrets/claude/ANTHROPIC_AUTH_TOKEN}"
# ── OpenAI Codex harness credentials ─────────────────────────────────────
# Codex authenticates from $CODEX_HOME/auth.json, NOT from OPENAI_API_KEY
# (verified against codex-cli 0.167.0 — see bin/agent-harness.sh). Two inputs:
#   OPENAI_API_KEY  an API key; agent-harness.sh turns it into auth.json via
#                   `codex login --with-api-key` once the harness is selected.
#   auth.json       a login already created with `codex login` (API key or
#                   ChatGPT OAuth). Projected here so the daemon's per-task
#                   CODEX_HOME mirror finds it; never logged.
read_secret_file OPENAI_API_KEY "${OPENAI_API_KEY_FILE:-/run/secrets/codex/OPENAI_API_KEY}"
_codex_auth_src="${CODEX_AUTH_JSON_FILE:-/run/secrets/codex/auth.json}"
if [ -f "$_codex_auth_src" ]; then
  _codex_home="${CODEX_HOME:-$HOME/.codex}"
  if mkdir -p "$_codex_home" 2>/dev/null; then
    cp -f "$_codex_auth_src" "$_codex_home/auth.json"
    chmod 600 "$_codex_home/auth.json" 2>/dev/null || true
    log "codex: projected auth.json → $_codex_home/auth.json"
  else
    log "WARN: codex: cannot create '$_codex_home'; the mounted auth.json was not projected (OPENAI_API_KEY still works)"
  fi
fi
unset _codex_auth_src _codex_home
read_secret_file GITHUB_TOKEN "${GITHUB_TOKEN_FILE:-/run/secrets/git/GITHUB_TOKEN}"
# GitHub Enterprise Server password tier (lowest priority) + host selector.
read_secret_file GITHUB_USER "${GITHUB_USER_FILE:-/run/secrets/git/GITHUB_USER}"
read_secret_file GITHUB_PASSWORD "${GITHUB_PASSWORD_FILE:-/run/secrets/git/GITHUB_PASSWORD}"
read_secret_file GITHUB_HOST "${GITHUB_HOST_FILE:-/run/secrets/git/GITHUB_HOST}"
read_secret_file GITLAB_TOKEN "${GITLAB_TOKEN_FILE:-/run/secrets/git/GITLAB_TOKEN}"
read_secret_file GITEA_TOKEN "${GITEA_TOKEN_FILE:-/run/secrets/git/GITEA_TOKEN}"
read_secret_file GITHUB_APP_ID "${GITHUB_APP_ID_FILE:-/run/secrets/git/GITHUB_APP_ID}"
read_secret_file GITHUB_APP_INSTALLATION_ID \
  "${GITHUB_APP_INSTALLATION_ID_FILE:-/run/secrets/git/GITHUB_APP_INSTALLATION_ID}"
# PEM may be multi-line — read raw file into env when unset (keep newlines).
if [ -z "${GITHUB_APP_PRIVATE_KEY:-}" ]; then
  _app_pem_path="${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}"
  if [ -f "$_app_pem_path" ]; then
    GITHUB_APP_PRIVATE_KEY="$(cat "$_app_pem_path")"
    export GITHUB_APP_PRIVATE_KEY
  fi
  unset _app_pem_path
fi
# Always export file path for mint script (file mount preferred over env echo).
export GITHUB_APP_PRIVATE_KEY_FILE="${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}"

# ── aws-sso SecureStore passphrase (file backend unlock) ──────────────────
# aws-sso's `file` SecureStore encrypts the token/role cache with a passphrase
# and asks for it on every process that opens the store. Agent tasks have no
# TTY, so `credential_process` (`aws-sso process`) can only unlock it
# non-interactively from AWS_SSO_FILE_PASSWORD — the upstream-documented env var
# (aws-sso-cli 2.1.0: internal/storage/keyring.go, `fileKeyringPassword`).
# Optional: unset keeps the previous fail-closed behavior (agents see
# "Enter passphrase to unlock …" then "Must run `aws-sso login`"). The value is
# never logged and is inherited by tasks like the other provider secrets.
read_secret_file AWS_SSO_FILE_PASSWORD \
  "${AWS_SSO_FILE_PASSWORD_FILE:-/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD}"

# Persist daemon.id into Multica home when only env provided (compose convenience).
if [ ! -f "$MULTICA_HOME/daemon.id" ] && [ -n "${MULTICA_DAEMON_ID:-}" ]; then
  printf '%s\n' "$MULTICA_DAEMON_ID" >"$MULTICA_HOME/daemon.id"
  chmod 600 "$MULTICA_HOME/daemon.id" 2>/dev/null || true
fi
