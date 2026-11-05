#!/usr/bin/env bash
# Optional egress control: client half of a MITM egress proxy (iron-proxy).
#
# Division of labour (important): the PROXY enforces egress policy — it answers
# DNS, terminates TLS, applies a default-deny allowlist and (optionally) swaps
# placeholder tokens for real secrets. Routing traffic to it is a DEPLOYMENT
# decision this container cannot make from the inside (docker `--dns` / compose
# `dns:` / k8s `dnsConfig` must point at the proxy's IP). What this image owns is
# the other half of the contract:
#
#   1. Trust the proxy's MITM CA. The agent user is non-root and cannot write
#      /etc/ssl/certs, so trust is delivered through each toolchain's CA env
#      var, pointing at one bundle = system CAs + the proxy CA.
#   2. Fail CLOSED. Enabled but no usable CA → non-zero exit (CrashLoop), never
#      a silent fallback to direct egress and never a "-k / skip verify" path.
#   3. Say what happened at boot, so "why is everything 403" is one log line.
#
# Knobs:
#
#   MULTICA_EGRESS_PROXY=off|iron-proxy   default off (today's direct egress)
#   MULTICA_EGRESS_PROXY_CA=<path>        default /run/certs/iron-proxy/ca.crt
#   MULTICA_EGRESS_PROXY_PROBE_URL=<url>  optional advisory reachability probe
#                                         (a request the allowlist should allow)
#   MULTICA_EGRESS_PROXY_BUNDLE=<path>    default $MULTICA_HOME/egress-ca-bundle.crt
#   MULTICA_EGRESS_SYSTEM_BUNDLE=<path>   default /etc/ssl/certs/ca-certificates.crt
#
# Managed env (exported, so the daemon and every task it spawns inherit them):
#   SSL_CERT_FILE, CURL_CA_BUNDLE, REQUESTS_CA_BUNDLE, NODE_EXTRA_CA_CERTS,
#   GIT_SSL_CAINFO, AWS_CA_BUNDLE  — all → the combined bundle above.
#
# Sourced by entrypoint.sh (functions only); also runnable standalone to
# validate the current environment. Unit-tested by test/unit/egress-proxy.sh.
#
# shellcheck shell=bash

egress_log() { printf '%s\n' "$*" >&2; }

egress_proxy_known_modes() { printf '%s\n' off iron-proxy; }

# Normalize + validate MULTICA_EGRESS_PROXY. Prints the effective mode.
egress_proxy_mode() {
  local raw
  raw="$(printf '%s' "${MULTICA_EGRESS_PROXY:-off}" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    "" | off) printf 'off\n' ;;
    iron-proxy) printf 'iron-proxy\n' ;;
    *)
      egress_log "FATAL: MULTICA_EGRESS_PROXY='${MULTICA_EGRESS_PROXY}' is not a known mode (expected off | iron-proxy)"
      return 1
      ;;
  esac
}

egress_proxy_ca_path() { printf '%s\n' "${MULTICA_EGRESS_PROXY_CA:-/run/certs/iron-proxy/ca.crt}"; }

egress_proxy_system_bundle() {
  printf '%s\n' "${MULTICA_EGRESS_SYSTEM_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
}

egress_proxy_bundle_path() {
  if [ -n "${MULTICA_EGRESS_PROXY_BUNDLE:-}" ]; then
    printf '%s\n' "$MULTICA_EGRESS_PROXY_BUNDLE"
  else
    printf '%s\n' "${MULTICA_HOME:-$HOME/.multica}/egress-ca-bundle.crt"
  fi
}

# Is $1 a usable PEM certificate? Every failure is fatal at the call site — a
# half-trusted TLS path is worse than a loud CrashLoop.
egress_proxy_ca_ok() {
  local ca="$1"
  if [ -z "$ca" ]; then
    egress_log "FATAL: egress proxy CA path is empty"
    return 1
  fi
  if [ ! -e "$ca" ]; then
    egress_log "FATAL: egress proxy CA not found at $ca — mount the proxy CA (ca.crt) there or set MULTICA_EGRESS_PROXY_CA"
    return 1
  fi
  if [ ! -r "$ca" ]; then
    egress_log "FATAL: egress proxy CA at $ca is not readable by uid $(id -u) — check the mount's file mode"
    return 1
  fi
  if [ ! -s "$ca" ]; then
    egress_log "FATAL: egress proxy CA at $ca is empty"
    return 1
  fi
  if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$ca"; then
    egress_log "FATAL: egress proxy CA at $ca is not a PEM certificate (expected -----BEGIN CERTIFICATE-----)"
    return 1
  fi
  if command -v openssl >/dev/null 2>&1; then
    if ! openssl x509 -in "$ca" -noout >/dev/null 2>&1; then
      egress_log "FATAL: egress proxy CA at $ca does not parse as an X.509 certificate"
      return 1
    fi
    if ! openssl x509 -in "$ca" -noout -checkend 0 >/dev/null 2>&1; then
      egress_log "FATAL: egress proxy CA at $ca has expired — regenerate it and recreate the proxy + this container (an expired CA fails every TLS request closed)"
      return 1
    fi
  fi
  return 0
}

# Write system CAs + proxy CA to one bundle so nothing loses public trust when
# the proxy CA is added. Atomic-ish: temp file then rename, so a concurrent task
# never reads a partially written bundle.
egress_proxy_build_bundle() {
  local ca="$1" bundle="$2" system tmp
  system="$(egress_proxy_system_bundle)"
  if ! mkdir -p "$(dirname "$bundle")"; then
    egress_log "FATAL: cannot create CA bundle directory for $bundle"
    return 1
  fi
  tmp="${bundle}.tmp.$$"
  if ! : >"$tmp"; then
    egress_log "FATAL: cannot write CA bundle at $tmp"
    return 1
  fi
  if [ -f "$system" ]; then
    cat "$system" >>"$tmp" || { rm -f "$tmp"; return 1; }
  else
    # Non-Debian base or a stripped image: still correct, just narrower trust.
    egress_log "WARN: system CA bundle $system not found — the egress bundle trusts the proxy CA only"
  fi
  cat "$ca" >>"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0644 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$bundle"; then
    rm -f "$tmp"
    egress_log "FATAL: cannot install CA bundle at $bundle"
    return 1
  fi
  return 0
}

# Trust each toolchain's own CA knob. There is no single cross-language setting:
# Go (multica CLI, gh, git's HTTP backend when built with Go) reads SSL_CERT_FILE,
# curl/git read CURL_CA_BUNDLE/GIT_SSL_CAINFO, Node/Bun (Claude Code native
# binary) reads NODE_EXTRA_CA_CERTS, Python (AWS CLI v2) reads
# REQUESTS_CA_BUNDLE, botocore reads AWS_CA_BUNDLE.
egress_proxy_export_env() {
  local bundle="$1"
  export SSL_CERT_FILE="$bundle"
  export CURL_CA_BUNDLE="$bundle"
  export REQUESTS_CA_BUNDLE="$bundle"
  export NODE_EXTRA_CA_CERTS="$bundle"
  export GIT_SSL_CAINFO="$bundle"
  export AWS_CA_BUNDLE="$bundle"
}

# Advisory only: proves DNS routing + allowlist actually reach a host. Never
# fatal (a network blip must not CrashLoop a healthy runtime; the proxy's own
# 403/audit log is the authority on policy).
egress_proxy_probe() {
  local url="${MULTICA_EGRESS_PROXY_PROBE_URL:-}" code
  [ -n "$url" ] || return 0
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --max-time "${MULTICA_EGRESS_PROXY_PROBE_TIMEOUT:-8}" "$url" 2>/dev/null || true)"
  case "$code" in
    2* | 3*)
      egress_log "egress proxy: probe OK (HTTP $code from $url)"
      return 0
      ;;
    *)
      egress_log "egress proxy: WARN probe failed (HTTP '${code:-none}' for $url) — check DNS routing points at the proxy and that the host is in its allowlist; boot continues (probe is advisory)"
      return 1
      ;;
  esac
}

# Boot entry point. Returns non-zero (caller dies → CrashLoop) when egress
# control is requested but cannot be honoured.
egress_proxy_boot() {
  local mode ca bundle
  if ! mode="$(egress_proxy_mode)"; then
    return 1
  fi

  if [ "$mode" = "off" ]; then
    if [ -n "${MULTICA_EGRESS_PROXY_CA:-}" ]; then
      egress_log "egress proxy: off (MULTICA_EGRESS_PROXY_CA is ignored unless MULTICA_EGRESS_PROXY=iron-proxy)"
    fi
    egress_log "egress proxy: off — direct egress, no MITM CA trusted (set MULTICA_EGRESS_PROXY=iron-proxy to route through a proxy)"
    return 0
  fi

  ca="$(egress_proxy_ca_path)"
  if ! egress_proxy_ca_ok "$ca"; then
    return 1
  fi
  bundle="$(egress_proxy_bundle_path)"
  if ! egress_proxy_build_bundle "$ca" "$bundle"; then
    return 1
  fi
  egress_proxy_export_env "$bundle"
  egress_log "egress proxy: iron-proxy — MITM CA trusted via $bundle (SSL_CERT_FILE/CURL_CA_BUNDLE/REQUESTS_CA_BUNDLE/NODE_EXTRA_CA_CERTS/GIT_SSL_CAINFO/AWS_CA_BUNDLE)"
  egress_log "egress proxy: DNS routing is deployment-side — this container only trusts the CA; point --dns / compose dns: / k8s dnsConfig at the proxy IP or traffic bypasses policy"
  egress_proxy_probe || true
  return 0
}

# Standalone use: ./egress-proxy.sh → validate the current environment.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  egress_proxy_boot
fi
