#!/usr/bin/env bash
# Forge HTTPS credential helper (cherry-picked pattern; generic hosts only).
# Writes ~/.git-credentials from env tokens so Multica lazy checkout can use
# HTTPS without interactive prompts.
#
# Env:
#   GITHUB_TOKEN                 → github.com (username x-access-token)
#   GITLAB_TOKEN + GITLAB_HOST   → GitLab (default host gitlab.com)
#   GITEA_TOKEN  + GITEA_HOST    → Gitea/Forgejo (host required)
#   GITEA_USER                   → optional username (default oauth2)
#
# Exit 1 when no forge tokens are present (boot hard-fail policy).
set -euo pipefail

CRED_FILE="${GIT_CREDENTIALS_FILE:-$HOME/.git-credentials}"
: >"$CRED_FILE"
chmod 600 "$CRED_FILE"
have_git_creds=0

add_git_cred() {
  # $1=host (no scheme)  $2=username  $3=token
  [ -n "${1:-}" ] && [ -n "${3:-}" ] || return 0
  printf 'https://%s:%s@%s\n' "$2" "$3" "$1" >>"$CRED_FILE"
  have_git_creds=1
}

add_git_cred "github.com" "${GITHUB_USER:-x-access-token}" "${GITHUB_TOKEN:-}"
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
