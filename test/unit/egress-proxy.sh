#!/usr/bin/env bash
# Unit check: bin/egress-proxy.sh — mode parsing, fail-closed CA validation,
# combined-bundle construction and the CA env exports each toolchain reads.
# No Docker, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/bin/egress-proxy.sh"
FIXTURE_CA="$ROOT/test/boot/fixtures/certs/iron-proxy/ca.crt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }

chmod +x "$LIB"

# Stand-in for the OS trust store so assertions are stable on any distro.
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'SYSTEM-CA-MARKER' '-----END CERTIFICATE-----' \
  >"$WORK/system-bundle.crt"

# Probe variant: sources the library and reports the outcome + resulting env in
# a stable, greppable form. Each probe runs in its own shell so exports never
# leak between cases.
cat >"$WORK/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1090
source "$LIB"
rc=0
egress_proxy_boot 2>"$PROBE_ERR" || rc=$?
printf 'rc=%s\n' "$rc"
printf 'ssl_cert_file=%s\n' "${SSL_CERT_FILE:-}"
printf 'curl_ca_bundle=%s\n' "${CURL_CA_BUNDLE:-}"
printf 'requests_ca_bundle=%s\n' "${REQUESTS_CA_BUNDLE:-}"
printf 'node_extra_ca_certs=%s\n' "${NODE_EXTRA_CA_CERTS:-}"
printf 'git_ssl_cainfo=%s\n' "${GIT_SSL_CAINFO:-}"
printf 'aws_ca_bundle=%s\n' "${AWS_CA_BUNDLE:-}"
PROBE
chmod +x "$WORK/probe.sh"

# run_case [VAR=value ...] — prints the probe report (callers assert the rc).
run_case() {
  local out
  out="$(env -u MULTICA_EGRESS_PROXY -u MULTICA_EGRESS_PROXY_CA \
    -u MULTICA_EGRESS_PROXY_BUNDLE -u MULTICA_EGRESS_PROXY_PROBE_URL \
    -u SSL_CERT_FILE -u CURL_CA_BUNDLE -u REQUESTS_CA_BUNDLE \
    -u NODE_EXTRA_CA_CERTS -u GIT_SSL_CAINFO -u AWS_CA_BUNDLE \
    LIB="$LIB" PROBE_ERR="$WORK/err" \
    HOME="$WORK/home" MULTICA_HOME="$WORK/multica-home" \
    MULTICA_EGRESS_SYSTEM_BUNDLE="$WORK/system-bundle.crt" \
    "$@" "$WORK/probe.sh")"
  printf '%s\n' "$out"
  return 0
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# ── 1. Default: off → nothing exported, boot continues ─────────────────────
out="$(run_case)"
if [ "$(field "$out" rc)" = 0 ] \
  && [ -z "$(field "$out" ssl_cert_file)" ] \
  && [ -z "$(field "$out" node_extra_ca_certs)" ]; then
  ok "default (unset) = off, no CA env exported (existing deployments unchanged)"
else
  bad "default/setup case: rc=$(field "$out" rc) ssl=$(field "$out" ssl_cert_file)"
  cat "$WORK/err" >&2 || true
fi
if grep -q 'egress proxy: off' "$WORK/err"; then
  ok "boot states direct egress when disabled"
else
  bad "boot did not report 'egress proxy: off'"
  cat "$WORK/err" >&2 || true
fi

# ── 2. Explicit off + a stray CA path → still off, warns it is ignored ─────
out="$(run_case MULTICA_EGRESS_PROXY=off MULTICA_EGRESS_PROXY_CA="$FIXTURE_CA")"
if [ "$(field "$out" rc)" = 0 ] && [ -z "$(field "$out" ssl_cert_file)" ] \
  && grep -q 'MULTICA_EGRESS_PROXY_CA is ignored' "$WORK/err"; then
  ok "MULTICA_EGRESS_PROXY=off ignores a CA path (with a warning)"
else
  bad "explicit off did not stay off / did not warn about the ignored CA"
  cat "$WORK/err" >&2 || true
fi

# ── 3. Unknown mode → hard fail (typo must not silently mean "off") ───────
out="$(run_case MULTICA_EGRESS_PROXY=ironproxy)"
if [ "$(field "$out" rc)" != 0 ] && grep -q 'not a known mode' "$WORK/err"; then
  ok "unknown MULTICA_EGRESS_PROXY fails the boot (typo is not silently 'off')"
else
  bad "unknown mode did not fail: rc=$(field "$out" rc)"
  cat "$WORK/err" >&2 || true
fi

# ── 4. Enabled without a CA → fail closed (never direct egress) ───────────
out="$(run_case MULTICA_EGRESS_PROXY=iron-proxy \
  MULTICA_EGRESS_PROXY_CA="$WORK/does-not-exist.crt")"
if [ "$(field "$out" rc)" != 0 ] && [ -z "$(field "$out" ssl_cert_file)" ] \
  && grep -q 'CA not found' "$WORK/err"; then
  ok "iron-proxy without a mounted CA fails closed (no silent direct egress)"
else
  bad "missing CA did not fail closed: rc=$(field "$out" rc)"
  cat "$WORK/err" >&2 || true
fi

# ── 5. Non-PEM garbage at the CA path → fail closed ───────────────────────
printf 'not a certificate\n' >"$WORK/garbage.crt"
out="$(run_case MULTICA_EGRESS_PROXY=iron-proxy MULTICA_EGRESS_PROXY_CA="$WORK/garbage.crt")"
if [ "$(field "$out" rc)" != 0 ] && grep -q 'is not a PEM certificate' "$WORK/err"; then
  ok "non-PEM CA fails closed"
else
  bad "non-PEM CA did not fail: rc=$(field "$out" rc)"
  cat "$WORK/err" >&2 || true
fi

# ── 6. Empty CA file → fail closed ────────────────────────────────────────
: >"$WORK/empty.crt"
out="$(run_case MULTICA_EGRESS_PROXY=iron-proxy MULTICA_EGRESS_PROXY_CA="$WORK/empty.crt")"
if [ "$(field "$out" rc)" != 0 ] && grep -q 'is empty' "$WORK/err"; then
  ok "empty CA file fails closed"
else
  bad "empty CA did not fail: rc=$(field "$out" rc)"
  cat "$WORK/err" >&2 || true
fi

# ── 7. Valid CA → every toolchain CA knob points at one combined bundle ────
out="$(run_case MULTICA_EGRESS_PROXY=iron-proxy MULTICA_EGRESS_PROXY_CA="$FIXTURE_CA")"
bundle="$WORK/multica-home/egress-ca-bundle.crt"
all_exported=1
for var in ssl_cert_file curl_ca_bundle requests_ca_bundle \
  node_extra_ca_certs git_ssl_cainfo aws_ca_bundle; do
  [ "$(field "$out" "$var")" = "$bundle" ] || { all_exported=0; bad "export $var=$(field "$out" "$var") (want $bundle)"; }
done
if [ "$(field "$out" rc)" = 0 ] && [ "$all_exported" = 1 ]; then
  ok "iron-proxy exports all six CA knobs to the combined bundle"
else
  bad "valid CA case: rc=$(field "$out" rc)"
  cat "$WORK/err" >&2 || true
fi
if [ -f "$bundle" ] \
  && grep -q 'SYSTEM-CA-MARKER' "$bundle" \
  && grep -q 'BEGIN CERTIFICATE' "$bundle"; then
  ok "bundle = system CAs + proxy CA (public trust not lost)"
else
  bad "combined bundle missing system marker or proxy CA"
  ls -l "$WORK/multica-home" >&2 || true
fi
if [ -z "$(find "$WORK/multica-home" -maxdepth 1 -name '*.tmp.*' -print -quit)" ]; then
  ok "bundle written atomically (no leftover .tmp file)"
else
  bad "leftover temp bundle file present"
fi
if grep -q 'DNS routing is deployment-side' "$WORK/err"; then
  ok "boot explains that DNS routing is the deployment's job (no false 'enforced' claim)"
else
  bad "boot did not state the DNS-routing division of labour"
  cat "$WORK/err" >&2 || true
fi

# ── 8. Expired CA → fail closed (TLS would fail anyway; say why) ───────────
if command -v openssl >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/expired.key" \
    -not_before 20200101000000Z -not_after 20200102000000Z \
    -subj "/CN=expired fixture CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -out "$WORK/expired.crt" >/dev/null 2>&1 \
    || openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/expired.key" \
      -days -1 -subj "/CN=expired fixture CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -out "$WORK/expired.crt" >/dev/null 2>&1 || true
  if [ -f "$WORK/expired.crt" ]; then
    out="$(run_case MULTICA_EGRESS_PROXY=iron-proxy MULTICA_EGRESS_PROXY_CA="$WORK/expired.crt")"
    if [ "$(field "$out" rc)" != 0 ] && grep -q 'has expired' "$WORK/err"; then
      ok "expired CA fails closed with an actionable message"
    else
      bad "expired CA did not fail closed: rc=$(field "$out" rc)"
      cat "$WORK/err" >&2 || true
    fi
  else
    printf 'SKIP  expired-CA case (this openssl cannot backdate a cert)\n'
  fi
else
  printf 'SKIP  expired-CA case (openssl not installed)\n'
fi

# ── 9. Advisory probe: unreachable URL warns but never fails the boot ─────
out="$(run_case MULTICA_EGRESS_PROXY=iron-proxy MULTICA_EGRESS_PROXY_CA="$FIXTURE_CA" \
  MULTICA_EGRESS_PROXY_PROBE_URL="http://127.0.0.1:1/" MULTICA_EGRESS_PROXY_PROBE_TIMEOUT=1)"
if [ "$(field "$out" rc)" = 0 ] && grep -q 'WARN probe failed' "$WORK/err"; then
  ok "failed egress probe is advisory (warns, boot still succeeds)"
else
  bad "probe failure changed the boot result: rc=$(field "$out" rc)"
  cat "$WORK/err" >&2 || true
fi

if [ "$fail" = 0 ]; then
  printf '\nPASS  egress-proxy: %d checks\n' "$pass"
else
  printf '\nFAIL  egress-proxy: %d failed, %d passed\n' "$fail" "$pass" >&2
fi
[ "$fail" = 0 ]
