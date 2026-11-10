#!/usr/bin/env bash
# Unit check: bin/aws-credential-source.sh names the credential source the AWS
# SDK default chain would actually use, and never leaks a credential value.
#
# No network, no real credentials, no AWS calls — the suite only exercises the
# detection predicates against env vars and a throwaway HOME.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/aws-credential-source.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

chmod +x "$SCRIPT"

# Isolated HOME: a mounted ~/.aws from the caller's machine must not leak in.
export HOME="$WORK/home"
mkdir -p "$HOME"

clear_aws_env() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
    AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_PROFILE \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_SSO_FILE_PASSWORD \
    MULTICA_AWS_SSO_PASSPHRASE_SOURCE
}

source_of() {
  # Usage: source_of [VAR=value ...] → the reported line
  (
    clear_aws_env
    env "$@" "$SCRIPT"
  )
}

expect_contains() {
  # expect_contains <label> <needle> [VAR=value ...]
  local label="$1" needle="$2" out
  shift 2
  out="$(source_of "$@")"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    ok "$label"
  else
    bad "$label — want '$needle', got: $out"
  fi
}

expect_absent() {
  # expect_absent <label> <needle> [VAR=value ...]
  local label="$1" needle="$2" out
  shift 2
  out="$(source_of "$@")"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    bad "$label — leaked '$needle' in: $out"
  else
    ok "$label"
  fi
}

expect_contains "static env keys reported" "static env keys" \
  "AWS_ACCESS_KEY_ID=AKIAEXAMPLE"
expect_contains "session token noted, value never printed" "AWS_SESSION_TOKEN" \
  "AWS_ACCESS_KEY_ID=AKIAEXAMPLE" "AWS_SESSION_TOKEN=SECRETSESSION"
expect_absent "secret access key never printed" "SECRETKEYVALUE" \
  "AWS_ACCESS_KEY_ID=AKIAEXAMPLE" "AWS_SECRET_ACCESS_KEY=SECRETKEYVALUE"
expect_absent "secret session token never printed" "SECRETSESSION" \
  "AWS_ACCESS_KEY_ID=AKIAEXAMPLE" "AWS_SESSION_TOKEN=SECRETSESSION"

expect_contains "IRSA web identity reported" "IRSA" \
  "AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token" \
  "AWS_ROLE_ARN=arn:aws:iam::111111111111:role/multica-runtime"
expect_contains "IRSA without role ARN is called out" "without AWS_ROLE_ARN" \
  "AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token"

expect_contains "ECS task role endpoint reported" "container credentials endpoint" \
  "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/v2/credentials/abc"

# Env static keys outrank IRSA in the SDK chain — the report must say so.
expect_contains "env keys win over IRSA" "static env keys" \
  "AWS_ACCESS_KEY_ID=AKIAEXAMPLE" \
  "AWS_WEB_IDENTITY_TOKEN_FILE=/token" "AWS_ROLE_ARN=arn:aws:iam::111111111111:role/x"

# Mounted config (tier 3): default ~/.aws paths, then the env-var override.
mkdir -p "$HOME/.aws"
printf '[default]\naws_access_key_id = AKIAFILE\n' >"$HOME/.aws/credentials"
expect_contains "mounted ~/.aws credentials reported" "mounted AWS config"
printf '[default]\nregion = us-east-1\n' >"$WORK/aws-config"
expect_contains "AWS_CONFIG_FILE override reported" "$WORK/aws-config" \
  "AWS_CONFIG_FILE=$WORK/aws-config"

# Env points at a path that does not exist: a nameable misconfiguration, still exit 0.
expect_contains "missing mounted file called out" "missing or empty" \
  "AWS_SHARED_CREDENTIALS_FILE=$WORK/absent/credentials"

rm -rf "$HOME/.aws"
expect_contains "nothing wired is reported" "none detected" 

# aws-sso credential_process profiles (BOX-124): the boot line must say whether
# the file-SecureStore passphrase is exported, without ever printing it.
mkdir -p "$HOME/.aws"
printf '[profile Example:ReadOnly]\ncredential_process = /usr/local/bin/aws-sso -S "Default" process --arn arn:aws:iam::111111111111:role/ReadOnly\n' \
  >"$HOME/.aws/config"
expect_contains "aws-sso profile without passphrase is called out" \
  "AWS_SSO_FILE_PASSWORD unset"
expect_contains "aws-sso profile names the fatal repro" "Must run" 
expect_contains "aws-sso profile with passphrase exported" \
  "passphrase loaded from env" \
  "AWS_SSO_FILE_PASSWORD=SECRETPASSPHRASE"
expect_absent "passphrase value never printed in the aws-sso note" "SECRETPASSPHRASE" \
  "AWS_SSO_FILE_PASSWORD=SECRETPASSPHRASE"
# Boot names the source so "which wiring is this pod using?" is answerable.
expect_contains "env-sourced passphrase reported as such" \
  "passphrase loaded from env" \
  "AWS_SSO_FILE_PASSWORD=SECRETPASSPHRASE" \
  "MULTICA_AWS_SSO_PASSPHRASE_SOURCE=env"
expect_contains "file-sourced passphrase names the file path" \
  "passphrase loaded from file:/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD" \
  "AWS_SSO_FILE_PASSWORD=SECRETPASSPHRASE" \
  "MULTICA_AWS_SSO_PASSPHRASE_SOURCE=file:/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD"
expect_absent "file path note never prints the passphrase" "SECRETPASSPHRASE" \
  "AWS_SSO_FILE_PASSWORD=SECRETPASSPHRASE" \
  "MULTICA_AWS_SSO_PASSPHRASE_SOURCE=file:/run/secrets/aws-sso/AWS_SSO_FILE_PASSWORD"

# No aws-sso profile in the mounted config → note stays out of the way.
printf '[default]\nregion = us-east-1\n' >"$HOME/.aws/config"
expect_absent "no aws-sso note without a credential_process profile" "aws-sso profile(s)"
rm -rf "$HOME/.aws"

# Contract: always exits 0 — a detection mistake must never fail a boot.
clear_aws_env
if "$SCRIPT" >/dev/null 2>&1; then
  ok "exits 0 with no credentials present"
else
  bad "non-zero exit with no credentials present"
fi

printf '\n%s/%s checks passed\n' "$pass" "$((pass + fail))"
[ "$fail" = 0 ]
