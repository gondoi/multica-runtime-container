#!/usr/bin/env bash
# Agent CLI harness selection + boot gates.
#
# Division of labour (important): the *Multica CLI* owns harness invocation and
# protocol handling — its `daemon start` spawns the selected CLI per run, speaks
# that CLI's stream protocol (Claude Code stream-json, cursor-agent, …) and
# parses the results. This image is the home-base: it only has to make the
# selected harness's *binary* and *credentials* available on PATH / in the
# daemon environment.
#
# Harnesses provisioned by this image:
#
#   cursor   cursor-agent   CURSOR_API_KEY
#   claude   claude         ANTHROPIC_API_KEY | CLAUDE_CODE_OAUTH_TOKEN | ANTHROPIC_AUTH_TOKEN
#
# Selection: MULTICA_AGENT_CLI — comma and/or space separated, default `cursor`
# (previous behaviour, so existing deployments keep their exact boot contract).
#
#   MULTICA_AGENT_CLI=cursor           # Cursor only (default)
#   MULTICA_AGENT_CLI=claude           # Claude Code only
#   MULTICA_AGENT_CLI=cursor,claude    # both must be usable
#
# Every selected harness is a HARD boot gate: missing binary or missing
# credential → non-zero exit → CrashLoop, exactly like the old Cursor-only gate.
# Harnesses *not* selected are ignored (their binaries may still ship in the
# image; the daemon simply cannot run tasks for them without credentials).
#
# Note: MULTICA_AGENT_CLI is this container's provision/gate selector, not the
# daemon's per-run harness switch — the harness for a given run comes from the
# agent definition on the Multica server. It only guarantees the CLI that runs
# will actually be present and authenticated in here.
#
# Sourced by entrypoint.sh (functions only); also runnable standalone to
# validate the current environment. Unit-tested by test/unit/agent-harness.sh.
#
# shellcheck shell=bash

harness_log() { printf '%s\n' "$*" >&2; }

# Known harness names, one per line.
harness_known() { printf '%s\n' cursor claude; }

harness_is_known() {
  case "${1:-}" in
    cursor|claude) return 0 ;;
    *) return 1 ;;
  esac
}

# Executable name for a harness.
harness_bin_name() {
  case "${1:-}" in
    cursor) printf 'cursor-agent\n' ;;
    claude) printf 'claude\n' ;;
    *) return 1 ;;
  esac
}

# Binary the daemon will spawn for a harness, honouring the daemon's own path
# overrides (MULTICA_CURSOR_PATH / MULTICA_CLAUDE_PATH) when the operator set
# them explicitly.
harness_bin_path() {
  case "${1:-}" in
    cursor) printf '%s\n' "${MULTICA_CURSOR_PATH:-$(harness_bin_name cursor)}" ;;
    claude) printf '%s\n' "${MULTICA_CLAUDE_PATH:-$(harness_bin_name claude)}" ;;
    *) return 1 ;;
  esac
}

# Credential variables accepted for a harness (message text only).
harness_cred_vars() {
  case "${1:-}" in
    cursor) printf 'CURSOR_API_KEY\n' ;;
    claude) printf 'ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_AUTH_TOKEN\n' ;;
    *) return 1 ;;
  esac
}

# Are credentials present in the environment? Secret file mounts are already
# lifted into env by materialize-secrets.sh before this runs, so env-only checks
# cover both mount and env-file paths.
harness_creds_ok() {
  case "${1:-}" in
    cursor) [ -n "${CURSOR_API_KEY:-}" ] ;;
    claude)
      [ -n "${ANTHROPIC_API_KEY:-}" ] \
        || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
        || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]
      ;;
    *) return 1 ;;
  esac
}

# Selected harnesses, one per line, deduped. Returns non-zero on an unknown name
# so callers can fail the boot with a message naming the offender.
harness_selected() {
  local raw h seen=" "
  raw="${MULTICA_AGENT_CLI:-cursor}"
  raw="${raw//,/ }"
  for h in $raw; do
    h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
    if ! harness_is_known "$h"; then
      harness_log "harness: unknown name '$h'"
      return 1
    fi
    case "$seen" in
      *" $h "*) continue ;;
    esac
    seen="$seen$h "
    printf '%s\n' "$h"
  done
}

# Export the env the daemon needs to spawn the selected harness(es):
#   - MULTICA_<CLI>_PATH pinned to the resolved absolute path (daemon-spawned
#     children get the same binary the gate proved)
#   - DISABLE_AUTOUPDATER=1 for claude: the image pins one Claude Code version
#     and the non-root runtime user cannot self-update that path anyway; an
#     attempted update would drift from the pin or fail mid-run.
harness_export_env() {
  local h path
  for h in "$@"; do
    case "$h" in
      cursor)
        path="$(harness_bin_path cursor)"
        [ -n "${MULTICA_CURSOR_PATH:-}" ] || export MULTICA_CURSOR_PATH="$(command -v "$path" 2>/dev/null || printf '%s' "$path")"
        ;;
      claude)
        path="$(harness_bin_path claude)"
        [ -n "${MULTICA_CLAUDE_PATH:-}" ] || export MULTICA_CLAUDE_PATH="$(command -v "$path" 2>/dev/null || printf '%s' "$path")"
        export DISABLE_AUTOUPDATER="${DISABLE_AUTOUPDATER:-1}"
        ;;
    esac
  done
}

# Gate every selected harness (binary + credentials). Returns non-zero after
# printing every problem found, so one boot surfaces all missing pieces.
harness_gate() {
  local h path out rc=0
  local -a selected=()

  if ! out="$(harness_selected)"; then
    harness_log "FATAL: MULTICA_AGENT_CLI must list one or more of: $(harness_known | tr '\n' ' ')"
    return 1
  fi
  if [ -z "$out" ]; then
    harness_log "FATAL: MULTICA_AGENT_CLI is empty; expected one or more of: $(harness_known | tr '\n' ' ')"
    return 1
  fi
  mapfile -t selected <<<"$out"

  for h in "${selected[@]}"; do
    path="$(harness_bin_path "$h")"
    if ! command -v "$path" >/dev/null 2>&1; then
      harness_log "FATAL: required binary not on PATH: $path (harness '$h'; build with INSTALL_CLAUDE_CLI=true for claude)"
      rc=1
      continue
    fi
    if ! harness_creds_ok "$h"; then
      harness_log "FATAL: $h harness auth required: set $(harness_cred_vars "$h") (env or the matching Secret file mount under /run/secrets/)"
      rc=1
      continue
    fi
    harness_log "harness $h: ok ($path, credentials present)"
  done

  [ "$rc" = 0 ] || return 1

  harness_export_env "${selected[@]}"
  harness_log "agent harnesses: ${selected[*]}"
  return 0
}

# Standalone use: ./agent-harness.sh → validate and print the selection.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  harness_gate
fi
