#!/usr/bin/env bash
# Scaffold entrypoint. Full boot contract (hard gates → git auth →
# `exec multica daemon start --foreground`) lands in a later slice.
#
# Behaviour today:
#   - optional .env source (compose / secret file mount)
#   - optional forge HTTPS helper when tokens are present
#   - with MULTICA_TOKEN: login + daemon foreground (minimal path)
#   - without MULTICA_TOKEN: interactive shell / passed command
set -euo pipefail

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

if [ -n "${GITHUB_TOKEN:-}${GITLAB_TOKEN:-}${GITEA_TOKEN:-}" ]; then
  /usr/local/bin/configure-git-auth.sh || true
fi

if [ -z "${MULTICA_TOKEN:-}" ]; then
  echo "No MULTICA_TOKEN set — starting an interactive shell instead of the daemon." >&2
  echo "For headless daemon mode: docker run -e MULTICA_TOKEN=mul_... multica-runtime" >&2
  exec "${@:-bash}"
fi

SERVER_URL="${MULTICA_SERVER_URL:-https://api.multica.ai}"
APP_URL="${MULTICA_APP_URL:-https://multica.ai}"

multica config set server_url "$SERVER_URL"
multica config set app_url "$APP_URL"

if [ -n "${MULTICA_WORKSPACE_ID:-}" ]; then
  multica config set workspace_id "$MULTICA_WORKSPACE_ID"
fi

multica login --token "$MULTICA_TOKEN"
exec multica daemon start --foreground
