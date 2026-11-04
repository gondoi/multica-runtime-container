#!/usr/bin/env bash
# Unit check: bin/agent-harness.sh harness selection + boot gates
# (cursor → cursor-agent + CURSOR_API_KEY; claude → claude + an Anthropic
# credential). No Docker, no network, no real binaries: stub executables on a
# throwaway PATH stand in for cursor-agent/claude.
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
mkdir -p "$WORK/full" "$WORK/cursor-only" "$WORK/empty"
printf '#!/bin/sh\necho stub-claude\n' >"$WORK/full/claude"
printf '#!/bin/sh\necho stub-cursor-agent\n' >"$WORK/full/cursor-agent"
chmod +x "$WORK/full/claude" "$WORK/full/cursor-agent"
cp "$WORK/full/cursor-agent" "$WORK/cursor-only/cursor-agent"
chmod +x "$WORK/cursor-only/cursor-agent"

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
printf 'autoupdater=%s\n' "${DISABLE_AUTOUPDATER:-}"
PROBE
chmod +x "$WORK/probe-gate.sh"

# run_gate <path-dir> [VAR=value ...] → probe output (stderr folded in)
HARNESS_VARS=(-u MULTICA_AGENT_CLI -u CURSOR_API_KEY -u ANTHROPIC_API_KEY
  -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN
  -u MULTICA_CURSOR_PATH -u MULTICA_CLAUDE_PATH -u DISABLE_AUTOUPDATER)

run_gate() {
  # Caller-supplied VAR=value pairs land after the -u scrub, so each case starts
  # from a clean harness env regardless of the invoking shell.
  local pathdir="$1"
  shift
  env "${HARNESS_VARS[@]}" PATH="$pathdir:$BASE_PATH" LIB="$LIB" "$@" \
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

for spec in "claude:claude" "cursor,claude:cursor,claude" "claude cursor:claude,cursor" \
  "CLAUDE:claude" "claude,claude:claude" "cursor, claude :cursor,claude"; do
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

if printf '%s' "$out" | grep -qi 'sk-ant-test'; then
  bad "gate output leaked a credential value"
else
  ok "gate output never echoes credential values"
fi

echo
if [ "$fail" = 0 ]; then
  echo "agent-harness: $pass passed"
else
  echo "agent-harness: $fail failed, $pass passed" >&2
fi
[ "$fail" = 0 ]
