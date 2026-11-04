#!/usr/bin/env bash
# Unit check: test/ci/check-conventional-commits.sh — the Release Please input gate.
#
# Covers: valid type/scope/breaking subjects, non-conventional subjects rejected
# (issue-key prefix, bare word, uppercase type, empty summary), merge commits
# skipped, `Revert "..."` allowed, empty range OK, unresolvable range errors.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/test/ci/check-conventional-commits.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

chmod +x "$GATE"

# Hermetic git: no user/system config, no signing, fixed identity.
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: >"$GIT_CONFIG_GLOBAL"

REPO="$WORK/repo"
git init -q "$REPO"
cd "$REPO"
git config user.name "Test"
git config user.email "test@example.com"
git config commit.gpgsign false
MAIN="$(git symbolic-ref --short HEAD)"

commit() { git commit -q --allow-empty -m "$1"; }
OUT=""
RC=0
run_gate() {
  set +e
  OUT=$("$GATE" ${1:+"$1"} 2>&1)
  RC=$?
  set -e
}
expect_rc() { # expect_rc <want-rc> <label> [range]
  run_gate "${3:-}"
  if [ "$RC" = "$1" ]; then
    ok "$2 (rc=$RC)"
  else
    bad "$2 (rc=$RC, want $1)"
    printf '%s\n' "$OUT" >&2
  fi
}

commit "chore: initial"
base="$(git rev-parse HEAD)"

echo "==> valid subjects"
commit "feat(ci): add release-please config"
commit "fix: gate non-conventional commit subjects"
commit "chore(main)!: drop sha image tags"
commit 'Revert "feat: throwaway experiment"'
expect_rc 0 "valid type/scope/breaking/revert subjects pass" "$base..HEAD"

echo "==> merge commits"
git checkout -q -b topic
commit "feat(release): tag images from semver releases"
git checkout -q "$MAIN"
git merge -q --no-ff topic -m "Merge branch 'topic' into main"
expect_rc 0 "merge commit subject ignored" "$base..HEAD"
mark="$(git rev-parse HEAD)"

echo "==> rejected subjects"
for subject in \
  "BOX-89: add release please" \
  "wip" \
  "Feat: uppercase type" \
  "feat(ci):" \
  "fix ci missing colon"
do
  commit "$subject"
  range="$(git rev-parse HEAD)~1..HEAD"
  run_gate "$range"
  if [ "$RC" = 1 ]; then
    if printf '%s' "$OUT" | grep -qF "$subject"; then
      ok "rejected: $subject (rc=1, subject echoed)"
    else
      bad "rejected but subject not echoed: $subject"
      printf '%s\n' "$OUT" >&2
    fi
  else
    bad "accepted non-conventional subject: $subject (rc=$RC)"
    printf '%s\n' "$OUT" >&2
  fi
done

echo "==> ranges"
commit "docs: document the release flow"
expect_rc 0 "empty range passes" "HEAD..HEAD"
expect_rc 2 "unresolvable range errors out" "does-not-exist..HEAD"
expect_rc 0 "default range (no argument) passes" ""

# A mixed range must still fail as a whole.
expect_rc 1 "mixed range fails on the bad commit" "$mark..HEAD"

echo
echo "Conventional commits gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
