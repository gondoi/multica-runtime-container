#!/usr/bin/env bash
# Unit check: the aws-sso config stubs keep the two pins BOX-124 depends on.
#
#   1. `AuthWorkflow: device_code` — aws-sso >= 2.2.0 defaults to `pkce`, whose
#      loopback callback (127.0.0.1:<port>) is unreachable from an operator
#      browser outside the pod, so login hangs and no session is cached. A
#      dependency bump that drops this pin silently re-breaks operator login.
#   2. `SecureStore: file` — the only backend available without a keyring daemon
#      in the container; `AWS_SSO_FILE_PASSWORD` only applies to that backend.
#   3. Pinned aws-sso >= 2.4.0 while `device_code` is set — earlier releases
#      requested no refresh_token for that workflow (sessions died after 8h).
#
# No network, no aws-sso binary: this is a config-contract test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB="$ROOT/examples/aws/config.yaml"
CM="$ROOT/examples/k8s/aws-configmap.yaml"
DOCKERFILE="$ROOT/Dockerfile"

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

for f in "$STUB" "$CM" "$DOCKERFILE"; do
  [ -r "$f" ] || { bad "missing $f"; exit 1; }
done

# value_of <file> <key> → the first `Key: value` outside a comment, trimmed.
value_of() {
  local file="$1" key="$2"
  sed -n "s/^[[:space:]]*${key}:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$file" | head -1
}

check_pin() {
  # check_pin <label> <file> <key> <expected>
  local label="$1" file="$2" key="$3" want="$4" got
  got="$(value_of "$file" "$key")"
  if [ "$got" = "$want" ]; then
    ok "$label: $key = $want"
  else
    bad "$label: $key = '${got}' (want '$want')"
  fi
}

check_pin "examples/aws/config.yaml" "$STUB" AuthWorkflow device_code
check_pin "examples/aws/config.yaml" "$STUB" SecureStore file
check_pin "examples/k8s/aws-configmap.yaml" "$CM" AuthWorkflow device_code
check_pin "examples/k8s/aws-configmap.yaml" "$CM" SecureStore file

# Upstream accepts exactly these two values (a typo like `authorization_code`
# makes every aws-sso command fail with "invalid AuthWorkflow").
for f in "$STUB" "$CM"; do
  got="$(value_of "$f" AuthWorkflow)"
  case "$got" in
    device_code|pkce|"") ok "$(basename "$f"): AuthWorkflow value is upstream-valid ('${got:-unset}')" ;;
    *) bad "$(basename "$f"): AuthWorkflow '${got}' is not one of device_code|pkce" ;;
  esac
done

# device_code + aws-sso < 2.4.0 = no refresh token (session dies after 8h).
sso_version="$(sed -n 's/^ARG AWS_SSO_VERSION=\([0-9][0-9.]*\).*/\1/p' "$DOCKERFILE" | head -1)"
if [ -z "$sso_version" ]; then
  bad "cannot read ARG AWS_SSO_VERSION from Dockerfile"
else
  lowest="2.4.0"
  if [ "$(printf '%s\n%s\n' "$lowest" "$sso_version" | sort -V | head -1)" = "$lowest" ]; then
    ok "pinned AWS_SSO_VERSION=$sso_version is >= $lowest (device_code gets a refresh_token)"
  else
    bad "pinned AWS_SSO_VERSION=$sso_version < $lowest while AuthWorkflow=device_code — sessions would die after 8h"
  fi
fi

# The comment has to explain the pin, or the next bump removes it again.
if grep -q 'AuthWorkflow' "$STUB" && grep -qi 'pkce' "$STUB" \
  && grep -qi '127\.0\.0\.1' "$STUB"; then
  ok "config.yaml comment explains device_code vs the pkce loopback callback"
else
  bad "config.yaml does not explain why AuthWorkflow is pinned (loopback/pkce)"
fi

printf '\n%s/%s checks passed\n' "$pass" "$((pass + fail))"
[ "$fail" = 0 ]
