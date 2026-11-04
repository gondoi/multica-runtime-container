#!/usr/bin/env bash
# Wire AWS CLI profile + aws-sso config onto durable provider homes.
#
# Continue-on-degrade: missing ConfigMap mounts are OK — daemon still starts.
# When mounts are present, link them into PVC-backed dirs under the workspaces
# root so SSO cache survives pod recreate.
#
# Layout:
#   $MULTICA_WORKSPACES_ROOT/.provider-homes/aws/          → ~/.aws
#   $MULTICA_WORKSPACES_ROOT/.provider-homes/aws-sso/      → ~/.config/aws-sso
#   /run/config/aws/config                                 (ConfigMap, optional)
#   /run/config/aws-sso/config.yaml                         (ConfigMap, optional)
#
# AWS_PROFILE is intentionally left unset (callers pass --profile).
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

WORKSPACES_ROOT="${MULTICA_WORKSPACES_ROOT:-/home/agent/workspaces}"
AWS_HOME_DURABLE="${AWS_HOME_DURABLE:-$WORKSPACES_ROOT/.provider-homes/aws}"
AWS_SSO_DURABLE="${AWS_SSO_DURABLE:-$WORKSPACES_ROOT/.provider-homes/aws-sso}"
AWS_CONFIG_SRC="${AWS_CONFIG_SRC:-/run/config/aws/config}"
AWS_SSO_CONFIG_SRC="${AWS_SSO_CONFIG_SRC:-/run/config/aws-sso/config.yaml}"

mkdir -p "$AWS_HOME_DURABLE" "$AWS_SSO_DURABLE" \
  "$(dirname "$HOME/.aws")" "$(dirname "$HOME/.config/aws-sso")"

# Replace non-symlink leftovers so PVC-backed homes always win.
if [ -e "$HOME/.aws" ] && [ ! -L "$HOME/.aws" ]; then
  rm -rf "$HOME/.aws"
fi
if [ -e "$HOME/.config/aws-sso" ] && [ ! -L "$HOME/.config/aws-sso" ]; then
  rm -rf "$HOME/.config/aws-sso"
fi

ln -sfn "$AWS_HOME_DURABLE" "$HOME/.aws"
ln -sfn "$AWS_SSO_DURABLE" "$HOME/.config/aws-sso"

have_aws_config=0
if [ -f "$AWS_CONFIG_SRC" ]; then
  ln -sfn "$AWS_CONFIG_SRC" "$AWS_HOME_DURABLE/config"
  have_aws_config=1
elif [ -L "$AWS_HOME_DURABLE/config" ] && [ ! -e "$AWS_HOME_DURABLE/config" ]; then
  # Stale symlink from a previous mount — drop so AWS CLI does not trip on it.
  rm -f "$AWS_HOME_DURABLE/config"
fi

have_sso_config=0
if [ -f "$AWS_SSO_CONFIG_SRC" ]; then
  ln -sfn "$AWS_SSO_CONFIG_SRC" "$AWS_SSO_DURABLE/config.yaml"
  have_sso_config=1
elif [ -L "$AWS_SSO_DURABLE/config.yaml" ] && [ ! -e "$AWS_SSO_DURABLE/config.yaml" ]; then
  rm -f "$AWS_SSO_DURABLE/config.yaml"
fi

if [ "$have_aws_config" = 1 ] && [ "$have_sso_config" = 1 ]; then
  log "AWS profiles: config + aws-sso mounted; SSO cache → $AWS_SSO_DURABLE (PVC)"
elif [ "$have_aws_config" = 1 ] || [ "$have_sso_config" = 1 ]; then
  log "AWS profiles: partial mount (aws_config=$have_aws_config aws_sso=$have_sso_config) — continuing degraded"
else
  log "AWS profiles: no ConfigMap mounts at $AWS_CONFIG_SRC / $AWS_SSO_CONFIG_SRC — continuing without AWS"
fi

# Fail closed for accidental defaults: never export a profile from the entrypoint.
unset AWS_PROFILE || true
