#!/usr/bin/env bash
# Conventional Commits gate — the input Release Please parses.
#
# Release Please builds the CHANGELOG and picks the next version purely from
# commit subjects on `main`. A subject it cannot parse is silently dropped from
# the changelog and can swallow a `feat` (no release PR at all), so this gate
# fails instead of letting the next release go quiet.
#
# Merge commits are ignored (they carry no release meaning), as are
# `Revert "..."` subjects produced by `git revert`.
#
# Usage (from repo root):
#   ./test/ci/check-conventional-commits.sh [<git-rev-range>]
#
# Default range is `origin/main..HEAD` when that ref exists, else `HEAD~1..HEAD`.
set -euo pipefail

TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'
# <type>(<scope>)!?: <summary>  — scope and breaking marker optional.
SUBJECT_RE="^(${TYPES})(\([A-Za-z0-9._/-]+\))?!?: .+$"
REVERT_RE='^Revert ".+"$'
SEP=$'\x1f'

range="${1:-}"
if [ -z "$range" ]; then
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    range="origin/main..HEAD"
  elif git rev-parse --verify -q 'HEAD~1' >/dev/null 2>&1; then
    range="HEAD~1..HEAD"
  else
    range="HEAD"
  fi
fi

if ! git log -1 --format=%H "$range" >/dev/null 2>&1; then
  printf 'Conventional commits: cannot resolve range %s\n' "$range" >&2
  exit 2
fi

checked=0
violations=0

while IFS="$SEP" read -r sha parents subject; do
  [ -n "$sha" ] || continue
  # Merge commit: its parents' history is checked as its own commits.
  case "$parents" in
    *" "*) continue ;;
  esac
  checked=$((checked + 1))
  if [[ "$subject" =~ $SUBJECT_RE ]] || [[ "$subject" =~ $REVERT_RE ]]; then
    continue
  fi
  violations=$((violations + 1))
  printf '::error::%s non-conventional commit subject: %s\n' "${sha:0:8}" "$subject"
done < <(git log --no-decorate --format="%H${SEP}%P${SEP}%s" "$range")

if [ "$violations" -ne 0 ]; then
  printf '\nConventional commits: %d of %d commit(s) invalid (range %s)\n' \
    "$violations" "$checked" "$range" >&2
  printf '  expected: <type>(<scope>): <summary>\n' >&2
  printf '  types:    %s\n' "${TYPES//|/, }" >&2
  printf '  example:  feat(release): publish images on semver tags\n' >&2
  exit 1
fi

printf 'Conventional commits: %d commit(s) OK (range %s)\n' "$checked" "$range"
