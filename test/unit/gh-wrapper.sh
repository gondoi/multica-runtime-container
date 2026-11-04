#!/usr/bin/env bash
# Unit check: bin/gh-wrapper.sh — installed as /usr/local/bin/gh.
#
# Covers: arg passthrough, the local-only fast path (no mint round-trip), App
# tier re-mint (GH_TOKEN refreshed per invocation), and mint-failure fallback to
# the token already in the environment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$ROOT/bin/gh-wrapper.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

chmod +x "$WRAPPER"

# Fake real-gh: reports the args it got plus the token it would use.
cat >"$WORK/gh-real" <<'EOF'
#!/usr/bin/env bash
printf 'REAL_GH args=[%s] token=%s\n' "$*" "${GH_TOKEN:-unset}"
EOF
# Fake mint: prints a token, or fails when MINT_FAIL=1; records invocations.
cat >"$WORK/mint" <<'EOF'
#!/usr/bin/env bash
echo "mint-called" >>"${MINT_LOG:?}"
[ "${MINT_FAIL:-0}" = 1 ] && exit 1
printf 'ghs_refreshed_token'
EOF
chmod +x "$WORK/gh-real" "$WORK/mint"

export GH_REAL_BIN="$WORK/gh-real"
export GITHUB_APP_MINT_BIN="$WORK/mint"
export MINT_LOG="$WORK/mint.log"
: >"$MINT_LOG"

clear_gh_env() {
  unset GH_TOKEN GITHUB_TOKEN GITHUB_HOST \
    GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_PRIVATE_KEY_FILE \
    MINT_FAIL
}

run_wrapper() {
  # Usage: run_wrapper [VAR=value ...] -- <args>
  local assigns=()
  while [ "$1" != "--" ]; do assigns+=("$1"); shift; done
  shift
  (
    clear_gh_env
    for a in "${assigns[@]}"; do export "$a"; done
    "$WRAPPER" "$@"
  )
}

echo "==> Pass-through (no App credentials)"

out="$(run_wrapper -- pr list --repo gondoi/multica-runtime)"
if [ "$out" = "REAL_GH args=[pr list --repo gondoi/multica-runtime] token=unset" ]; then
  ok "no App creds: execs real gh with unchanged args"
else
  bad "no App creds: unexpected output '$out'"
fi

out="$(run_wrapper GH_TOKEN=ghp_pat -- pr list)"
if [ "$out" = "REAL_GH args=[pr list] token=ghp_pat" ]; then
  ok "no App creds: PAT in env reaches gh untouched"
else
  bad "no App creds: PAT not passed through ('$out')"
fi

if [ ! -s "$MINT_LOG" ]; then
  ok "no App creds: mint never invoked"
else
  bad "no App creds: mint was invoked"
fi

echo "==> Local-only fast path"

: >"$MINT_LOG"
out="$(run_wrapper GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PRIVATE_KEY=dummy -- --version)"
if [ "$out" = "REAL_GH args=[--version] token=unset" ] && [ ! -s "$MINT_LOG" ]; then
  ok "--version: passthrough without a mint round-trip"
else
  bad "--version: unexpected output '$out' or mint called unnecessarily"
fi

echo "==> App tier re-mint"

: >"$MINT_LOG"
out="$(run_wrapper GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PRIVATE_KEY=dummy -- pr view 3)"
if [ "$out" = "REAL_GH args=[pr view 3] token=ghs_refreshed_token" ] \
  && grep -qx mint-called "$MINT_LOG"; then
  ok "App creds: fresh installation token exported to gh"
else
  bad "App creds: expected fresh token, got '$out'"
fi

echo "==> Mint failure falls back"

: >"$MINT_LOG"
out="$(run_wrapper GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PRIVATE_KEY=dummy GH_TOKEN=ghs_boot_token MINT_FAIL=1 -- pr list)"
if [ "$out" = "REAL_GH args=[pr list] token=ghs_boot_token" ]; then
  ok "mint failure: existing boot token still used"
else
  bad "mint failure: expected boot token fallback, got '$out'"
fi

echo
echo "gh-wrapper: $pass passed, $fail failed"
[ "$fail" = 0 ]
