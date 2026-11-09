#!/usr/bin/env bash
# Unit check: bin/agent-harness.sh harness selection + boot gates + PATH mask
# (cursor → cursor-agent + CURSOR_API_KEY; claude → claude + an Anthropic
# credential; codex → codex + OPENAI_API_KEY (projected into
# $CODEX_HOME/auth.json) or a pre-provisioned auth.json; unselected harnesses →
# removed from PATH). No Docker, no network, no real binaries: stub executables
# on a throwaway PATH stand in for cursor-agent/claude/codex.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/bin/agent-harness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

chmod +x "$LIB"

BASE_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$WORK/full" "$WORK/cursor-only" "$WORK/empty" "$WORK/all"
printf '#!/bin/sh\necho stub-claude\n' >"$WORK/full/claude"
printf '#!/bin/sh\necho stub-cursor-agent\n' >"$WORK/full/cursor-agent"
chmod +x "$WORK/full/claude" "$WORK/full/cursor-agent"
cp "$WORK/full/cursor-agent" "$WORK/cursor-only/cursor-agent"
chmod +x "$WORK/cursor-only/cursor-agent"

# Codex stand-in. The only codex behaviour the gate depends on is the documented
# credential writer `codex login --with-api-key`, which writes $CODEX_HOME/auth.json
# (the real CLI also writes mode 0600 and prints "API key saved.").
cat >"$WORK/codex-stub" <<'STUB'
#!/bin/sh
if [ "${1:-}" = login ] && [ "${2:-}" = --with-api-key ]; then
  key="$(cat)"
  if [ -z "${CODEX_HOME:-}" ]; then
    echo 'error: CODEX_HOME is not set' >&2
    exit 1
  fi
  mkdir -p "$CODEX_HOME" || exit 1
  umask 077
  printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": "%s"\n}\n' "$key" >"$CODEX_HOME/auth.json" || exit 1
  printf 'API key saved.\n'
  exit 0
fi
printf 'stub-codex\n'
STUB
chmod +x "$WORK/codex-stub"
cp "$WORK/full/claude" "$WORK/full/cursor-agent" "$WORK/all/"
cp "$WORK/codex-stub" "$WORK/all/codex"
chmod +x "$WORK/all/codex"

# Same image layout, but `codex login --with-api-key` fails: the gate must fail
# closed rather than start a daemon whose credential was never written.
mkdir -p "$WORK/all-bad-login"
cp "$WORK/full/claude" "$WORK/full/cursor-agent" "$WORK/all-bad-login/"
printf '#!/bin/sh\nif [ "${1:-}" = login ]; then echo "login exploded" >&2; exit 1; fi\nprintf "stub-codex\\n"\n' \
  >"$WORK/all-bad-login/codex"
chmod +x "$WORK/all-bad-login/codex"

# Probes source the library with a clean harness env (so the suite is
# independent of the shell it runs in). Functions do not survive a child shell,
# so each probe computes its own result.
# Probe variant that reports the parsed selection.
cat >"$WORK/probe-selected.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090
source "$LIB"
harness_selected | paste -sd, -
PROBE
chmod +x "$WORK/probe-selected.sh"

# Probe variant that runs the gate and then reports the exported env in a
# stable, greppable form (never the credential value itself).
cat >"$WORK/probe-gate.sh" <<'PROBE'
#!/usr/bin/env bash
# shellcheck disable=SC1090
source "$LIB"
rc=0
harness_gate || rc=$?
printf 'rc=%s\n' "$rc"
printf 'cursor_path=%s\n' "${MULTICA_CURSOR_PATH:-}"
printf 'claude_path=%s\n' "${MULTICA_CLAUDE_PATH:-}"
printf 'codex_path=%s\n' "${MULTICA_CODEX_PATH:-}"
printf 'autoupdater=%s\n' "${DISABLE_AUTOUPDATER:-}"
# Codex credential projection (never the key itself — only its presence/shape).
auth="$(harness_codex_auth_json)"
if [ -s "$auth" ]; then
  printf 'codex_auth=present\n'
  printf 'codex_auth_mode=%s\n' "$(sed -n 's/.*"auth_mode"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' "$auth" | head -1)"
  printf 'codex_auth_perm=%s\n' "$(stat -c '%a' "$auth" 2>/dev/null || printf unknown)"
  if [ -n "${OPENAI_API_KEY:-}" ] && grep -qF -- "$OPENAI_API_KEY" "$auth"; then
    printf 'codex_key_projected=yes\n'
  else
    printf 'codex_key_projected=no\n'
  fi
else
  printf 'codex_auth=absent\n'
fi
PROBE
chmod +x "$WORK/probe-gate.sh"

# run_gate <path-dir> [VAR=value ...] → probe output (stderr folded in)
# CODEX_HOME always points inside $WORK so the suite never touches a real
# ~/.codex. The default home is wiped per case; CASE_CODEX_HOME pre-seeds one
# (used by the pre-provisioned-auth.json cases).
HARNESS_VARS=(-u MULTICA_AGENT_CLI -u CURSOR_API_KEY -u ANTHROPIC_API_KEY
  -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN -u OPENAI_API_KEY
  -u MULTICA_CURSOR_PATH -u MULTICA_CLAUDE_PATH -u MULTICA_CODEX_PATH
  -u DISABLE_AUTOUPDATER -u CODEX_HOME
  -u MULTICA_HARNESS_MASK_DIR)

run_gate() {
  # Caller-supplied VAR=value pairs land after the -u scrub, so each case starts
  # from a clean harness env regardless of the invoking shell.
  local pathdir="$1"
  local chome="${CASE_CODEX_HOME:-$WORK/codex-home}"
  shift
  if [ -z "${CASE_CODEX_HOME:-}" ]; then
    rm -rf "$chome"
    mkdir -p "$chome"
  fi
  env "${HARNESS_VARS[@]}" PATH="$pathdir:$BASE_PATH" LIB="$LIB" CODEX_HOME="$chome" "$@" \
    "$WORK/probe-gate.sh" 2>&1
}

# selected <path-dir> [VAR=value ...] → comma-joined names, or non-zero + stderr
selected() {
  local pathdir="$1"
  shift
  env "${HARNESS_VARS[@]}" PATH="$pathdir:$BASE_PATH" LIB="$LIB" "$@" \
    "$WORK/probe-selected.sh" 2>&1
}

expect_gate_ok() {
  # expect_gate_ok <label> <path-dir> [VAR=value ...]
  local label="$1" pathdir="$2" out
  shift 2
  out="$(run_gate "$pathdir" "$@")"
  if printf '%s' "$out" | grep -qx 'rc=0'; then
    ok "$label"
  else
    bad "$label — gate failed: $out"
  fi
}

expect_gate_fail() {
  # expect_gate_fail <label> <needle> <path-dir> [VAR=value ...]
  local label="$1" needle="$2" pathdir="$3" out
  shift 3
  out="$(run_gate "$pathdir" "$@")"
  if printf '%s' "$out" | grep -qx 'rc=1' && printf '%s' "$out" | grep -qF -- "$needle"; then
    ok "$label"
  else
    bad "$label — want rc=1 + '$needle', got: $out"
  fi
}

# ── selection ────────────────────────────────────────────────────────────
if [ "$(selected "$WORK/full")" = "cursor" ]; then
  ok "default MULTICA_AGENT_CLI is cursor (pre-Claude boot contract)"
else
  bad "default selection is not cursor: $(selected "$WORK/full")"
fi

for spec in "claude:claude" "codex:codex" "cursor,claude:cursor,claude" "claude cursor:claude,cursor" \
  "cursor,claude,codex:cursor,claude,codex" "claude codex:claude,codex" \
  "CLAUDE:claude" "CODEX:codex" "claude,claude:claude" "codex,codex:codex" \
  "cursor, claude :cursor,claude"; do
  want="${spec##*:}"
  value="${spec%:*}"
  got="$(selected "$WORK/full" MULTICA_AGENT_CLI="$value")"
  if [ "$got" = "$want" ]; then
    ok "MULTICA_AGENT_CLI='$value' → $want"
  else
    bad "MULTICA_AGENT_CLI='$value' → '$got', want '$want'"
  fi
done

if out="$(selected "$WORK/full" MULTICA_AGENT_CLI=gemini)"; then
  bad "unknown harness 'gemini' was accepted: $out"
else
  if printf '%s' "$out" | grep -qF "unknown name 'gemini'"; then
    ok "unknown harness name rejected with the offending value"
  else
    bad "unknown harness rejected without naming it: $out"
  fi
fi

# ── gates: success paths ─────────────────────────────────────────────────
expect_gate_ok "cursor gate passes with CURSOR_API_KEY + cursor-agent" \
  "$WORK/full" CURSOR_API_KEY=cursor_test

expect_gate_ok "claude gate passes with ANTHROPIC_API_KEY + claude binary" \
  "$WORK/full" MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test

expect_gate_ok "claude gate accepts CLAUDE_CODE_OAUTH_TOKEN" \
  "$WORK/full" MULTICA_AGENT_CLI=claude CLAUDE_CODE_OAUTH_TOKEN=oauth-test

expect_gate_ok "claude gate accepts ANTHROPIC_AUTH_TOKEN (gateway)" \
  "$WORK/full" MULTICA_AGENT_CLI=claude ANTHROPIC_AUTH_TOKEN=gw-test

expect_gate_ok "cursor,claude gate passes with both credentials" \
  "$WORK/full" MULTICA_AGENT_CLI=cursor,claude \
  CURSOR_API_KEY=cursor_test ANTHROPIC_API_KEY=sk-ant-test

expect_gate_ok "codex gate passes with OPENAI_API_KEY + codex binary" \
  "$WORK/all" MULTICA_AGENT_CLI=codex OPENAI_API_KEY=sk-codex-test

# Pre-provisioned auth.json (what `codex login` writes, API-key or OAuth) must
# satisfy the gate without any OPENAI_API_KEY in the environment.
CASE_CODEX_HOME="$WORK/codex-home-preprovisioned"
mkdir -p "$CASE_CODEX_HOME"
printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": "sk-preprovisioned"\n}\n' \
  >"$CASE_CODEX_HOME/auth.json"
expect_gate_ok "codex gate passes with a pre-provisioned auth.json and no key" \
  "$WORK/all" MULTICA_AGENT_CLI=codex
out="$(run_gate "$WORK/all" MULTICA_AGENT_CLI=codex)"
unset CASE_CODEX_HOME
if printf '%s' "$out" | grep -qx 'codex_auth=present' \
  && printf '%s' "$out" | grep -qx 'codex_key_projected=no'; then
  ok "pre-provisioned auth.json is left untouched (no key to project)"
else
  bad "pre-provisioned auth.json was overwritten or lost: $out"
fi

expect_gate_ok "cursor,claude,codex gate passes with all three credentials" \
  "$WORK/all" MULTICA_AGENT_CLI=cursor,claude,codex \
  CURSOR_API_KEY=cursor_test ANTHROPIC_API_KEY=sk-ant-test OPENAI_API_KEY=sk-codex-test

# Regression guard: a Claude-only deployment must not need a Cursor key, and
# the gate must say which harness it accepted.
out="$(run_gate "$WORK/full" MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test)"
if printf '%s' "$out" | grep -qF 'agent harnesses: claude'; then
  ok "claude-only gate succeeds without CURSOR_API_KEY (reports claude)"
else
  bad "claude-only gate did not report its harness: $out"
fi

# ── gates: failure paths ─────────────────────────────────────────────────
expect_gate_fail "missing claude credential fails the gate" \
  "claude harness auth required" "$WORK/full" MULTICA_AGENT_CLI=claude

expect_gate_fail "missing claude credential names every accepted variable" \
  "ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_AUTH_TOKEN" \
  "$WORK/full" MULTICA_AGENT_CLI=claude

expect_gate_fail "cursor credential does not satisfy the claude gate" \
  "claude harness auth required" "$WORK/full" \
  MULTICA_AGENT_CLI=claude CURSOR_API_KEY=cursor_test

expect_gate_fail "missing cursor credential fails the default gate" \
  "CURSOR_API_KEY" "$WORK/full"

expect_gate_fail "missing claude binary fails the gate" \
  "required binary not on PATH: claude" "$WORK/cursor-only" \
  MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test

expect_gate_fail "cursor,claude fails when one harness is unauthenticated" \
  "claude harness auth required" "$WORK/full" \
  MULTICA_AGENT_CLI=cursor,claude CURSOR_API_KEY=cursor_test

expect_gate_fail "unknown MULTICA_AGENT_CLI fails the gate" \
  "MULTICA_AGENT_CLI" "$WORK/full" MULTICA_AGENT_CLI=gemini ANTHROPIC_API_KEY=sk-ant-test

expect_gate_fail "empty MULTICA_AGENT_CLI fails the gate" \
  "MULTICA_AGENT_CLI is empty" "$WORK/full" MULTICA_AGENT_CLI=" "

expect_gate_fail "missing codex credential fails the gate" \
  "codex harness auth required" "$WORK/all" MULTICA_AGENT_CLI=codex

expect_gate_fail "missing codex credential names OPENAI_API_KEY" \
  "OPENAI_API_KEY" "$WORK/all" MULTICA_AGENT_CLI=codex

expect_gate_fail "cursor credential does not satisfy the codex gate" \
  "codex harness auth required" "$WORK/all" \
  MULTICA_AGENT_CLI=codex CURSOR_API_KEY=cursor_test ANTHROPIC_API_KEY=sk-ant-test

expect_gate_fail "missing codex binary fails the gate" \
  "required binary not on PATH: codex" "$WORK/full" \
  MULTICA_AGENT_CLI=codex OPENAI_API_KEY=sk-codex-test

expect_gate_fail "missing claude binary hint names INSTALL_CLAUDE_CLI" \
  "build with INSTALL_CLAUDE_CLI=true" "$WORK/cursor-only" \
  MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test

expect_gate_fail "missing codex binary hint names INSTALL_CODEX_CLI" \
  "build with INSTALL_CODEX_CLI=true" "$WORK/full" \
  MULTICA_AGENT_CLI=codex OPENAI_API_KEY=sk-codex-test

expect_gate_fail "codex credential projection failure fails the gate (fail closed)" \
  "codex login --with-api-key" "$WORK/all-bad-login" \
  MULTICA_AGENT_CLI=codex OPENAI_API_KEY=sk-codex-test

# ── exported env for the daemon ──────────────────────────────────────────
out="$(run_gate "$WORK/full" MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test)"
if printf '%s' "$out" | grep -qx "claude_path=$WORK/full/claude" \
  && printf '%s' "$out" | grep -qx 'autoupdater=1'; then
  ok "claude selection pins MULTICA_CLAUDE_PATH (absolute) + DISABLE_AUTOUPDATER=1"
else
  bad "claude selection did not export path/autoupdater: $out"
fi

out="$(run_gate "$WORK/full" CURSOR_API_KEY=cursor_test)"
if printf '%s' "$out" | grep -qx "cursor_path=$WORK/full/cursor-agent" \
  && printf '%s' "$out" | grep -qx 'autoupdater='; then
  ok "cursor-only selection leaves claude autoupdater/knob untouched"
else
  bad "cursor-only selection exported unexpected env: $out"
fi

out="$(run_gate "$WORK/full" MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test \
  MULTICA_CLAUDE_PATH="$WORK/full/claude")"
if printf '%s' "$out" | grep -qx "claude_path=$WORK/full/claude"; then
  ok "explicit MULTICA_CLAUDE_PATH override is honoured"
else
  bad "MULTICA_CLAUDE_PATH override not honoured: $out"
fi

out="$(run_gate "$WORK/all" MULTICA_AGENT_CLI=codex OPENAI_API_KEY=sk-codex-test)"
if printf '%s' "$out" | grep -qx "codex_path=$WORK/all/codex" \
  && printf '%s' "$out" | grep -qx 'codex_auth=present' \
  && printf '%s' "$out" | grep -qx 'codex_auth_mode=apikey' \
  && printf '%s' "$out" | grep -qx 'codex_auth_perm=600' \
  && printf '%s' "$out" | grep -qx 'codex_key_projected=yes' \
  && printf '%s' "$out" | grep -qx 'autoupdater='; then
  ok "codex selection pins MULTICA_CODEX_PATH and projects OPENAI_API_KEY → \$CODEX_HOME/auth.json (0600, auth_mode=apikey)"
else
  bad "codex selection did not pin its path / project the credential: $out"
fi

# An OAuth login (auth_mode != apikey) must never be clobbered by an API key
# that happens to sit in the environment.
CASE_CODEX_HOME="$WORK/codex-home-oauth"
mkdir -p "$CASE_CODEX_HOME"
printf '{\n  "auth_mode": "chatgpt",\n  "tokens": {\n    "access_token": "oauth-not-real"\n  }\n}\n' \
  >"$CASE_CODEX_HOME/auth.json"
out="$(run_gate "$WORK/all" MULTICA_AGENT_CLI=codex OPENAI_API_KEY=sk-codex-test)"
unset CASE_CODEX_HOME
if printf '%s' "$out" | grep -qx 'codex_auth_mode=chatgpt' \
  && printf '%s' "$out" | grep -qx 'codex_key_projected=no' \
  && printf '%s' "$out" | grep -q 'keeping existing'; then
  ok "codex keeps an existing non-API-key auth.json (OAuth login) and says why"
else
  bad "codex overwrote an OAuth auth.json with the env API key: $out"
fi

out="$(run_gate "$WORK/all" MULTICA_AGENT_CLI=codex OPENAI_API_KEY=sk-codex-test \
  MULTICA_CODEX_PATH="$WORK/all/codex") "
if printf '%s' "$out" | grep -qx "codex_path=$WORK/all/codex"; then
  ok "explicit MULTICA_CODEX_PATH override is honoured"
else
  bad "MULTICA_CODEX_PATH override not honoured: $out"
fi

if printf '%s' "$out" | grep -qiE 'sk-ant-test|sk-codex-test'; then
  bad "gate output leaked a credential value"
else
  ok "gate output never echoes credential values"
fi

# ── PATH mask: unselected harness binaries leave PATH ────────────────────
# The image ships both CLIs, so a Cursor-only deployment must not be able to
# resolve `claude` from the daemon/task PATH (and vice versa). Stubs below model
# the image layout, including /usr/local/bin/agent → cursor-agent.
mkdir -p "$WORK/aliased" "$WORK/agent-other" "$WORK/two-a" "$WORK/two-b"
cp "$WORK/full/claude" "$WORK/aliased/claude"
cp "$WORK/full/cursor-agent" "$WORK/aliased/cursor-agent"
cp "$WORK/codex-stub" "$WORK/aliased/codex"
ln -sf "$WORK/aliased/cursor-agent" "$WORK/aliased/agent"
ln -sf "$WORK/aliased/codex" "$WORK/aliased/codex-linux-sandbox"
chmod +x "$WORK/aliased/claude" "$WORK/aliased/cursor-agent" "$WORK/aliased/codex"
# `agent` here is an unrelated tool (different real file) — must stay visible.
printf '#!/bin/sh\necho unrelated-agent\n' >"$WORK/agent-other/agent"
cp "$WORK/aliased/claude" "$WORK/agent-other/claude"
chmod +x "$WORK/agent-other/agent" "$WORK/agent-other/claude"
cp "$WORK/full/cursor-agent" "$WORK/two-a/cursor-agent"
cp "$WORK/full/claude" "$WORK/two-b/claude"
chmod +x "$WORK/two-a/cursor-agent" "$WORK/two-b/claude"

cat >"$WORK/probe-mask.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090
source "$LIB"
for _ in $(seq 1 "${MASK_RUNS:-1}"); do
  harness_mask_unselected
  printf 'path=%s\n' "$PATH"
  for b in claude cursor-agent codex codex-linux-sandbox agent; do
    if p="$(command -v "$b" 2>/dev/null)"; then
      printf 'bin_%s=%s\n' "$b" "$p"
    else
      printf 'bin_%s=MASKED\n' "$b"
    fi
  done
done
PROBE
chmod +x "$WORK/probe-mask.sh"

# mask_path <path-dir> [VAR=value ...] → probe output (stderr folded in)
mask_path() {
  local pathdir="$1"
  shift
  env "${HARNESS_VARS[@]}" PATH="$pathdir:$BASE_PATH" LIB="$LIB" \
    MULTICA_HARNESS_MASK_DIR="${MASK_DIR_OVERRIDE:-$WORK/mask}" "$@" \
    "$WORK/probe-mask.sh" 2>&1
}

masked_bin() { printf '%s\n' "$1" | sed -n "s/^bin_$2=//p" | head -1; }
masked_path() { printf '%s\n' "$1" | sed -n 's/^path=//p' | head -1; }

out="$(mask_path "$WORK/full" MULTICA_AGENT_CLI=cursor CURSOR_API_KEY=cursor_test)"
if [ "$(masked_bin "$out" claude)" = "MASKED" ] \
  && [ -n "$(masked_bin "$out" cursor-agent)" ] \
  && printf '%s' "$(masked_path "$out")" | grep -q "$WORK/mask/entry-" \
  && ! printf '%s' "$(masked_path "$out")" | grep -qF "$WORK/full"; then
  ok "cursor selected → claude masked, cursor-agent resolvable (PATH rewritten)"
else
  bad "cursor selected did not mask claude / keep cursor-agent: $out"
fi

# The masked PATH must still execute the selected harness (symlink mirror, not
# a stub that breaks argv/exec).
if [ "$(env -i PATH="$(masked_path "$out")" cursor-agent 2>/dev/null)" = "stub-cursor-agent" ]; then
  ok "masked PATH still executes the selected cursor-agent binary"
else
  bad "selected cursor-agent does not run through the masked PATH"
fi

out="$(mask_path "$WORK/aliased" MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test)"
if [ "$(masked_bin "$out" cursor-agent)" = "MASKED" ] \
  && [ "$(masked_bin "$out" agent)" = "MASKED" ] \
  && [ "$(masked_bin "$out" codex)" = "MASKED" ] \
  && [ "$(masked_bin "$out" codex-linux-sandbox)" = "MASKED" ] \
  && [ -n "$(masked_bin "$out" claude)" ] \
  && [ "$(env -i PATH="$(masked_path "$out")" claude 2>/dev/null)" = "stub-claude" ]; then
  ok "claude selected → cursor-agent + its 'agent' alias + codex + codex-linux-sandbox masked, claude still runs"
else
  bad "claude selected did not mask cursor-agent/agent/codex aliases or broke claude: $out"
fi

out="$(mask_path "$WORK/all" MULTICA_AGENT_CLI=codex OPENAI_API_KEY=sk-codex-test)"
if [ "$(masked_bin "$out" claude)" = "MASKED" ] \
  && [ "$(masked_bin "$out" cursor-agent)" = "MASKED" ] \
  && [ -n "$(masked_bin "$out" codex)" ] \
  && [ "$(env -i PATH="$(masked_path "$out")" codex 2>/dev/null)" = "stub-codex" ]; then
  ok "codex selected → claude + cursor-agent masked, codex still runs"
else
  bad "codex selected did not mask claude/cursor-agent or broke codex: $out"
fi

out="$(mask_path "$WORK/all" MULTICA_AGENT_CLI=cursor,claude,codex)"
if [ "$(masked_path "$out")" = "$WORK/all:$BASE_PATH" ] \
  && ! printf '%s' "$out" | grep -qE '^bin_(claude|cursor-agent|codex)=MASKED$'; then
  ok "all three harnesses selected → mask is a no-op (PATH untouched)"
else
  bad "all-selected boot changed PATH: $out"
fi

out="$(mask_path "$WORK/agent-other:$WORK/full" MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test)"
if [ "$(masked_bin "$out" agent)" = "$WORK/agent-other/agent" ] \
  && [ "$(masked_bin "$out" cursor-agent)" = "MASKED" ]; then
  ok "unrelated 'agent' binary not masked (alias match is by real file)"
else
  bad "mask treated an unrelated 'agent' binary as the Cursor alias: $out"
fi

out="$(mask_path "$WORK/two-a:$WORK/two-b" MULTICA_AGENT_CLI=claude ANTHROPIC_API_KEY=sk-ant-test)"
if [ "$(masked_bin "$out" cursor-agent)" = "MASKED" ] \
  && [ "$(masked_bin "$out" claude)" = "$WORK/two-b/claude" ] \
  && printf '%s' "$(masked_path "$out")" | grep -qF "$WORK/two-b"; then
  ok "masked binary removed from its PATH entry only (other entries verbatim)"
else
  bad "mask rewrote PATH entries it should not have: $out"
fi

out="$(mask_path "$WORK/full" MULTICA_AGENT_CLI=cursor CURSOR_API_KEY=cursor_test MASK_RUNS=2)"
mask_paths="$(printf '%s\n' "$out" | sed -n 's/^path=//p')"
if [ "$(printf '%s\n' "$mask_paths" | wc -l)" = 2 ] \
  && [ "$(printf '%s\n' "$mask_paths" | sort -u | wc -l)" = 1 ] \
  && [ "$(printf '%s\n' "$out" | grep -c '^bin_claude=MASKED$')" = 2 ]; then
  ok "mask is idempotent (second run leaves the same PATH, claude still masked)"
else
  bad "mask is not idempotent: mask_paths='$mask_paths'"
fi

out="$(mask_path "$WORK/cursor-only" MULTICA_AGENT_CLI=cursor CURSOR_API_KEY=cursor_test)"
if [ "$(masked_path "$out")" = "$WORK/cursor-only:$BASE_PATH" ] \
  && printf '%s' "$out" | grep -q 'nothing to mask'; then
  ok "harness not installed → nothing to mask, PATH unchanged"
else
  bad "mask changed PATH although no unselected binary is installed: $out"
fi

out="$(MASK_DIR_OVERRIDE=/proc/definitely-not-writable mask_path "$WORK/full" \
  MULTICA_AGENT_CLI=cursor CURSOR_API_KEY=cursor_test)"
if [ "$(masked_path "$out")" = "$WORK/full:$BASE_PATH" ] \
  && printf '%s' "$out" | grep -q 'mask dir .* is not writable'; then
  ok "unwritable mask dir → WARN + PATH unchanged (masking never breaks boot)"
else
  bad "unwritable mask dir did not degrade to a warning: $out"
fi

out="$(mask_path "$WORK/full" MULTICA_AGENT_CLI=gemini)"
if printf '%s' "$out" | grep -q 'mask skipped' \
  && [ "$(masked_path "$out")" = "$WORK/full:$BASE_PATH" ]; then
  ok "unparseable MULTICA_AGENT_CLI → mask skipped (gate already failed the boot)"
else
  bad "invalid selection did not skip masking cleanly: $out"
fi

echo
if [ "$fail" = 0 ]; then
  echo "agent-harness: $pass passed"
else
  echo "agent-harness: $fail failed, $pass passed" >&2
fi
[ "$fail" = 0 ]
