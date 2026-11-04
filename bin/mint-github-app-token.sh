#!/usr/bin/env bash
# Mint a short-lived GitHub App installation access token.
#
# Required env (or files — see materialize-secrets.sh):
#   GITHUB_APP_ID
#   GITHUB_APP_INSTALLATION_ID
#   GITHUB_APP_PRIVATE_KEY          (PEM text) — or —
#   GITHUB_APP_PRIVATE_KEY_FILE     (path to PEM; default /run/secrets/git/GITHUB_APP_PRIVATE_KEY)
#
# Optional:
#   GITHUB_API_URL                  (default https://api.github.com)
#
# Prints the token to stdout. Logs go to stderr. Exit 1 on failure.
# Does not echo the private key or token on stderr.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

API_URL="${GITHUB_API_URL:-https://api.github.com}"
KEY_FILE="${GITHUB_APP_PRIVATE_KEY_FILE:-/run/secrets/git/GITHUB_APP_PRIVATE_KEY}"
ID_FILE="${GITHUB_APP_ID_FILE:-/run/secrets/git/GITHUB_APP_ID}"
INSTALLATION_ID_FILE="${GITHUB_APP_INSTALLATION_ID_FILE:-/run/secrets/git/GITHUB_APP_INSTALLATION_ID}"

# Prefer env; fall back to Secret file mounts (credential helper has no boot env).
APP_ID="${GITHUB_APP_ID:-}"
if [ -z "$APP_ID" ] && [ -f "$ID_FILE" ]; then
  APP_ID="$(tr -d '\r\n' <"$ID_FILE")"
fi
INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:-}"
if [ -z "$INSTALLATION_ID" ] && [ -f "$INSTALLATION_ID_FILE" ]; then
  INSTALLATION_ID="$(tr -d '\r\n' <"$INSTALLATION_ID_FILE")"
fi

[ -n "$APP_ID" ] || die "GITHUB_APP_ID is required (env or $ID_FILE)"
[ -n "$INSTALLATION_ID" ] || die "GITHUB_APP_INSTALLATION_ID is required (env or $INSTALLATION_ID_FILE)"

TMP_KEY=""
cleanup() {
  if [ -n "$TMP_KEY" ] && [ -f "$TMP_KEY" ]; then
    rm -f "$TMP_KEY"
  fi
}
trap cleanup EXIT

# Prefer PEM file mount (stable newlines) over env when both exist.
if [ -f "$KEY_FILE" ] && [ -s "$KEY_FILE" ]; then
  KEY_PATH="$KEY_FILE"
elif [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]; then
  TMP_KEY="$(mktemp)"
  chmod 600 "$TMP_KEY"
  printf '%s\n' "$GITHUB_APP_PRIVATE_KEY" >"$TMP_KEY"
  KEY_PATH="$TMP_KEY"
else
  die "GITHUB_APP_PRIVATE_KEY (env) or PEM file at $KEY_FILE required"
fi

command -v openssl >/dev/null 2>&1 || die "openssl required to sign App JWT"
command -v curl >/dev/null 2>&1 || die "curl required to mint installation token"
command -v jq >/dev/null 2>&1 || die "jq required to parse installation token response"

b64url() {
  # stdin → base64url without padding
  openssl base64 -e -A 2>/dev/null | tr '+/' '-_' | tr -d '='
}

now="$(date +%s)"
iat=$((now - 60))
exp=$((now + 540)) # GitHub max JWT lifetime is 10m; stay under

header='{"alg":"RS256","typ":"JWT"}'
payload="$(jq -nc --argjson iat "$iat" --argjson exp "$exp" --arg iss "$APP_ID" \
  '{iat:$iat,exp:$exp,iss:$iss}')"

h_b64="$(printf '%s' "$header" | b64url)"
p_b64="$(printf '%s' "$payload" | b64url)"
unsigned="${h_b64}.${p_b64}"

sig_b64="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$KEY_PATH" | b64url)" \
  || die "failed to sign App JWT (check PEM / App ID)"
jwt="${unsigned}.${sig_b64}"

resp_file="$(mktemp)"
trap 'cleanup; rm -f "$resp_file"' EXIT
http_code="$(curl -sS -o "$resp_file" -w '%{http_code}' \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${jwt}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${API_URL%/}/app/installations/${INSTALLATION_ID}/access_tokens" || true)"

if [ "$http_code" != "201" ] && [ "$http_code" != "200" ]; then
  die "installation token mint failed (HTTP ${http_code})"
fi

token="$(jq -r '.token // empty' "$resp_file")"
[ -n "$token" ] || die "installation token mint returned empty token"
printf '%s' "$token"
log "github App installation token minted (installation=${INSTALLATION_ID})"
