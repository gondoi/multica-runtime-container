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
#   ${GITHUB_TOKEN_FILE:-/run/secrets/git/GITHUB_TOKEN}
#   ${GITLAB_TOKEN_FILE:-/run/secrets/git/GITLAB_TOKEN}
#   ${GITEA_TOKEN_FILE:-/run/secrets/git/GITEA_TOKEN}
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

# ── Cursor + git token files ──────────────────────────────────────────────
read_secret_file CURSOR_API_KEY "${CURSOR_API_KEY_FILE:-/run/secrets/cursor/CURSOR_API_KEY}"
read_secret_file GITHUB_TOKEN "${GITHUB_TOKEN_FILE:-/run/secrets/git/GITHUB_TOKEN}"
read_secret_file GITLAB_TOKEN "${GITLAB_TOKEN_FILE:-/run/secrets/git/GITLAB_TOKEN}"
read_secret_file GITEA_TOKEN "${GITEA_TOKEN_FILE:-/run/secrets/git/GITEA_TOKEN}"

# Persist daemon.id into Multica home when only env provided (compose convenience).
if [ ! -f "$MULTICA_HOME/daemon.id" ] && [ -n "${MULTICA_DAEMON_ID:-}" ]; then
  printf '%s\n' "$MULTICA_DAEMON_ID" >"$MULTICA_HOME/daemon.id"
  chmod 600 "$MULTICA_HOME/daemon.id" 2>/dev/null || true
fi
