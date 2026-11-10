#!/usr/bin/env bash
# Unit check: bin/materialize-aws.sh reports the aws-sso AuthWorkflow that is
# actually in effect and warns when the pin is missing or misplaced.
#
# Background (BOX-124): aws-sso >= 2.2.0 defaults to PKCE, whose loopback
# callback lives inside the pod's netns and is unreachable from an operator's
# browser, so `aws-sso login` hangs. The fix is a TOP-LEVEL
# `AuthWorkflow: device_code` in consumer config — which an overlay can copy
# without, on any image release. Boot must say so out loud.
#
# No network, no aws-sso binary: this is a config-reading contract test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/materialize-aws.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

[ -r "$SCRIPT" ] || { bad "missing $SCRIPT"; exit 1; }

# run_case <name> <config-body|-> <legacy-dir?>
# Runs the real script in an isolated HOME and returns its log output.
run_case() {
  local name="$1" body="$2" legacy="${3:-}"
  local root="$WORK/$name"
  mkdir -p "$root/home" "$root/durable-sso" "$root/ws"
  if [ "$body" != "-" ]; then
    printf '%s' "$body" >"$root/durable-sso/config.yaml"
  fi
  if [ "$legacy" = "legacy" ]; then
    mkdir -p "$root/home/.aws-sso"
  fi
  (
    cd "$root"
    env HOME="$root/home" \
      MULTICA_WORKSPACES_ROOT="$root/ws" \
      AWS_SSO_DURABLE="$root/durable-sso" \
      AWS_HOME_DURABLE="$root/durable-aws" \
      AWS_CONFIG_SRC="$root/absent-aws-config" \
      AWS_SSO_CONFIG_SRC="$root/absent-sso-config" \
      AWS_SSO_FILE_PASSWORD=unit-passphrase \
      bash "$SCRIPT" 2>&1
  )
}

PINNED='AuthWorkflow: device_code
SSOConfig:
    Default:
        SSORegion: us-east-1
        StartUrl: https://example.awsapps.com/start
SecureStore: file
'

# 1. Pinned at the top level → reported as effective.
out="$(run_case pinned "$PINNED")"
if printf '%s' "$out" | grep -q 'aws-sso config: AuthWorkflow=device_code'; then
  ok "pinned workflow reported as effective"
else
  bad "effective workflow not reported for a pinned config: $out"
fi

# 2. Missing pin → loud warning naming the consequence and the fix.
out="$(run_case missing 'SecureStore: file
SSOConfig:
    Default:
        SSORegion: us-east-1
        StartUrl: https://example.awsapps.com/start
')"
if printf '%s' "$out" | grep -q "no 'AuthWorkflow: device_code'" \
  && printf '%s' "$out" | grep -q 'defaults to pkce'; then
  ok "missing pin warned (names pkce default + consequence)"
else
  bad "no warning for a config without the pin: $out"
fi

# 3. Pin nested under a block (the natural mistake) → says it is ignored.
out="$(run_case nested 'SecureStore: file
SSOConfig:
    Default:
        SSORegion: us-east-1
        StartUrl: https://example.awsapps.com/start
        AuthWorkflow: device_code
')"
if printf '%s' "$out" | grep -q 'AuthWorkflow is INDENTED'; then
  ok "indented/nested pin called out as ignored"
else
  bad "nested pin not detected as ignored: $out"
fi

# 4. Explicit pkce → warns, but names the deliberate-port-forward escape hatch.
out="$(run_case pkce 'AuthWorkflow: pkce
SSOConfig:
    Default:
        SSORegion: us-east-1
        StartUrl: https://example.awsapps.com/start
')"
if printf '%s' "$out" | grep -q 'AuthWorkflow=pkce' \
  && printf '%s' "$out" | grep -q 'port-forward'; then
  ok "explicit pkce warned with the port-forward caveat"
else
  bad "explicit pkce not warned: $out"
fi

# 5. Legacy ~/.aws-sso directory silently shadows the linked config.
out="$(run_case legacy-shadow "$PINNED" legacy)"
if printf '%s' "$out" | grep -q 'prefers it over'; then
  ok "legacy ~/.aws-sso directory called out as shadowing the ConfigMap"
else
  bad "legacy config dir shadowing not reported: $out"
fi

# 6. No aws-sso config at all → no workflow noise (deployments without AWS).
out="$(run_case absent -)"
if printf '%s' "$out" | grep -q 'aws-sso config:'; then
  bad "warned about aws-sso workflow with no config present: $out"
else
  ok "no aws-sso config → no workflow noise"
fi

# 7. Contract: a config problem must never fail the boot (continue-on-degrade).
if run_case exitcheck 'AuthWorkflow: pkce
SSOConfig:
    Default:
        SSORegion: us-east-1
        StartUrl: https://example.awsapps.com/start
' >/dev/null 2>&1; then
  ok "unpinned config does not fail the boot"
else
  bad "materialize-aws.sh exited non-zero on an unpinned config"
fi

printf '\n%s/%s checks passed\n' "$pass" "$((pass + fail))"
[ "$fail" = 0 ]
