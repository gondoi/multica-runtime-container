#!/usr/bin/env bash
# Unit runner: every test/unit/*.sh executable, no Docker, no network.
#
# Usage (from repo root):
#   ./test/unit/run-unit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0

for t in "$ROOT"/test/unit/*.sh; do
  [ -e "$t" ] || continue
  [ "$(basename "$t")" = "run-unit.sh" ] && continue
  echo "==> $(basename "$t")"
  chmod +x "$t"
  if "$t"; then
    :
  else
    fail=1
  fi
done

if [ "$fail" = 0 ]; then
  echo
  echo "Unit: all suites passed"
else
  echo
  echo "Unit: FAILURES (see above)" >&2
fi
[ "$fail" = 0 ]
