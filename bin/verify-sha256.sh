#!/usr/bin/env bash
# Fail-closed SHA-256 check for a downloaded artifact.
#
# Usage: verify-sha256.sh <file> <expected-sha256> <label>
#
# Non-zero (and nothing installed) when the artifact is missing, the expected
# hash is absent or malformed, or it does not match the file. Pinned installs in
# the Dockerfile call this *before* extracting, so a version bump that forgot its
# paired checksum breaks the build instead of shipping an unverified tarball.
#
# This is an integrity + pin check, not a signature check: the hash and the
# artifact come from the same upstream origin.
set -euo pipefail

file="${1:-}"
want="${2:-}"
label="${3:-artifact}"

if [ -z "$file" ] || [ ! -f "$file" ]; then
  printf '%s: artifact not found: %s\n' "$label" "${file:-<none>}" >&2
  exit 1
fi

if ! printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$'; then
  printf '%s: no pinned SHA-256 (got: %s) — refusing to install an unverified artifact\n' \
    "$label" "${want:-<empty>}" >&2
  exit 1
fi

if ! printf '%s  %s\n' "$want" "$file" | sha256sum -c -; then
  printf '%s: SHA-256 mismatch — refusing to install an unverified artifact\n' "$label" >&2
  exit 1
fi
