# Egress control (optional): iron-proxy evaluation

Status: **adopted as an opt-in deployment pattern; container-side support
shipped; Kubernetes deferred; secret injection not enabled (needs owner
sign-off)**. Default behaviour is unchanged: `MULTICA_EGRESS_PROXY` is unset,
which means direct egress, exactly as before this change.

This page records the evaluation behind that decision, what is actually
implemented, what is still open, and how to undo it.

## The problem

A runtime container runs untrusted-ish code: agent tasks execute arbitrary
shell, `repo checkout` clones whatever a task names, `asdf` installs
toolchains, and the harnesses hold long-lived credentials
(`CURSOR_API_KEY`, `ANTHROPIC_API_KEY`/OAuth token, `GITHUB_TOKEN`, AWS
roles). Nothing in the image constrains where that process may connect. A
prompt-injected task or a compromised dependency can exfiltrate to any host it
can resolve, and there is no record of where traffic went.

## What iron-proxy is

[`ironsh/iron-proxy`](https://github.com/ironsh/iron-proxy) — Apache-2.0, Go,
single binary, single YAML config. Relevant properties, all checked against the
upstream README/config source at the time of writing:

| Property | Detail |
| --- | --- |
| Default-deny egress | Requests must match a domain glob or CIDR in the `allowlist` transform; everything else gets **403** and a WARN audit entry |
| Built-in DNS | Answers every intercepted lookup with `proxy_ip`, which is what routes workload traffic through the proxy (no proxy env vars required) |
| MITM TLS | Mints a leaf cert per host from a CA you provide; the workload must trust that CA |
| Upstream deny list | On by default: `169.254.169.254/32`, `fd00:ec2::254/128`, `fd20:ce::254/128`, `127.0.0.0/8`, `::1/128` — closes the "allowlisted name points at IMDS/loopback" SSRF gap |
| Structured audit log | One JSON line per request: host, method, path, action, status, transform trace; rejections carry `rejected_by` |
| Streaming | WebSocket + SSE proxied natively (agent task streams) |
| `warn: true` | Observe-only allowlist mode for rollout |
| Secret injection | Placeholder tokens in the workload, real secrets swapped in at egress — **not enabled here** |

Current release at evaluation time: **v0.56.0** (Docker Hub tag `0.56.0` — the
pinned tag drops the `v`). Upstream also ships a Helm chart
(`charts/iron-proxy`, chart `0.1.0`) and three routing options.

## Decision

| Question | Decision | Why |
| --- | --- | --- |
| Adopt iron-proxy? | **Yes, opt-in** | Purpose-built for exactly this workload class (CI/agent sandboxes); default-deny + audit log is the security win; single sidecar, no code in the image |
| Default on or off? | **Off** (`MULTICA_EGRESS_PROXY` unset) | Turning it on by default would break every existing deployment whose allowlist is not yet complete — blast radius is *every* agent run, not a narrow surface |
| Compose first? | **Yes** | The documented upstream flow is Docker-shaped: static proxy IP + `dns:` + CA mount. Verified working end to end here |
| Kubernetes? | **Deferred** | The chart exists, but the parts that actually decide success are deployment-specific: the DNS answer must be the reachable Service IP, pods need `dnsConfig` pointing at it, and `NetworkPolicy` should block everything except the proxy. That is a cluster-side design decision, not a runtime-image change |
| Enforced (non-bypassable) egress? | **Not yet** | DNS routing is bypassable by design (hardcoded IPs, own resolver — upstream says so). Closing that needs nftables/TPROXY with `NET_ADMIN` inside the workload container, which this image does not carry and which changes the deployment's capability surface. Its own follow-up decision |
| Secret injection (real secrets on the proxy, placeholders in the container)? | **Not enabled — owner sign-off required** | It relocates credentials: the proxy becomes the only holder of the real Anthropic/GitHub tokens. That changes blast radius and the secrets layout, so it is not something this change does silently |

### What the container itself can and cannot do

The proxy enforces; the deployment routes; **this image only makes the TLS half
work**. It cannot re-point its own resolver, so:

| Concern | Owner |
| --- | --- |
| Allowlist contents, audit log, 403 policy | Deployment (proxy config) — start from `examples/iron-proxy/proxy.yaml` |
| DNS routing to the proxy (`--dns`, compose `dns:`, k8s `dnsConfig`) | Deployment |
| Trusting the proxy's MITM CA in every toolchain | **This image** (`bin/egress-proxy.sh`) |
| Failing closed when the CA is missing/unusable | **This image** |

## What shipped in this image

`MULTICA_EGRESS_PROXY=iron-proxy` makes boot:

1. **Require a usable CA** at `MULTICA_EGRESS_PROXY_CA`
   (default `/run/certs/iron-proxy/ca.crt`). Missing, empty, non-PEM, unparseable
   or expired → **non-zero exit** (CrashLoop). There is no "skip verification"
   path and no silent fallback to direct egress.
2. **Build one bundle** = the OS trust store + the proxy CA, at
   `$MULTICA_HOME/egress-ca-bundle.crt`, written atomically.
3. **Export it through every relevant toolchain knob**, so the daemon and every
   task it spawns inherit trust:
   `SSL_CERT_FILE` (Go: `multica`, `gh`), `CURL_CA_BUNDLE`,
   `GIT_SSL_CAINFO` (git/curl), `NODE_EXTRA_CA_CERTS` (Node/Bun: Claude Code
   native binary), `REQUESTS_CA_BUNDLE` (AWS CLI v2), `AWS_CA_BUNDLE`
   (botocore).
4. **Report the mode at boot**, including the explicit statement that DNS
   routing is the deployment's job — so nobody reads "enabled" as "enforced".
5. Optionally run an **advisory probe** (`MULTICA_EGRESS_PROXY_PROBE_URL`);
   failure warns and boots anyway, because a network blip must not CrashLoop a
   healthy runtime.

`MULTICA_EGRESS_PROXY=off` (default) exports nothing and logs
`egress proxy: off`.

Worked example: [`examples/iron-proxy/`](../examples/iron-proxy/) — proxy
sidecar, CA generation, allowlist scoped to this image's own egress, rollback
instructions.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| **Availability**: an incomplete allowlist breaks *all* outbound calls, including `multica login` at boot → CrashLoop | Roll out with `warn: true`, run one task per harness, then enforce. The example allowlist covers Multica + Anthropic + Cursor + GitHub + registries as a starting point |
| **MITM CA drift** (proxy recreated with a new CA, workload still trusts the old one) | CA validation is a hard gate; expired/invalid CA fails closed with an actionable message; boot log names the bundle path |
| **Allowlist erosion / maintenance** | Documented as ongoing work: every new MCP server, registry, or vendor endpoint needs an allowlist change. Owned by whoever owns the deployment |
| **DNS bypass** | Explicitly *not* claimed as enforcement in code or docs. nftables/TPROXY remains a follow-up |
| **Secrets still in the container** (no injection enabled) | Unchanged from today; a compromise can still exfiltrate tokens to an allowlisted host. Secret injection is the follow-up that fixes this, gated on owner sign-off |
| **`asdf`/`wget` downloads** that ignore the CA env vars | `curl`-based installs work; `wget`-based ones may need `--ca-certificate`. Documented, not silently assumed solved |

## Verification

Offline (CI, `test/boot/run-seam.sh`): fail-closed crash fixture, CA bundle
composition, daemon-env inheritance, and the off-mode rollback contract.
Unit: `test/unit/egress-proxy.sh` (13 checks).

End-to-end (`test/integration/egress-proxy.sh`, opt-in: Docker + internet):

```
PASS  runtime Ready behind the egress proxy
PASS  allowlisted host reachable through the proxy (HTTP 200)
PASS  TLS fails closed without the proxy CA (traffic really is MITM'd)
PASS  non-allowlisted host rejected with 403
PASS  proxy audit log records the rejection (rejected_by field)
```

That run used the boot-seam stub `multica`, i.e. it proves the *egress* path,
not a real harness conversation. A first real task per harness (`cursor`,
`claude`) is still worth running against the example before trusting the
allowlist in production — the harness CLIs talk to endpoints we cannot
enumerate for you.

## Rollback

Nothing about the image or the secrets layout changes, so rollback is one flip:

```bash
# compose: drop the dns:/MULTICA_EGRESS_PROXY knobs and the CA mount — or point
# at the plain compose file again
docker compose up -d
```

The next boot logs `egress proxy: off` and connects directly, as before. If a
*daemon* change is needed (e.g. a stale bundle in a long-lived container), it is
recreated on the next boot anyway — `$MULTICA_HOME` is ephemeral.
