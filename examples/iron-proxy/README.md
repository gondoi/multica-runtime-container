# iron-proxy egress sidecar (optional)

A worked, verified setup that puts the runtime container behind
[iron-proxy](https://github.com/ironsh/iron-proxy): default-deny egress to
anything not in the allowlist, a per-request audit log, and TLS that the
container trusts without weakening verification.

**This is not on by default and nothing changes for a plain
`docker compose up` at the repo root.** The evaluation and decision record —
including what is *not* covered (enforced/bypass-proof egress, secret
injection, Kubernetes) — is in
[docs/egress-control.md](../../docs/egress-control.md).

## Files

| File | Role |
| --- | --- |
| `docker-compose.yml` | Proxy + runtime on a private network; runtime DNS → proxy, CA mounted read-only |
| `proxy.yaml` | iron-proxy config: default-deny allowlist scoped to this image's egress, plus the CA/listener wiring |
| `gen-ca.sh` | Generates the MITM CA (`certs/{ca.crt,ca.key}`) with the pinned upstream image; openssl fallback |
| `certs/` | Generated, **git-ignored** — `ca.key` is secret material, `ca.crt` is what the runtime trusts |

## Run it

```bash
# 1. MITM CA (proxy re-signs TLS with it; the runtime trusts ca.crt only)
./examples/iron-proxy/gen-ca.sh

# 2. Same secret layout as the root compose file
mkdir -p secrets/multica-home secrets/cursor secrets/git
cp examples/secrets/multica-home/config.json.example secrets/multica-home/config.json
cp examples/secrets/multica-home/daemon.id.example   secrets/multica-home/daemon.id
printf '%s' "$CURSOR_API_KEY" > secrets/cursor/CURSOR_API_KEY
printf '%s' "$GITHUB_TOKEN"   > secrets/git/GITHUB_TOKEN

# 3. Bring it up
docker compose -f examples/iron-proxy/docker-compose.yml up -d --build
docker compose -f examples/iron-proxy/docker-compose.yml logs -f runtime
docker compose -f examples/iron-proxy/docker-compose.yml logs -f proxy   # audit log
```

Boot log should contain:

```
egress proxy: iron-proxy — MITM CA trusted via /home/agent/.multica/egress-ca-bundle.crt (...)
egress proxy: DNS routing is deployment-side — ...
```

## Verify it is actually working

From inside the runtime container (the `--cacert` is only needed because
`docker exec` starts a new process without the daemon's exported env; the
daemon and every task it spawns already inherit it):

```bash
ca=/home/agent/.multica/egress-ca-bundle.crt
docker compose -f examples/iron-proxy/docker-compose.yml exec runtime \
  curl -sS -o /dev/null -w '%{http_code}\n' --cacert "$ca" https://api.github.com/zen   # 200
docker compose -f examples/iron-proxy/docker-compose.yml exec runtime \
  curl -sS -o /dev/null -w '%{http_code}\n' --cacert "$ca" https://example.com/         # 403
```

The second request shows up in `logs proxy` as a JSON line with
`"rejected_by"`. Before trusting the policy for real, do a `warn: true` rollout
(uncomment it in `proxy.yaml`):
requests that *would* be blocked still go through, annotated `"action":"warn"`,
so the audit log tells you exactly which hosts a real task needs.

Automated end-to-end check (opt-in, needs Docker + internet, not in CI):

```bash
./test/integration/egress-proxy.sh
```

## Pick your own subnet

`proxy.yaml`'s `dns.proxy_ip` and the compose network subnet must agree
(`10.231.0.0/24` here). Avoid ranges your host or VPN already routes — Docker's
default `172.17–172.31` pool collides with Cloudflare WARP and many corporate
VPNs, which shows up as *all* proxied requests timing out while non-proxied
containers work fine. If the runtime container cannot resolve anything, check
that first.

## Consequences to expect

- **Docker's embedded DNS is bypassed** (`dns:` replaces `127.0.0.11`), so
  other compose service names no longer resolve inside the runtime container.
  The proxy itself is reached by static IP, which is what `proxy.yaml` encodes.
- **Allowlist maintenance is ongoing.** A new MCP server, registry or vendor
  endpoint fails until it is added. That is the cost of default-deny.
- **`wget`-based installs** may ignore the exported CA env vars; `curl`-based
  tooling (`asdf` plugins mostly) is covered.
- **The CA key never enters the runtime container** — only `ca.crt` is mounted.

## Roll back

Bring up the plain compose file instead; no image rebuild, no secret changes:

```bash
docker compose -f examples/iron-proxy/docker-compose.yml down
docker compose up -d
```

The next boot logs `egress proxy: off` and connects directly.
