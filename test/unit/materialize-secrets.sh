#!/usr/bin/env bash
# Unit check: bin/materialize-secrets.sh lifts the aws-sso SecureStore passphrase
# from its mounted Secret file into AWS_SSO_FILE_PASSWORD (BOX-124), so a
# non-TTY agent task's `credential_process` can unlock the encrypted file store.
#
# No network, no real secrets — a throwaway HOME and a fake passphrase file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/materialize-secrets.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

[ -r "$SCRIPT" ] || { bad "missing $SCRIPT"; exit 1; }

# Isolated HOME + secret tree: the caller's real secrets must never leak in.
export HOME="$WORK/home"
SECRETS="$WORK/secrets"
mkdir -p "$HOME" "$SECRETS"

# run_script [ENV=VAL ...] → prints the exported AWS_SSO_FILE_PASSWORD (may be
# empty) on the last line; earlier lines are the script's own output (stdout +
# stderr, which must never contain the passphrase).
run_script() {
  (
    cd "$WORK"
    unset AWS_SSO_FILE_PASSWORD AWS_SSO_FILE_PASSWORD_FILE \
      MULTICA_HOME MULTICA_HOME_SECRET_DIR
    env "$@" bash -c '
      set -uo pipefail
      # shellcheck disable=SC1090
      source "$1" >/dev/null 2>"$2"
      printf "%s" "${AWS_SSO_FILE_PASSWORD:-}"
    ' _ "$SCRIPT" "$WORK/script.err" 2>/dev/null
  )
}

secret_of() { run_script "$@" | tail -1; }

# 1. No secret file → unset (previous fail-closed behavior preserved).
out="$(secret_of "AWS_SSO_FILE_PASSWORD_FILE=$SECRETS/absent")"
if [ -z "$out" ]; then
  ok "no passphrase file → AWS_SSO_FILE_PASSWORD unset"
else
  bad "unexpected passphrase from a missing file: '$out'"
fi

# 2. Mounted passphrase file → exported verbatim, trailing newline stripped.
mkdir -p "$SECRETS/aws-sso"
printf '%s\n' 'unit-test-passphrase' >"$SECRETS/aws-sso/AWS_SSO_FILE_PASSWORD"
out="$(secret_of "AWS_SSO_FILE_PASSWORD_FILE=$SECRETS/aws-sso/AWS_SSO_FILE_PASSWORD")"
if [ "$out" = "unit-test-passphrase" ]; then
  ok "mounted passphrase file lifted into AWS_SSO_FILE_PASSWORD"
else
  bad "expected the file value, got '$out'"
fi

# 3. Default mount path (/run/secrets/aws-sso/…) — exercised via the override
#    contract only; the default path cannot exist in a unit run. Assert the
#    documented default is what the script names.
if grep -q '/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD' "$SCRIPT"; then
  ok "default passphrase path documented in script"
else
  bad "default /run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD path missing"
fi

# 4. An env value already set wins over the file (compose/.env escape hatch).
out="$(secret_of "AWS_SSO_FILE_PASSWORD=from-env" \
  "AWS_SSO_FILE_PASSWORD_FILE=$SECRETS/aws-sso/AWS_SSO_FILE_PASSWORD")"
if [ "$out" = "from-env" ]; then
  ok "env value wins over the mounted file"
else
  bad "env value did not win: '$out'"
fi

# 5. The passphrase is never printed by the script itself (boot log hygiene).
if grep -q 'unit-test-passphrase' "$WORK/script.err" 2>/dev/null; then
  bad "script leaked the passphrase to stderr"
else
  ok "script never echoes the passphrase"
fi

printf '\n%s/%s checks passed\n' "$pass" "$((pass + fail))"
[ "$fail" = 0 ]
