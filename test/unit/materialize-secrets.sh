#!/usr/bin/env bash
# Unit check: bin/materialize-secrets.sh resolves the aws-sso SecureStore
# passphrase from the two supported sources, in the documented precedence, and
# reports which one it used (BOX-124 follow-up).
#
#   1. AWS_SSO_FILE_PASSWORD set directly  → used as-is, source=env
#   2. MULTICA_AWS_SSO_PASSPHRASE_FILE=<path> → read from that file, source=file:<path>
#   3. AWS_SSO_FILE_PASSWORD_FILE (old name) → still honoured, warns, same as (2)
#
# The two names mean different things: AWS_SSO_FILE_PASSWORD is the passphrase,
# MULTICA_AWS_SSO_PASSPHRASE_FILE is a path to a file holding it.
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

export HOME="$WORK/home"
SECRETS="$WORK/secrets"
mkdir -p "$HOME" "$SECRETS/aws-sso"
PW_FILE="$SECRETS/aws-sso/AWS_SSO_FILE_PASSWORD"
printf '%s\n' 'unit-test-passphrase' >"$PW_FILE"

# run_script [ENV=VAL ...] → "<passphrase>|<source>" from the scripted env.
# The script's own stdout/stderr is captured separately (must never leak the value).
run_script() {
  (
    cd "$WORK"
    unset AWS_SSO_FILE_PASSWORD AWS_SSO_FILE_PASSWORD_FILE \
      MULTICA_AWS_SSO_PASSPHRASE_FILE MULTICA_AWS_SSO_PASSPHRASE_SOURCE \
      MULTICA_HOME MULTICA_HOME_SECRET_DIR
    env "$@" bash -c '
      set -uo pipefail
      # shellcheck disable=SC1090
      source "$1" >/dev/null 2>"$2"
      printf "%s|%s" "${AWS_SSO_FILE_PASSWORD:-}" "${MULTICA_AWS_SSO_PASSPHRASE_SOURCE:-}"
    ' _ "$SCRIPT" "$WORK/script.err" 2>/dev/null
  )
}

# 1. Nothing supplied → unset, no source (previous fail-closed behavior).
out="$(run_script "MULTICA_AWS_SSO_PASSPHRASE_FILE=$SECRETS/absent")"
if [ "$out" = "|" ]; then
  ok "no passphrase source → AWS_SSO_FILE_PASSWORD unset, source empty"
else
  bad "unexpected passphrase/source from a missing file: '$out'"
fi

# 2. Direct env (Secret secretKeyRef) → used as-is, source=env.
out="$(run_script "AWS_SSO_FILE_PASSWORD=direct-passphrase")"
if [ "$out" = "direct-passphrase|env" ]; then
  ok "direct AWS_SSO_FILE_PASSWORD honoured with source=env"
else
  bad "direct env not honoured as-is: '$out'"
fi

# 3. Env wins over a file even when both are present.
out="$(run_script "AWS_SSO_FILE_PASSWORD=from-env" \
  "MULTICA_AWS_SSO_PASSPHRASE_FILE=$PW_FILE")"
if [ "$out" = "from-env|env" ]; then
  ok "env value wins over MULTICA_AWS_SSO_PASSPHRASE_FILE"
else
  bad "precedence wrong (env should win): '$out'"
fi

# 4. File wiring under the unambiguous name.
out="$(run_script "MULTICA_AWS_SSO_PASSPHRASE_FILE=$PW_FILE")"
if [ "$out" = "unit-test-passphrase|file:$PW_FILE" ]; then
  ok "MULTICA_AWS_SSO_PASSPHRASE_FILE read + source names the path"
else
  bad "file wiring failed: '$out'"
fi

# 5. Default path (/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD) is documented.
if grep -q '/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD' "$SCRIPT"; then
  ok "default passphrase path documented in script"
else
  bad "default /run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD path missing"
fi

# 6. Deprecated AWS_SSO_FILE_PASSWORD_FILE still works, and warns.
out="$(run_script "AWS_SSO_FILE_PASSWORD_FILE=$PW_FILE")"
if [ "$out" = "unit-test-passphrase|file:$PW_FILE" ]; then
  ok "deprecated AWS_SSO_FILE_PASSWORD_FILE still resolved"
else
  bad "deprecated alias broke: '$out'"
fi
if grep -q 'AWS_SSO_FILE_PASSWORD_FILE is deprecated' "$WORK/script.err" 2>/dev/null; then
  ok "deprecated alias logs a rename warning"
else
  bad "no deprecation warning for AWS_SSO_FILE_PASSWORD_FILE"
  sed -n '1,10p' "$WORK/script.err" >&2 || true
fi

# 7. The new name wins over the deprecated one (both set, no warning).
run_script "MULTICA_AWS_SSO_PASSPHRASE_FILE=$PW_FILE" \
  "AWS_SSO_FILE_PASSWORD_FILE=$SECRETS/absent" >/dev/null
if grep -q 'is deprecated' "$WORK/script.err" 2>/dev/null; then
  bad "warned about the deprecated alias even though the new name was set"
else
  ok "no deprecation warning when MULTICA_AWS_SSO_PASSPHRASE_FILE is set"
fi

# 8. An explicitly configured but unreadable file must be named in the log —
#    otherwise it looks like the variable was silently ignored.
out="$(run_script "MULTICA_AWS_SSO_PASSPHRASE_FILE=$SECRETS/absent/pw")"
if [ "$out" = "|" ] && grep -q 'is missing or empty' "$WORK/script.err" 2>/dev/null; then
  ok "configured-but-missing passphrase file is called out"
else
  bad "no warning for an explicitly configured missing passphrase file ('$out')"
fi

# 9. The passphrase is never printed by the script itself (boot log hygiene).
if grep -q 'unit-test-passphrase' "$WORK/script.err" 2>/dev/null; then
  bad "script leaked the passphrase to stderr"
else
  ok "script never echoes the passphrase"
fi

printf '\n%s/%s checks passed\n' "$pass" "$((pass + fail))"
[ "$fail" = 0 ]
