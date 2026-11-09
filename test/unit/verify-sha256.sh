#!/usr/bin/env bash
# Unit check: bin/verify-sha256.sh — the fail-closed gate used by the pinned
# tarball installs in the Dockerfile (multica-cli, cursor-agent).
#
# Covers: matching hash passes, wrong hash fails, missing/empty/malformed hash
# fails, missing artifact fails — and that the failure path never leaves the
# artifact "accepted" (exit code is all the Dockerfile RUN layer sees).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$ROOT/bin/verify-sha256.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

chmod +x "$VERIFY"

printf 'pinned artifact contents\n' >"$WORK/artifact.tgz"
good="$(sha256sum "$WORK/artifact.tgz" | cut -d' ' -f1)"

# expect_fail <description> <args...>
expect_fail() {
  local desc="$1"
  shift
  if "$VERIFY" "$@" >"$WORK/out" 2>&1; then
    bad "$desc (exited 0)"
    sed -n '1,5p' "$WORK/out" | sed 's/^/      /'
  else
    ok "$desc (fail-closed)"
  fi
}

echo "==> Matching checksum"
if "$VERIFY" "$WORK/artifact.tgz" "$good" "test artifact"; then
  ok "matching SHA-256 accepted"
else
  bad "matching SHA-256 rejected"
fi

echo "==> Mismatch"
if "$VERIFY" "$WORK/artifact.tgz" \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "test artifact" >"$WORK/out" 2>&1; then
  bad "mismatched SHA-256 accepted"
else
  grep -q 'SHA-256 mismatch' "$WORK/out" && ok "mismatched SHA-256 rejected with a clear message" \
    || bad "mismatched SHA-256 rejected without the expected message"
fi

echo "==> Tampered artifact (hash pinned to pre-tamper bytes)"
cp "$WORK/artifact.tgz" "$WORK/tampered.tgz"
printf 'injected\n' >>"$WORK/tampered.tgz"
expect_fail "tampered artifact rejected" "$WORK/tampered.tgz" "$good" "test artifact"

echo "==> Missing / malformed pin"
expect_fail "empty checksum rejected" "$WORK/artifact.tgz" "" "test artifact"
expect_fail "unset checksum rejected" "$WORK/artifact.tgz" "test artifact"
expect_fail "short checksum rejected" "$WORK/artifact.tgz" "abc123" "test artifact"
expect_fail "non-hex checksum rejected" "$WORK/artifact.tgz" \
  "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" "test artifact"

echo "==> Missing artifact"
expect_fail "missing artifact rejected" "$WORK/nope.tgz" "$good" "test artifact"

echo
if [ "$fail" -eq 0 ]; then
  printf 'verify-sha256: all %d checks passed\n' "$pass"
else
  printf 'verify-sha256: %d of %d checks FAILED\n' "$fail" "$((pass + fail))" >&2
fi
[ "$fail" -eq 0 ]
