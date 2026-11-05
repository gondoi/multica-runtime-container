#!/usr/bin/env bash
# Forge HTTPS credential helper (cherry-picked pattern; generic hosts only).
# Writes ~/.git-credentials from env tokens so Multica lazy checkout can use
# HTTPS without interactive prompts.
#
# GitHub auth tiers — resolved in this order, first COMPLETE tier wins (most →
# least secure for managed credentials):
#   1. app       GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + PEM
#                → live credential helper, remints every ~1h installation token
#   2. token     GITHUB_TOKEN (static PAT / fine-grained token)
#                → static store entry, username GITHUB_USER or x-access-token
#   3. password  GITHUB_USER + GITHUB_PASSWORD
#                → static store entry, percent-encoded (git decodes on read)
#
# Env:
#   GITHUB_HOST                  → GitHub host for tiers 1-3 (default github.com)
#   GITHUB_AUTH_TIER             → force one tier (app|token|password). Unset =
#                                  automatic precedence; a forced but incomplete
#                                  tier is a hard error, never a silent fallback.
#   GITLAB_TOKEN + GITLAB_HOST   → GitLab (default host gitlab.com)
#   GITEA_TOKEN  + GITEA_HOST    → Gitea/Forgejo (host required)
#   GITEA_USER                   → optional username (default oauth2)
#
# Also writes ${MULTICA_HOME:-$HOME/.multica}/git-auth.env (0600) with
# GH_TOKEN/GITHUB_TOKEN/GH_HOST so the daemon environment — and therefore the
# `gh` CLI — is authenticated for the resolved tier without ever logging the
# token. The entrypoint sources that file.
#
# Exit 1 when no forge tokens / App credentials are present (boot hard-fail).
#
# Password tier note: github.com removed password (basic) auth for git-over-HTTPS
# in Aug 2021, so a lone GITHUB_PASSWORD against github.com is a hard error here
# rather than a silent no-op that fails later at clone time. The tier is
# meaningful for GitHub Enterprise Server, selected with GITHUB_HOST.
set -euo pipefail

CRED_FILE="${GIT_CREDENTIALS_FILE:-$HOME/.git-credentials}"
GH_ENV_FILE="${GIT_AUTH_ENV_FILE:-${MULTICA_HOME:-$HOME/.multica}/git-auth.env}"
have_git_creds=0

log() { printf '%s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

github_host() {
  local host="${GITHUB_HOST:-github.com}"
  host="${host#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  printf '%s' "${host:-github.com}"
}

github_app_complete() {
  [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] || return 1
  [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ] \
    || [ -s "${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}" ]
}

github_password_complete() {
  [ -n "${GITHUB_USER:-}" ] && [ -n "${GITHUB_PASSWORD:-}" ]
}

# Which GitHub auth tier applies. Prints: app | token | password | none
github_auth_method() {
  if github_app_complete; then
    printf 'app\n'
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    printf 'token\n'
  elif github_password_complete; then
    printf 'password\n'
  else
    printf 'none\n'
  fi
}

github_tier_complete() {
  case "$1" in
    app) github_app_complete ;;
    token) [ -n "${GITHUB_TOKEN:-}" ] ;;
    password) github_password_complete ;;
    *) return 1 ;;
  esac
}

github_tier_requirements() {
  case "$1" in
    app) printf 'GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + private key PEM' ;;
    token) printf 'GITHUB_TOKEN' ;;
    password) printf 'GITHUB_USER + GITHUB_PASSWORD' ;;
  esac
}

# Resolved tier: explicit GITHUB_AUTH_TIER wins over automatic precedence.
resolve_github_method() {
  local forced
  forced="$(printf '%s' "${GITHUB_AUTH_TIER:-}" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$forced" ]; then
    github_auth_method
    return 0
  fi
  case "$forced" in
    app|token|password) ;;
    *) die "GITHUB_AUTH_TIER='${GITHUB_AUTH_TIER}' is invalid; use app, token, or password" ;;
  esac
  github_tier_complete "$forced" \
    || die "GITHUB_AUTH_TIER=${forced} was forced but that tier is incomplete: needs $(github_tier_requirements "$forced")"
  printf '%s\n' "$forced"
}

uri_encode() {
  # $1=raw → RFC 3986 percent-encoded; git percent-decodes credential URLs.
  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg v "$1" '$v|@uri'
  else
    printf '%s' "$1"
  fi
}

# $1=host (no scheme). This runtime ships no SSH key, so a `git@<host>:` or
# `ssh://git@<host>/` remote can only hang trying auth it can never complete —
# rewrite it to the HTTPS form we do have credentials for. Scoped to hosts we
# actually configure credentials for (the repo(s) being worked on), not every
# possible git host.
force_https_for_host() {
  [ -n "${1:-}" ] || return 0
  git config --global --add url."https://$1/".insteadOf "git@$1:"
  git config --global --add url."https://$1/".insteadOf "ssh://git@$1/"
}

add_git_cred() {
  # $1=host (no scheme)  $2=username  $3=token/password
  [ -n "${1:-}" ] && [ -n "${3:-}" ] || return 0
  printf 'https://%s:%s@%s\n' "$2" "$3" "$1" >>"$CRED_FILE"
  have_git_creds=1
  force_https_for_host "$1"
}

# gh CLI auth view for the daemon environment. Written 0600, sourced by the
# entrypoint; nothing here is ever logged. Password tier has no token to seed.
write_gh_env() {
  # $1=token ("" for the password tier)
  local token="${1:-}" host
  host="$(github_host)"
  mkdir -p "$(dirname "$GH_ENV_FILE")"
  : >"$GH_ENV_FILE"
  chmod 600 "$GH_ENV_FILE"
  [ -n "$token" ] || return 0
  {
    printf 'GH_TOKEN=%q\n' "$token"
    printf 'GITHUB_TOKEN=%q\n' "$token"
    if [ "$host" != "github.com" ]; then
      printf 'GH_HOST=%q\n' "$host"
    fi
  } >"$GH_ENV_FILE"
}

# Tier 1: GitHub App — live credential helper remints (~1h token lifetime).
# Do NOT put the App host into the store file — store would return a stale seed
# and skip the helper. Seed GH_TOKEN for non-git tools (gh/curl) only.
configure_github_app() {
  local host token
  host="$(github_host)"
  token="$(/usr/local/bin/mint-github-app-token.sh)" \
    || die "GitHub App installation token mint failed"
  export GITHUB_TOKEN="$token"
  export GH_TOKEN="$token"
  have_git_creds=1
  git config --global --unset-all "credential.https://${host}.helper" 2>/dev/null || true
  git config --global "credential.https://${host}.helper" \
    '!/usr/local/bin/github-app-credential-helper.sh'
  force_https_for_host "$host"
  write_gh_env "$token"
  log "git HTTPS: GitHub App installation helper configured (host=${host}); gh CLI auth via per-invocation mint"
}

# Tier 2: static PAT / fine-grained token.
configure_github_token() {
  local host
  host="$(github_host)"
  add_git_cred "$host" "${GITHUB_USER:-x-access-token}" "${GITHUB_TOKEN:-}"
  write_gh_env "${GITHUB_TOKEN:-}"
  log "git HTTPS: static GITHUB_TOKEN configured (host=${host}); gh CLI auth via GH_TOKEN"
}

# Tier 3: username + password (GitHub Enterprise Server; see header note).
configure_github_password() {
  local host
  host="$(github_host)"
  case "$host" in
    github.com|www.github.com)
      die "GITHUB_PASSWORD set but ${host} no longer accepts password auth for git-over-HTTPS (removed 2021-08): set GITHUB_TOKEN or the GitHub App trio, or point GITHUB_HOST at a GitHub Enterprise Server host"
      ;;
  esac
  add_git_cred "$host" "$(uri_encode "$GITHUB_USER")" "$(uri_encode "$GITHUB_PASSWORD")"
  write_gh_env ""
  log "git HTTPS: GitHub password auth configured (host=${host}, lowest-priority tier); gh CLI has no token for this tier"
}

main() {
  local method
  : >"$CRED_FILE"
  chmod 600 "$CRED_FILE"
  write_gh_env ""

  method="$(resolve_github_method)"
  case "$method" in
    app) configure_github_app ;;
    token) configure_github_token ;;
    password) configure_github_password ;;
    *) write_gh_env "" ;;
  esac
  [ "$method" = none ] || log "git HTTPS: GitHub auth tier=${method}${GITHUB_AUTH_TIER:+ (forced by GITHUB_AUTH_TIER)}"

  add_git_cred "${GITLAB_HOST:-gitlab.com}" "oauth2" "${GITLAB_TOKEN:-}"
  add_git_cred "${GITEA_HOST:-}" "${GITEA_USER:-oauth2}" "${GITEA_TOKEN:-}"

  if [ "$have_git_creds" != 1 ]; then
    die "no forge tokens set; git HTTPS auth not configured (want GITHUB_TOKEN, the GitHub App trio, GITHUB_USER+GITHUB_PASSWORD for GitHub Enterprise Server, or GITLAB_TOKEN/GITEA_TOKEN)"
  fi

  git config --global credential.helper store

  # Defense in depth: this image has no SSH key, so force_https_for_host above
  # already rewrites every forge host we configure credentials for. Any SSH
  # git invocation that still slips through (an unconfigured host, or a task
  # repo URL we don't rewrite) must fail fast instead of hanging forever on a
  # blocked/filtered connection — it can never complete auth anyway.
  git config --global core.sshCommand "ssh -o ConnectTimeout=10 -o BatchMode=yes"

  # Prefer unambiguous GH_TOKEN for tooling that reads it first.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
  fi
  log "git HTTPS credentials configured ($CRED_FILE)"
}

# Allow unit tests to source the tier predicates without side effects.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
