#!/usr/bin/env bash
# Generate the MITM CA that iron-proxy uses to re-sign TLS for the runtime
# container, and that the runtime container trusts.
#
# iron-proxy mints a leaf certificate per host from this CA, so the CA's private
# key is deployment secret material: it stays in examples/iron-proxy/certs/
# (git-ignored) and is mounted read-only into the proxy only. The runtime gets
# ca.crt — never ca.key.
#
# Rotating the CA means recreating both containers (leaf certs are cached per
# proxy process, and the runtime's trust bundle is built at boot).
#
# Prefers the pinned upstream image (`iron-proxy generate-ca`, no host openssl
# needed); falls back to openssl when Docker is unavailable.
#
# Usage: ./gen-ca.sh [output-dir]     (default: examples/iron-proxy/certs)
#   PROXY_IMAGE=<ref>  override the proxy image (keep it equal to the tag in
#                      docker-compose.yml)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/certs}"
image="${PROXY_IMAGE:-ironsh/iron-proxy:0.56.0}"

mkdir -p "$out"
chmod 700 "$out"

if [ -f "$out/ca.crt" ] || [ -f "$out/ca.key" ]; then
  echo "CA already present in $out — refusing to overwrite (a new CA invalidates" >&2
  echo "every running proxy leaf cert and the runtime's boot-time trust bundle)." >&2
  echo "Delete $out/ca.crt and $out/ca.key first if that is what you want." >&2
  exit 0
fi

if command -v docker >/dev/null 2>&1; then
  # Run as the invoking user so the key is not root-owned on the host.
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$out:/certs" \
    "$image" generate-ca -outdir /certs \
    -name "multica-runtime iron-proxy CA" -expiry-hours 87600
elif command -v openssl >/dev/null 2>&1; then
  umask 077
  openssl genrsa -out "$out/ca.key" 4096
  openssl req -x509 -new -nodes -key "$out/ca.key" -sha256 -days 3650 \
    -subj "/CN=multica-runtime iron-proxy CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign" \
    -out "$out/ca.crt"
else
  echo "FATAL: need either docker (preferred) or openssl to generate the CA" >&2
  exit 1
fi

chmod 600 "$out/ca.key"
chmod 644 "$out/ca.crt"

echo "CA written to $out (ca.key is secret — never commit it, never mount it into the runtime container)"
