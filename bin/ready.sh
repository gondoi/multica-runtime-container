#!/usr/bin/env bash
# Shallow readiness probe: daemon process is up.
# Not an inventory / full-tree gate — first-task cold clone is expected.
set -euo pipefail

# Foreground daemon is PID 1's child under tini, or the main process when
# entrypoint exec'd it. Prefer Multica's own status when available.
if multica daemon status --output json >/dev/null 2>&1; then
  exit 0
fi

# Fallback: a multica daemon process is alive (covers stub / early boot).
if pgrep -f '[m]ultica daemon' >/dev/null 2>&1; then
  exit 0
fi

# Last resort without procps: readable ready stamp written by boot tests / stubs.
if [ -f "${MULTICA_READY_FILE:-/tmp/multica-runtime.ready}" ]; then
  exit 0
fi

exit 1
