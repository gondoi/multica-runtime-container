#!/usr/bin/env bash
# Forge HTTPS credential helper (cherry-picked pattern; generic hosts only).
# Writes ~/.git-credentials from env tokens so Multica lazy checkout can use
# HTTPS without interactive prompts.
#
# Env:
#   GITHUB_TOKEN                 → github.com (username x-access-token)
#   GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + PEM
#                                → github.com via App installation token helper
#                                  (preferred over static GITHUB_TOKEN when set)
#   GITLAB_TOKEN + GITLAB_HOST   → GitLab (default host gitlab.com)
#   GITEA_TOKEN  + GITEA_HOST    → Gitea/Forgejo (host required)
#   GITEA_USER                   → optional username (default oauth2)
#
# Exit 1 when no forge tokens / App credentials are present (boot hard-fail).
set -euo pipefail

CRED_FILE="${GIT_CREDENTIALS_FILE:-$HOME/.git-credentials}"
: >"$CRED_FILE"
chmod 600 "$CRED_FILE"
have_git_creds=0
have_github_app=0

if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]; then
  if [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ] || [ -f "${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}" ]; then
    have_github_app=1
  fi
fi

add_git_cred() {
  # $1=host (no scheme)  $2=username  $3=token
  [ -n "${1:-}" ] && [ -n "${3:-}" ] || return 0
  printf 'https://%s:%s@%s\n' "$2" "$3" "$1" >>"$CRED_FILE"
  have_git_creds=1
}

# GitHub App path: live credential helper remints (~1h token lifetime).
# Do NOT put github.com into the store file — store would return a stale seed
# and skip the helper. Seed GH_TOKEN for non-git tools (gh/curl) only.
if [ "$have_github_app" = 1 ]; then
  token="$(/usr/local/bin/mint-github-app-token.sh)" \
    || { echo "FATAL: GitHub App installation token mint failed" >&2; exit 1; }
  export GITHUB_TOKEN="$token"
  export GH_TOKEN="$token"
  have_git_creds=1
  git config --global --unset-all credential.https://github.com.helper 2>/dev/null || true
  git config --global credential.https://github.com.helper \
    '!/usr/local/bin/github-app-credential-helper.sh'
  echo "git HTTPS: GitHub App installation helper configured" >&2
else
  add_git_cred "github.com" "${GITHUB_USER:-x-access-token}" "${GITHUB_TOKEN:-}"
fi

add_git_cred "${GITLAB_HOST:-gitlab.com}" "oauth2" "${GITLAB_TOKEN:-}"
add_git_cred "${GITEA_HOST:-}" "${GITEA_USER:-oauth2}" "${GITEA_TOKEN:-}"

if [ "$have_git_creds" != 1 ]; then
  echo "FATAL: no forge tokens set; git HTTPS auth not configured" >&2
  exit 1
fi

git config --global credential.helper store
# Prefer unambiguous GH_TOKEN for tooling that reads it first.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
fi
echo "git HTTPS credentials configured ($CRED_FILE)" >&2
