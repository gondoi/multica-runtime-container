#!/usr/bin/env bash
# Unit check: configure-git-auth.sh GitHub auth precedence (App > PAT > password)
# and the credential-store output for each tier.
#
# No network, no real tokens, no mint: the App tier is only exercised through the
# tier-resolution predicate (mint itself is covered by mint-github-app-token.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/configure-git-auth.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

chmod +x "$SCRIPT"

# Isolated home/git state: never touch the caller's ~/.gitconfig or credentials.
export HOME="$WORK/home"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CREDENTIALS_FILE="$WORK/git-credentials"
mkdir -p "$HOME"
: >"$GIT_CONFIG_GLOBAL"
: >"$GIT_CREDENTIALS_FILE"

# Stand-in App PEM (existence only — no tier test here mints a token).
printf 'dummy-pem\n' >"$WORK/app.pem"

clear_git_env() {
  unset GITHUB_TOKEN GITHUB_USER GITHUB_PASSWORD GITHUB_HOST \
    GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_PRIVATE_KEY_FILE \
    GITLAB_TOKEN GITLAB_HOST GITEA_TOKEN GITEA_HOST GITEA_USER GH_TOKEN
}

method_of() {
  # Usage: method_of [VAR=value ...] → resolved tier (app|token|password|none)
  (
    clear_git_env
    for assign in "$@"; do export "$assign"; done
    # shellcheck disable=SC1090
    source "$SCRIPT" >/dev/null 2>&1
    github_auth_method
  )
}

check_method() {
  local expected="$1" label="$2" got
  shift 2
  got="$(method_of "$@")"
  if [ "$got" = "$expected" ]; then
    ok "tier precedence: $label → $expected"
  else
    bad "tier precedence: $label → got '$got' want '$expected'"
  fi
}

run_script() {
  # Usage: run_script [VAR=value ...] — runs the real script, output → $WORK/out
  (
    clear_git_env
    for assign in "$@"; do export "$assign"; done
    "$SCRIPT" >"$WORK/out" 2>&1
  )
}

creds() { cat "$GIT_CREDENTIALS_FILE"; }

echo "==> Tier resolution"

check_method app "App trio + PAT + password" \
  GITHUB_APP_ID=42 GITHUB_APP_INSTALLATION_ID=99 \
  GITHUB_APP_PRIVATE_KEY_FILE="$WORK/app.pem" \
  GITHUB_TOKEN=ghp_unit GITHUB_USER=agent GITHUB_PASSWORD=pw \
  GITHUB_HOST=ghes.unit.invalid
check_method token "App pair without PEM falls back to PAT" \
  GITHUB_APP_ID=42 GITHUB_APP_INSTALLATION_ID=99 \
  GITHUB_APP_PRIVATE_KEY_FILE="$WORK/missing.pem" GITHUB_TOKEN=ghp_unit
check_method token "PAT + password (no App)" \
  GITHUB_TOKEN=ghp_unit GITHUB_USER=agent GITHUB_PASSWORD=pw
check_method password "password only" \
  GITHUB_USER=agent GITHUB_PASSWORD=pw GITHUB_HOST=ghes.unit.invalid
check_method password "App pair without PEM falls through to password" \
  GITHUB_APP_ID=42 GITHUB_APP_INSTALLATION_ID=99 \
  GITHUB_APP_PRIVATE_KEY_FILE="$WORK/missing.pem" \
  GITHUB_USER=agent GITHUB_PASSWORD=pw GITHUB_HOST=ghes.unit.invalid
check_method none "nothing set"
check_method none "password without username is incomplete" GITHUB_PASSWORD=pw
check_method none "App IDs without key or PAT" \
  GITHUB_APP_ID=42 GITHUB_APP_INSTALLATION_ID=99 \
  GITHUB_APP_PRIVATE_KEY_FILE="$WORK/missing.pem"

echo "==> Credential store output"

# Tier 2: PAT wins over a co-present password tier (GITHUB_HOST applies to both).
: >"$GIT_CREDENTIALS_FILE"
if run_script GITHUB_TOKEN=ghp_unit_pat GITHUB_USER=agent GITHUB_PASSWORD=pw \
  GITHUB_HOST=ghes.unit.invalid; then
  if [ "$(creds)" = "https://agent:ghp_unit_pat@ghes.unit.invalid" ]; then
    ok "PAT tier: store has PAT for the configured host, password tier ignored"
  else
    bad "PAT tier wrote unexpected credentials: $(creds)"
  fi
else
  bad "PAT tier exited non-zero"
  sed -n 1,10p "$WORK/out" >&2
fi

# Default PAT username stays x-access-token.
: >"$GIT_CREDENTIALS_FILE"
if run_script GITHUB_TOKEN=ghp_unit_pat; then
  if [ "$(creds)" = "https://x-access-token:ghp_unit_pat@github.com" ]; then
    ok "PAT tier: default username x-access-token"
  else
    bad "PAT tier default username wrong: $(creds)"
  fi
else
  bad "PAT tier (no username) exited non-zero"
  sed -n 1,10p "$WORK/out" >&2
fi

# Tier 3: GHES username + password, percent-encoded on disk, decoded by git.
: >"$GIT_CREDENTIALS_FILE"
if run_script GITHUB_HOST=ghes.unit.invalid GITHUB_USER=agent GITHUB_PASSWORD='p@ss:word'; then
  if grep -Fq 'https://agent:p%40ss%3Aword@ghes.unit.invalid' "$GIT_CREDENTIALS_FILE"; then
    ok "password tier: percent-encoded store line for GHES host"
  else
    bad "password tier store line unexpected: $(creds)"
  fi
  filled="$(printf 'protocol=https\nhost=ghes.unit.invalid\n\n' \
    | GIT_TERMINAL_PROMPT=0 git -c "credential.helper=store --file=$GIT_CREDENTIALS_FILE" credential fill 2>/dev/null || true)"
  if printf '%s\n' "$filled" | grep -qx 'password=p@ss:word' \
    && printf '%s\n' "$filled" | grep -qx 'username=agent'; then
    ok "password tier: git decodes the stored password back to the raw value"
  else
    bad "password tier: git could not read back credentials: $(printf '%s' "$filled" | tr '\n' ' ')"
  fi
  if grep -qF 'p@ss:word' "$WORK/out"; then
    bad "password tier: raw GITHUB_PASSWORD leaked to script output"
  else
    ok "password tier: raw password never echoed"
  fi
else
  bad "password tier (GHES host) exited non-zero"
  sed -n 1,10p "$WORK/out" >&2
fi

# github.com rejects password auth → hard fail at boot, not a silent no-op.
: >"$GIT_CREDENTIALS_FILE"
if run_script GITHUB_USER=agent GITHUB_PASSWORD=pw; then
  bad "password tier on github.com should exit non-zero"
else
  if grep -q 'no longer accepts password auth' "$WORK/out" \
    && [ ! -s "$GIT_CREDENTIALS_FILE" ]; then
    ok "password tier on github.com: actionable fatal, no credentials written"
  else
    bad "password tier on github.com: wrong failure output"
    sed -n 1,10p "$WORK/out" >&2
  fi
fi

# No forge auth at all → boot hard-fail (unchanged contract).
if run_script; then
  bad "no-auth case should exit non-zero"
else
  if grep -q 'no forge tokens set' "$WORK/out"; then
    ok "no GitHub auth: fatal with actionable message"
  else
    bad "no-auth case: unexpected output"
    sed -n 1,10p "$WORK/out" >&2
  fi
fi

# Non-GitHub forges still work untouched by the tier logic.
: >"$GIT_CREDENTIALS_FILE"
if run_script GITLAB_TOKEN=glpat_unit; then
  if [ "$(creds)" = "https://oauth2:glpat_unit@gitlab.com" ]; then
    ok "GitLab-only path unchanged"
  else
    bad "GitLab-only path wrote unexpected credentials: $(creds)"
  fi
else
  bad "GitLab-only path exited non-zero"
  sed -n 1,10p "$WORK/out" >&2
fi

echo
echo "configure-git-auth: $pass passed, $fail failed"
[ "$fail" = 0 ]
