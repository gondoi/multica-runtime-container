## Running in Kubernetes

Usage walkthrough for the example manifests in
[`examples/k8s/`](../examples/k8s/). They implement the same Secret-projection
contract as the local Compose setup — see the [root README](../README.md) for
the full boot contract and GitHub auth tier precedence.

### What's here

| Manifest | Role |
| --- | --- |
| [`namespace.yaml`](../examples/k8s/namespace.yaml) | `multica-runtime` namespace (deploy-time name — replace it) |
| [`serviceaccount.yaml`](../examples/k8s/serviceaccount.yaml) | ServiceAccount for the pod — IRSA annotation point for AWS creds |
| [`secret.example.yaml`](../examples/k8s/secret.example.yaml) | Placeholder Secrets: Multica home, Cursor key, git auth (Claude Code + AWS optional) |
| [`pvc.yaml`](../examples/k8s/pvc.yaml) | `multica-runtime-workspaces` PVC — the only durable volume |
| [`deployment.yaml`](../examples/k8s/deployment.yaml) | Single-replica Deployment wiring the Secrets + PVC together |

There is **no** Multica-home PVC — identity (`config.json`, `daemon.id`) is
Secret-projected only. There is **no** Ingress — the runtime has nothing to
serve inbound.

### Apply

These are illustrative placeholders, not production manifests — production
should use GitOps + SOPS (or your cluster's secret manager) instead of
`secret.example.yaml`'s plaintext `stringData`.

```bash
kubectl apply -f examples/k8s/namespace.yaml
kubectl apply -f examples/k8s/serviceaccount.yaml
kubectl apply -f examples/k8s/secret.example.yaml   # replace placeholder values first
kubectl apply -f examples/k8s/pvc.yaml
kubectl apply -f examples/k8s/deployment.yaml
```

Replace the image tag in `deployment.yaml` (`ghcr.io/gondoi/multica-runtime:vX.Y.Z`)
with a published release tag — see the CI publish table in the README for the
tag shapes (`vX.Y.Z` or `X.Y.Z`), e.g. `v0.1.0`.

Name the deployment by its scope so Multica's runtime list is readable —
uncomment `MULTICA_MACHINE_NAME` in `deployment.yaml` (or set it in your GitOps
overlay); the row shows `Cursor (fuel-general)` / `Claude (fuel-general)` instead of
`Cursor (multica-runtime-6cc749d9f7-dr2gh)`. Full custom names (no provider
prefix) are a one-time `multica runtime rename <id> <name> --machine` and are
kept per runtime, so they survive pod recreates. Details:
[Machine name](../README.md#machine-name-multica_machine_name).

### Verify

```bash
kubectl -n multica-runtime get pods
kubectl -n multica-runtime logs deploy/multica-runtime -f
```

The Deployment wires `startupProbe` / `livenessProbe` / `readinessProbe` to
the same `/usr/local/bin/ready.sh` used by the Compose healthcheck — pods go
Ready once the daemon is up past the hard gates (required binaries + secrets).
`ready.sh` gates on the daemon's reported `status` (`running` / `starting`), not
on the `daemon status` exit code — that exit code is `0` even when no daemon is
running, so checking it alone reports Ready forever.
The **first** task run against the pod may cold-clone its repo; that is
expected and is not part of the Ready gate.

### Agent CLI harnesses (Cursor / Claude Code)

`MULTICA_AGENT_CLI` in `deployment.yaml` (default `cursor`) names the harnesses
the pod provisions and hard-gates: `cursor`, `claude`, or `cursor,claude`. The
harness used for a specific run is chosen on the Multica agent definition; this
only guarantees the CLI is present and authenticated in the pod.

Harnesses it does **not** name are masked from the PATH the daemon and its tasks
inherit (both CLIs ship in the image). A selected harness is never masked, and
the mask is a boot-time PATH rewrite — no image change, so updating the
`MULTICA_AGENT_CLI` env value and restarting the pod is enough. `kubectl exec`
shells start from the image env, so check the mask through the daemon:

```bash
kubectl -n multica-runtime exec deploy/multica-runtime -- bash -c \
  'p=$(pgrep -f "multica daemon" | head -1); d=$(tr "\0" "\n" </proc/$p/environ | sed -n "s/^PATH=//p"); PATH=$d command -v claude || echo "claude masked"'
```

The `claude` Secret + volume are shipped **commented out** in `deployment.yaml`
because a mounted-but-absent Secret (or a missing key in its `items` list) fails
the pod mount. To run Claude Code:

1. Add the `claude` Secret to your overlay from the commented block in
   `secret.example.yaml` (`multica-runtime-claude`, one key only:
   `ANTHROPIC_API_KEY` **or** `CLAUDE_CODE_OAUTH_TOKEN` **or**
   `ANTHROPIC_AUTH_TOKEN`).
2. Uncomment the matching `*_FILE` env var, the `claude` `volumeMount`, and the
   `claude` volume in `deployment.yaml`.
3. Set `MULTICA_AGENT_CLI` to `claude` (or `cursor,claude`).

⚠️ Higher-risk, same as the GitHub/AWS tiers: that credential is inherited by
every agent task the pod runs. Prefer the OAuth-token tier over a long-lived org
API key and scope the credential to this runtime. Detail:
[README → Agent CLI harnesses](../README.md#agent-cli-harnesses-multica_agent_cli).

Verify from inside the pod once Ready:

```bash
kubectl -n multica-runtime exec deploy/multica-runtime -- claude --version
kubectl -n multica-runtime logs deploy/multica-runtime | grep 'harness claude'
```

### Switching GitHub auth tiers

`secret.example.yaml` defaults to the PAT tier (`GITHUB_TOKEN`). To switch to
the GitHub App tier (recommended for orgs that disallow PATs) or the GitHub
Enterprise Server password tier, you must update **both** files so their keys
match — a mismatch fails the Secret volume mount:

1. In `secret.example.yaml`, comment out `GITHUB_TOKEN` and uncomment the
   `GITHUB_APP_*` (or `GITHUB_HOST`/`GITHUB_USER`/`GITHUB_PASSWORD`) keys.
2. In `deployment.yaml`, update the `git` Secret volume's `items` list to the
   same key set, and uncomment the matching `*_FILE` env vars on the
   container.

See [GitHub auth precedence](../README.md#github-auth-precedence-app--pat--password)
in the README for how the three tiers resolve.

### AWS credentials (IRSA > instance role > aws-sso ConfigMaps > static mount)

The image installs AWS CLI v2 + upstream `aws-sso` but bakes **no** credentials.
Prefer the SDK default chain first; ConfigMap profiles cover homelab without IRSA:

| Tier | Setup | Pod spec change | Static keys |
| --- | --- | --- | --- |
| 1 · IRSA (EKS, preferred) | IAM role whose trust policy federates the cluster's OIDC provider to `system:serviceaccount:multica-runtime:multica-runtime`; EKS then projects `AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN` automatically | uncomment `eks.amazonaws.com/role-arn` in `serviceaccount.yaml` | No |
| 2 · Instance / ECS task role | Node instance profile (EC2) or task role (ECS) — the SDK calls IMDS/container endpoint on its own | none | No |
| 3a · aws-sso ConfigMaps | Curated `~/.aws/config` + aws-sso YAML; SSO cache on workspaces PVC | `aws-configmap.yaml` + Deployment mounts (already in examples) | No |
| 3b · Mounted static config | Secret with `config` / `credentials`, pointed at by `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` | uncomment the AWS env vars, `volumeMounts.aws`, and `volumes.aws` in `deployment.yaml`, plus the optional Secret in `secret.example.yaml` | Yes — avoid when tiers 1–3a exist |

Grant the role only what agent tasks actually need (`sts:GetCallerIdentity`,
plus the specific read actions for the discovery work you intend); every task
running in the pod inherits the identity. Verify from inside a pod:

```bash
kubectl -n multica-runtime exec deploy/multica-runtime -- aws sts get-caller-identity
kubectl -n multica-runtime logs deploy/multica-runtime | grep 'aws auth:'
```

The boot log line names the tier the chain resolved (informational, never a
boot gate, never a credential value).

For ConfigMap / aws-sso profiles, login is **operator-exec only**:

```bash
kubectl -n multica-runtime exec -it deploy/multica-runtime -- \
  env AWS_SSO_OPERATOR_LOGIN=1 aws-sso login --url-action=print
```

### Egress control (not provided yet)

`MULTICA_EGRESS_PROXY` / `MULTICA_EGRESS_PROXY_CA` work identically in a pod —
set them plus a read-only mount of the proxy's `ca.crt` — but **no Kubernetes
manifest for an egress proxy ships here yet.** The two cluster-side decisions
that make or break it (the address iron-proxy answers DNS queries with, and the
`dnsConfig` + NetworkPolicy that force pods through it) depend on the cluster,
not on this image, so they are a separate follow-up. iron-proxy does publish a
Helm chart upstream. See [`docs/egress-control.md`](../egress-control.md).
Do **not** set `MULTICA_EGRESS_PROXY` without wiring `dnsConfig` at the proxy:
TLS would fail closed for every request (by design).

### Tear down

```bash
kubectl delete -f examples/k8s/deployment.yaml
kubectl delete -f examples/k8s/pvc.yaml       # drops the workspaces cache
kubectl delete -f examples/k8s/secret.example.yaml
kubectl delete -f examples/k8s/serviceaccount.yaml
kubectl delete -f examples/k8s/namespace.yaml
```
