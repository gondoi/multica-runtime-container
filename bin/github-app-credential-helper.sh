#!/usr/bin/env bash
# Git credential helper that mints a fresh GitHub App installation token on
# `get` for github.com. Used when App credentials are configured so tokens
# refresh across the ~1h installation-token lifetime without pod restart.
#
# Configure (see configure-git-auth.sh):
#   git config --global credential.https://<host>.helper \
#     '!/usr/local/bin/github-app-credential-helper.sh'
#
# Host: GITHUB_HOST (default github.com) — set for GitHub Enterprise Server.
#
# Protocol: https://git-scm.com/docs/gitcredentials
set -euo pipefail

op="${1:-}"
case "$op" in
  get)
    ;;
  store|erase)
    # No persistent store; mint is ephemeral.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

host=""
protocol=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    host=*) protocol_host_set=1; host="${line#host=}" ;;
    protocol=*) protocol="${line#protocol=}" ;;
    '') break ;;
  esac
done

# Only handle the configured GitHub host over https (ignore other hosts / SSH).
if [ "${protocol:-https}" != "https" ]; then
  exit 0
fi
gh_host="${GITHUB_HOST:-github.com}"
case "$host" in
  "$gh_host"|"www.$gh_host") ;;
  *) exit 0 ;;
esac

token="$(/usr/local/bin/mint-github-app-token.sh)" || exit 1
printf 'username=%s\n' "${GITHUB_USER:-x-access-token}"
printf 'password=%s\n' "$token"
