#!/usr/bin/env bash
# gh CLI entrypoint wrapper — installed as /usr/local/bin/gh; the upstream
# binary stays at /usr/local/bin/gh-real.
#
# Why a wrapper: GitHub App installation tokens expire after ~1 hour, so a token
# seeded into the daemon environment at boot goes stale mid-session. Re-minting
# per invocation keeps `gh` usable for as long as the git credential helper is.
# PAT / password tiers have nothing to refresh — the wrapper just execs gh.
#
# Env:
#   GH_REAL_BIN          real gh binary (default /usr/local/bin/gh-real)
#   GITHUB_APP_MINT_BIN  installation-token mint script
#                        (default /usr/local/bin/mint-github-app-token.sh)
#   GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY[_FILE]
#                        App tier credentials (see configure-git-auth.sh)
#   GH_TOKEN/GITHUB_TOKEN  fallback when no App credentials are present
set -euo pipefail

real="${GH_REAL_BIN:-/usr/local/bin/gh-real}"
mint="${GITHUB_APP_MINT_BIN:-/usr/local/bin/mint-github-app-token.sh}"

# Local-only subcommands never need a token: skip the mint round-trip.
case "${1:-}" in
  --version|-v|help|--help|completion) exec "$real" "$@" ;;
esac

app_ready() {
  [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] || return 1
  [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ] \
    || [ -s "${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}" ]
}

if app_ready && [ -x "$mint" ]; then
  # On mint failure fall through with whatever token the environment already
  # has (possibly a still-valid boot token) instead of failing the command.
  if token="$("$mint" 2>/dev/null)"; then
    export GH_TOKEN="$token"
    export GITHUB_TOKEN="$token"
  fi
fi

exec "$real" "$@"
