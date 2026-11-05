#!/usr/bin/env bash
# Shallow readiness probe: daemon process is up.
# Not an inventory / full-tree gate — first-task cold clone is expected.
set -euo pipefail

# Foreground daemon is PID 1's child under tini, or the main process when
# entrypoint exec'd it. Prefer Multica's own status when available.
#
# `multica daemon status` is a report, not an assertion: it prints
# {"status":"stopped"} and still exits 0 when nothing is running (CLI 0.8.0
# runDaemonStatus), so its exit code alone would make this probe always
# Ready — including when the daemon is gone, which also blinds the liveness
# probe. Read the status field instead. "starting" counts as alive (the health
# port answered, preflight is in flight): this probe answers "is a daemon
# process here", and treating a slow preflight as dead would make the
# liveness probe restart a daemon that is still coming up.
if status_json="$(multica daemon status --output json 2>/dev/null)"; then
  state="$(printf '%s' "$status_json" | jq -r '.status // empty' 2>/dev/null || true)"
  case "$state" in
    running | starting) exit 0 ;;
  esac
  if [ -n "$state" ]; then
    # The CLI answered and named a state that is not a live daemon.
    exit 1
  fi
fi

# Fallbacks below only run when the status payload could not be read at all
# (stub / no procps / no jq) — never to override a daemon that reported
# stopped, which is how this probe used to report Ready forever.

# A multica daemon process is alive (covers stub / early boot).
if pgrep -f '[m]ultica daemon' >/dev/null 2>&1; then
  exit 0
fi

# Last resort without procps: readable ready stamp written by boot tests / stubs.
if [ -f "${MULTICA_READY_FILE:-/tmp/multica-runtime.ready}" ]; then
  exit 0
fi

exit 1
