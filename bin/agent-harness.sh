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
#   codex    codex          OPENAI_API_KEY (→ $CODEX_HOME/auth.json) | a pre-provisioned auth.json
#
# Selection: MULTICA_AGENT_CLI — comma and/or space separated, default `cursor`
# (previous behaviour, so existing deployments keep their exact boot contract).
#
#   MULTICA_AGENT_CLI=cursor                  # Cursor only (default)
#   MULTICA_AGENT_CLI=claude                  # Claude Code only
#   MULTICA_AGENT_CLI=codex                   # OpenAI Codex only
#   MULTICA_AGENT_CLI=cursor,claude,codex     # all three must be usable
#
# Every selected harness is a HARD boot gate: missing binary or missing
# credential → non-zero exit → CrashLoop, exactly like the old Cursor-only gate.
# Harnesses *not* selected are ignored by the gate, and after the gate passes
# their binaries are *masked* out of the PATH the daemon (and every task it
# spawns) inherits — see "Masking unselected harnesses from PATH" below. The
# image ships cursor-agent, claude and codex unconditionally, so masking is what
# keeps a Cursor-only deployment from advertising a Claude or Codex harness it
# never configured.
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
harness_known() { printf '%s\n' cursor claude codex; }

harness_is_known() {
  case "${1:-}" in
    cursor|claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

# Executable name for a harness.
harness_bin_name() {
  case "${1:-}" in
    cursor) printf 'cursor-agent\n' ;;
    claude) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    *) return 1 ;;
  esac
}

# Binary the daemon will spawn for a harness, honouring the daemon's own path
# overrides (MULTICA_CURSOR_PATH / MULTICA_CLAUDE_PATH / MULTICA_CODEX_PATH)
# when the operator set them explicitly.
harness_bin_path() {
  case "${1:-}" in
    cursor) printf '%s\n' "${MULTICA_CURSOR_PATH:-$(harness_bin_name cursor)}" ;;
    claude) printf '%s\n' "${MULTICA_CLAUDE_PATH:-$(harness_bin_name claude)}" ;;
    codex) printf '%s\n' "${MULTICA_CODEX_PATH:-$(harness_bin_name codex)}" ;;
    *) return 1 ;;
  esac
}

# Credential variables accepted for a harness (message text only).
harness_cred_vars() {
  case "${1:-}" in
    cursor) printf 'CURSOR_API_KEY\n' ;;
    claude) printf 'ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_AUTH_TOKEN\n' ;;
    codex) printf 'OPENAI_API_KEY (or a pre-provisioned $CODEX_HOME/auth.json)\n' ;;
    *) return 1 ;;
  esac
}

# Codex's credential/config directory. Codex itself reads CODEX_HOME, and the
# daemon mirrors this directory into each task's own CODEX_HOME, so the auth
# file has to live here (default ~/.codex). CODEX_HOME is never exported by this
# image: the daemon sets it per task.
harness_codex_home() { printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"; }
harness_codex_auth_json() { printf '%s\n' "$(harness_codex_home)/auth.json"; }

# Are credentials present in the environment? Secret file mounts are already
# lifted into env by materialize-secrets.sh before this runs, so env-only checks
# cover both mount and env-file paths. codex is the exception: codex-cli 0.167.0
# ignores OPENAI_API_KEY in the environment (verified — it sends no bearer and
# fails with "Missing bearer or basic authentication"), and authenticates from
# $CODEX_HOME/auth.json. So for codex either the key (which provision_auth turns
# into auth.json) or an already-provisioned auth.json satisfies the gate.
harness_creds_ok() {
  case "${1:-}" in
    cursor) [ -n "${CURSOR_API_KEY:-}" ] ;;
    claude)
      [ -n "${ANTHROPIC_API_KEY:-}" ] \
        || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
        || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]
      ;;
    codex)
      if [ -n "${OPENAI_API_KEY:-}" ]; then
        return 0
      fi
      [ -s "$(harness_codex_auth_json)" ]
      ;;
    *) return 1 ;;
  esac
}

# Build-arg hint for a missing harness binary (message text only).
harness_install_hint() {
  case "${1:-}" in
    claude) printf 'INSTALL_CLAUDE_CLI=true' ;;
    codex) printf 'INSTALL_CODEX_CLI=true' ;;
    cursor) printf 'the default image (cursor-agent ships unconditionally)' ;;
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

# Codex authenticates from $CODEX_HOME/auth.json, not from OPENAI_API_KEY (see
# harness_creds_ok). Turn the env/Secret API key into that file before the
# daemon starts, using the pinned CLI's own documented writer
# (`codex login --with-api-key`) so the on-disk format stays correct across
# codex versions. An auth.json that is already there and is NOT an API-key login
# (e.g. a ChatGPT-OAuth projection from `codex login`) is left untouched.
harness_codex_provision_auth() {
  local bin_path home auth
  [ -n "${OPENAI_API_KEY:-}" ] || return 0
  home="$(harness_codex_home)"
  auth="$home/auth.json"
  if [ -s "$auth" ] && ! grep -q '"auth_mode"[[:space:]]*:[[:space:]]*"apikey"' "$auth" 2>/dev/null; then
    harness_log "codex: keeping existing $auth (not an API-key login) — OPENAI_API_KEY is not applied"
    return 0
  fi
  if ! mkdir -p "$home" 2>/dev/null || ! chmod 700 "$home" 2>/dev/null; then
    harness_log "FATAL: codex: cannot prepare CODEX_HOME '$home' for the projected credential"
    return 1
  fi
  bin_path="$(command -v "$(harness_bin_path codex)" 2>/dev/null || true)"
  if [ -z "$bin_path" ]; then
    harness_log "FATAL: codex: cannot locate the codex binary to write $auth"
    return 1
  fi
  if ! printf '%s\n' "$OPENAI_API_KEY" | "$bin_path" login --with-api-key >/dev/null 2>&1; then
    harness_log "FATAL: codex: 'codex login --with-api-key' failed — OPENAI_API_KEY could not be written to $auth"
    return 1
  fi
  chmod 600 "$auth" 2>/dev/null || true
  harness_log "codex: OPENAI_API_KEY → $auth (auth_mode=apikey, 0600)"
  return 0
}

# Export the env the daemon needs to spawn the selected harness(es):
#   - MULTICA_<CLI>_PATH pinned to the resolved absolute path (daemon-spawned
#     children get the same binary the gate proved)
#   - DISABLE_AUTOUPDATER=1 for claude: the image pins one Claude Code version
#     and the non-root runtime user cannot self-update that path anyway; an
#     attempted update would drift from the pin or fail mid-run.
#   - codex: no env var — its credential is the projected $CODEX_HOME/auth.json.
# Returns non-zero when a selected harness's credential could not be provisioned
# (fail closed: the daemon would otherwise start a task that cannot authenticate).
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
      codex)
        path="$(harness_bin_path codex)"
        if [ -z "${MULTICA_CODEX_PATH:-}" ]; then
          MULTICA_CODEX_PATH="$(command -v "$path" 2>/dev/null || printf '%s' "$path")"
          export MULTICA_CODEX_PATH
        fi
        harness_codex_provision_auth || return 1
        ;;
    esac
  done
  return 0
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
      harness_log "FATAL: required binary not on PATH: $path (harness '$h'; build with $(harness_install_hint "$h"))"
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

  harness_export_env "${selected[@]}" || return 1
  harness_log "agent harnesses: ${selected[*]}"
  return 0
}

# ── Masking unselected harnesses from PATH ────────────────────────────────
# All three agent CLIs ship in the image, so a Cursor-only deployment still has
# `claude` and `codex` on PATH; that is the surface that makes Multica advertise
# a harness the deployment never configured. After the gate above passes, every harness
# MULTICA_AGENT_CLI did not select is removed from the PATH exported to the
# daemon (and therefore to every task it spawns).
#
# Mechanism: PATH rewrite. Deleting /usr/local/bin/<cli> is not available at
# boot — the runtime user is uid 10001 (non-root) and /usr/local/bin is
# root-owned — so every PATH entry that actually holds a masked binary is
# replaced by a per-boot directory of symlinks to the rest of that entry's
# contents. Entries that hold nothing to mask are kept verbatim, and the image's
# directories are never modified, so this is stateless and reversible: restart
# with a different MULTICA_AGENT_CLI and the previous PATH comes back.
#
# Scope: the entrypoint's exported PATH → daemon + every task it spawns.
# `docker exec` / `kubectl exec` inherit the *image* env, not the boot env, so an
# operator shell still sees the unmasked image PATH; read the daemon's
# /proc/<pid>/environ to observe the mask.
#
# Masking is PATH hygiene, not an auth gate: when it cannot be applied the boot
# continues with a WARN, and a selected harness is never masked (so the hard
# gate's verdict is never contradicted).

# Where the per-boot mirror directories live (override for tests).
harness_mask_dir() { printf '%s\n' "${MULTICA_HARNESS_MASK_DIR:-${TMPDIR:-/tmp}/multica-harness-mask}"; }

# Other executable names that resolve to a harness's binary in this image
# (`/usr/local/bin/agent` → cursor-agent; `codex-linux-sandbox` → codex, the
# Linux sandbox helper codex re-execs itself as).
harness_bin_aliases() {
  case "${1:-}" in
    cursor) printf 'agent\n' ;;
    codex) printf 'codex-linux-sandbox\n' ;;
    *) : ;;
  esac
}

# Resolve an executable name to the real file it points at (PATH hits are often
# symlinks: /usr/local/bin/agent → cursor-agent).
harness_resolve_path() {
  local p
  p="$(command -v "${1:-}" 2>/dev/null || true)"
  [ -n "$p" ] || return 0
  readlink -f -- "$p" 2>/dev/null || printf '%s\n' "$p"
}

# Binary names that must leave PATH, one per line: each unselected harness's
# binary, plus any alias that currently resolves to that *same* binary (so an
# unrelated `agent` from another toolchain is never masked).
harness_masked_names() {
  local -a selected=("$@")
  local sel=" ${selected[*]} "
  local h name alias target hit
  while read -r h; do
    [ -n "$h" ] || continue
    case "$sel" in *" $h "*) continue ;; esac
    name="$(harness_bin_name "$h")" || continue
    printf '%s\n' "$name"
    target="$(harness_resolve_path "$name")"
    [ -n "$target" ] || continue
    for alias in $(harness_bin_aliases "$h"); do
      hit="$(harness_resolve_path "$alias")"
      if [ -n "$hit" ] && [ "$hit" = "$target" ]; then
        printf '%s\n' "$alias"
      fi
    done
  done < <(harness_known)
}

# Does <dir> hold any of the space-separated names in <names>?
harness_dir_has_masked() {
  local dir="$1" names="$2" name
  for name in $names; do
    if [ -e "$dir/$name" ] || [ -L "$dir/$name" ]; then
      return 0
    fi
  done
  return 1
}

# Rewrite PATH so the given binary names are unresolvable. <selected...> are the
# harnesses that keep their binaries.
harness_mask_path() {
  local -a selected=("$@")
  local -a dirs=()
  local original="$PATH" names names_csv mask_root name
  local dir dest entry base n=0 new_path="" seen=" " still_there=""

  names="$(harness_masked_names "${selected[@]}" || true)"
  if [ -z "$names" ]; then
    harness_log "harness PATH mask: every provisioned harness is selected (${selected[*]}); PATH unchanged"
    return 0
  fi
  names_csv="$(printf '%s' "$names" | tr '\n' ' ')"
  names_csv="${names_csv% }"

  mask_root="$(harness_mask_dir)"
  if ! mkdir -p "$mask_root" 2>/dev/null || [ ! -w "$mask_root" ]; then
    harness_log "WARN: harness PATH mask skipped: mask dir '$mask_root' is not writable; unselected harness binaries (${names_csv// /, }) stay on the daemon PATH"
    return 0
  fi

  IFS=':' read -r -a dirs <<<"$original"
  for dir in "${dirs[@]}"; do
    # Preserve empty PATH entries (they mean "current directory") and entries
    # that are not readable directories: only a directory that actually holds a
    # masked binary is rewritten.
    if [ -z "$dir" ]; then
      new_path="${new_path:+$new_path:}"
      continue
    fi
    # A duplicate PATH entry changes nothing about lookup order; keep the first.
    case "$seen" in *"|$dir|"*) continue ;; esac
    seen="$seen|$dir|"

    if [ ! -d "$dir" ] || ! harness_dir_has_masked "$dir" "$names_csv"; then
      new_path="${new_path:+$new_path:}$dir"
      continue
    fi

    n=$((n + 1))
    dest="$mask_root/entry-$n"
    rm -rf "$dest"
    if ! mkdir -p "$dest"; then
      harness_log "WARN: harness PATH mask: cannot create '$dest'; keeping '$dir' on PATH"
      new_path="${new_path:+$new_path:}$dir"
      continue
    fi
    # Mirror every non-masked entry as a symlink (a symlink resolves to the same
    # inode, so permissions/ownership/argv[0] all behave exactly as before).
    if ! (
      shopt -s nullglob dotglob
      for entry in "$dir"/*; do
        base="${entry##*/}"
        case " $names_csv " in *" $base "*) continue ;; esac
        ln -s "$entry" "$dest/$base" || exit 1
      done
    ); then
      harness_log "WARN: harness PATH mask: cannot mirror '$dir' into '$dest'; keeping it on PATH"
      new_path="${new_path:+$new_path:}$dir"
      continue
    fi
    new_path="${new_path:+$new_path:}$dest"
  done

  if [ "$new_path" = "$original" ]; then
    harness_log "harness PATH mask: nothing to mask (${names_csv// /, } not on PATH); PATH unchanged"
    return 0
  fi

  export PATH="$new_path"

  # Never claim a mask that did not happen: verify each name is really gone.
  for name in $names_csv; do
    if command -v "$name" >/dev/null 2>&1; then
      still_there="${still_there:+$still_there, }$name"
    fi
  done
  if [ -n "$still_there" ]; then
    harness_log "WARN: harness PATH mask incomplete — still resolvable: $still_there"
  else
    harness_log "harness PATH mask: ${names_csv// /, } removed from the daemon/task PATH (selected: ${selected[*]}; mirrors in $mask_root)"
  fi
  return 0
}

# Mask every harness MULTICA_AGENT_CLI did not select. Called by entrypoint.sh
# after harness_gate; never fatal and never touches a selected harness.
harness_mask_unselected() {
  local out
  local -a selected=()
  if ! out="$(harness_selected)" || [ -z "$out" ]; then
    harness_log "WARN: harness PATH mask skipped: MULTICA_AGENT_CLI could not be parsed"
    return 0
  fi
  mapfile -t selected <<<"$out"
  harness_mask_path "${selected[@]}" || true
  return 0
}

# Standalone use: ./agent-harness.sh → validate and print the selection.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  harness_gate
fi
