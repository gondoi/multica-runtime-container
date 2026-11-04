#!/usr/bin/env bash
# Guard wrapper around upstream aws-sso (real binary at /usr/local/libexec/aws-sso).
#
# Contract: `aws-sso login` is operator-exec only. Agents use the existing SSO
# cache on the workspaces PVC. Dead cache → AWS calls fail closed; agents must
# not mint a fresh Identity Center consent URL.
#
# Operator login:
#   AWS_SSO_OPERATOR_LOGIN=1 aws-sso login --url-action=print
set -euo pipefail

REAL="${AWS_SSO_REAL_BIN:-/usr/local/libexec/aws-sso}"
cmd="${1:-}"

if [ "$cmd" = "login" ] && [ "${AWS_SSO_OPERATOR_LOGIN:-}" != "1" ]; then
  printf '%s\n' \
    "FATAL: aws-sso login is operator-exec only (agents must not drive SSO)." \
    "Re-run with AWS_SSO_OPERATOR_LOGIN=1, e.g.:" \
    "  kubectl exec -it deploy/multica-runtime -n <ns> -- env AWS_SSO_OPERATOR_LOGIN=1 aws-sso login --url-action=print" \
    >&2
  exit 2
fi

exec "$REAL" "$@"
