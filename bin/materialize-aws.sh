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

# ── aws-sso auth workflow: report the effective value, warn when unpinned ──
# aws-sso >= 2.2.0 defaults to the PKCE workflow. PKCE waits for the browser to
# redirect to a loopback listener (127.0.0.1:<port>) inside THIS pod's network
# namespace, which an operator browser outside the cluster can never reach, so
# `aws-sso login` hangs and no session is cached. The only fix is a TOP-LEVEL
# `AuthWorkflow: device_code` in the file aws-sso actually reads.
#
# That pin is consumer config (ConfigMap), not something this image ships: an
# overlay whose config.yaml was copied before the pin existed reproduces the
# hang on any image, including a current release. So report what is effective at
# boot — answerable from `kubectl logs` without shelling into the pod — and name
# the two silent ways it gets lost (wrong nesting, legacy config dir).
aws_sso_conf="${AWS_SSO_CONFIG:-$HOME/.config/aws-sso/config.yaml}"
if [ -f "$aws_sso_conf" ]; then
  _workflow="$(sed -n 's/^AuthWorkflow:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$aws_sso_conf" | head -1)"
  case "$_workflow" in
    device_code)
      log "aws-sso config: AuthWorkflow=device_code (top level of $aws_sso_conf)"
      ;;
    "")
      if grep -qE '^[[:space:]]+AuthWorkflow:' "$aws_sso_conf"; then
        log "WARN: aws-sso config: AuthWorkflow is INDENTED in $aws_sso_conf (nested under a block such as SSOConfig). aws-sso reads it only at the TOP LEVEL, so it is ignored and login falls back to pkce — which cannot complete from 'kubectl exec' (its 127.0.0.1 callback is inside the pod). Move the line to the top level of the aws-sso ConfigMap and restart the pod."
      else
        log "WARN: aws-sso config: no 'AuthWorkflow: device_code' in $aws_sso_conf. aws-sso >= 2.2.0 then defaults to pkce, whose 127.0.0.1 callback an operator browser outside the pod cannot reach: 'aws-sso login' hangs and no session is cached. Add 'AuthWorkflow: device_code' at the TOP LEVEL of the aws-sso ConfigMap and restart the pod."
      fi
      ;;
    *)
      log "WARN: aws-sso config: AuthWorkflow=$_workflow in $aws_sso_conf. Only device_code works from 'kubectl exec' in this image; pkce waits on a 127.0.0.1 callback inside the pod. Ignore this if you deliberately port-forward that callback."
      ;;
  esac
  unset _workflow
fi
# aws-sso prefers the legacy ~/.aws-sso directory over ~/.config/aws-sso when it
# exists, so a stray copy there silently wins over the linked ConfigMap file.
if [ -d "${HOME}/.aws-sso" ]; then
  log "WARN: ${HOME}/.aws-sso exists and aws-sso prefers it over ${HOME}/.config/aws-sso — the ConfigMap-linked config.yaml is being IGNORED. Remove that directory and restart the pod."
fi

# Fail closed for accidental defaults: never export a profile from the entrypoint.
unset AWS_PROFILE || true
