#!/usr/bin/env bash
# Collection-side level filter for the multica daemon log stream.
#
# The daemon (CLI 0.8.0) has no log-level knob — no --log-level flag, no
# log-level env, nothing in `multica config set` — and its handler level is
# fixed at debug. So `MULTICA_LOG_LEVEL` cannot change what the daemon emits;
# it only decides which records we mirror to container stdout (`docker logs` /
# `kubectl logs`). ~/.multica/daemon.log keeps every DEBUG line.
#
# Usage: <daemon log stream> | log-level-filter.sh [DEBUG|INFO|WARN|ERROR]
#
# Line shape is zerolog-like: "<time> <LVL> <message> key=value …", with
# TRC/DBG/INF/WRN/ERR/FTL tokens (long names tolerated). Only tokens in the
# first three fields count, so message text that happens to contain "DBG" is
# not mistaken for a level. Lines with no level token (multiline continuations,
# stack traces) are passed through rather than silently dropped.
#
# Implemented with GNU grep --line-buffered: mawk (Debian slim's awk) only
# consumes a pipe once its buffer fills, which stalls a live `--follow`.

set -euo pipefail

level="${1:-${MULTICA_LOG_LEVEL:-INFO}}"
level="$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')"

# Token must sit in one of the first three whitespace-separated fields
# (a timestamp plus the level itself).
token_prefix='^([^[:space:]]+[[:space:]]+){0,2}'

case "$level" in
  DEBUG)
    # Everything, including debug records.
    exec cat
    ;;
  INFO)
    drop='TRC|TRACE|DBG|DEBUG'
    ;;
  WARN)
    drop='TRC|TRACE|DBG|DEBUG|INF|INFO'
    ;;
  ERROR)
    drop='TRC|TRACE|DBG|DEBUG|INF|INFO|WRN|WARN'
    ;;
  *)
    printf 'log-level-filter: invalid level %s (want DEBUG|INFO|WARN|ERROR)\n' "$level" >&2
    exit 2
    ;;
esac

exec grep -E --line-buffered -v "${token_prefix}(${drop})[[:space:]]"
