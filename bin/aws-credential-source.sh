#!/usr/bin/env bash
# Report which AWS credential source the SDK default chain will actually use.
#
# Informational only — prints ONE short line naming the detected source (and the
# env var / file path that pointed at it). It never reads, prints, or exports a
# credential value, never calls AWS, and always exits 0: a bad guess here must
# never turn into a boot failure.
#
# Precedence mirrors the AWS SDK default credential chain, so the printed source
# is the one that would win — not merely one that happens to be present.
# Image ships the AWS CLI with no credential plumbing of its own; see the
# README "AWS CLI auth tiers" table for why each tier is preferred over the next.
#
# Usage: aws-credential-source.sh
set -uo pipefail

aws_home="${HOME:-/home/agent}"
config_file="${AWS_CONFIG_FILE:-$aws_home/.aws/config}"
creds_file="${AWS_SHARED_CREDENTIALS_FILE:-$aws_home/.aws/credentials}"
profile="${AWS_PROFILE:-default}"

# Append a note about aws-sso file-SecureStore unlock when a profile in the
# mounted config uses `credential_process = …/aws-sso …`. Those profiles only
# work from a TTY (the store prompts for its passphrase) unless the
# upstream-documented AWS_SSO_FILE_PASSWORD is exported — which is what makes an
# agent task's `credential_process` fail with "Enter passphrase to unlock" then
# "Must run `aws-sso login`". Prints state only, never the passphrase.
aws_sso_note() {
  local cfg="${1:-}"
  [ -n "$cfg" ] && [ -r "$cfg" ] || return 0
  command -v grep >/dev/null 2>&1 || return 0
  grep -qs 'credential_process *=.*aws-sso' "$cfg" || return 0
  if [ -n "${AWS_SSO_FILE_PASSWORD:-}" ]; then
    printf '; aws-sso profile(s): passphrase loaded from %s — non-TTY credential_process can unlock' "${MULTICA_AWS_SSO_PASSPHRASE_SOURCE:-env}"
  else
    printf '; aws-sso profile(s): AWS_SSO_FILE_PASSWORD unset — non-TTY agent tasks get "Enter passphrase to unlock ~/.config/aws-sso/secure" then "Must run `aws-sso login`" (see README AWS profiles)'
  fi
}

# 1. Static keys in the environment win over everything below them.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  session_note=""
  [ -n "${AWS_SESSION_TOKEN:-}" ] && session_note=" + AWS_SESSION_TOKEN"
  printf 'static env keys (AWS_ACCESS_KEY_ID%s) — long-lived, prefer IRSA/instance role\n' "$session_note"
  exit 0
fi

# 2. IRSA / web identity (EKS projects these; highest-trust tier in this repo).
if [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ]; then
  if [ -n "${AWS_ROLE_ARN:-}" ]; then
    printf 'web identity / IRSA (AWS_WEB_IDENTITY_TOKEN_FILE, role %s) — tier 1\n' "$AWS_ROLE_ARN"
  else
    printf 'web identity (AWS_WEB_IDENTITY_TOKEN_FILE without AWS_ROLE_ARN — check the pod/SA annotation) — tier 1\n'
  fi
  exit 0
fi

# 3. ECS task role / EKS pod identity sidecar.
if [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ] || [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]; then
  printf 'container credentials endpoint (task/pod role) — tier 2\n'
  exit 0
fi

# 4. Mounted config / credentials files (fallback tier).
mounted=""
[ -s "$creds_file" ] && mounted="$creds_file"
[ -s "$config_file" ] && mounted="${mounted:+$mounted, }$config_file"
if [ -n "$mounted" ]; then
  printf 'mounted AWS config (profile %s: %s) — tier 3, lowest priority%s\n' \
    "$profile" "$mounted" "$(aws_sso_note "$config_file")"
  exit 0
fi

# 5. Env pointed at a path with nothing in it — a config error worth naming.
if [ -n "${AWS_CONFIG_FILE:-}" ] || [ -n "${AWS_SHARED_CREDENTIALS_FILE:-}" ]; then
  printf 'AWS_CONFIG_FILE/AWS_SHARED_CREDENTIALS_FILE set but file missing or empty (%s) — AWS calls will fail\n' \
    "${AWS_CONFIG_FILE:-$AWS_SHARED_CREDENTIALS_FILE}"
  exit 0
fi

# 6. Nothing wired here: the chain may still reach EC2 IMDSv2 (instance profile).
printf 'none detected in env/mounts — SDK falls back to an EC2 instance profile (IMDSv2) if present, else AWS calls fail; see README AWS CLI auth tiers\n'
exit 0
