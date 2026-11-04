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
| [`secret.example.yaml`](../examples/k8s/secret.example.yaml) | Placeholder Secrets: Multica home, Cursor key, git auth (AWS optional) |
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

Replace the image tag in `deployment.yaml` (`ghcr.io/gondoi/multica-runtime:sha-REPLACE`)
with a real published tag — see the CI publish table in the README for the
tag shapes (`v<semver>` or `sha-<12>`).

### Verify

```bash
kubectl -n multica-runtime get pods
kubectl -n multica-runtime logs deploy/multica-runtime -f
```

The Deployment wires `startupProbe` / `livenessProbe` / `readinessProbe` to
the same `/usr/local/bin/ready.sh` used by the Compose healthcheck — pods go
Ready once the daemon is up past the hard gates (required binaries + secrets).
The **first** task run against the pod may cold-clone its repo; that is
expected and is not part of the Ready gate.

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

### Tear down

```bash
kubectl delete -f examples/k8s/deployment.yaml
kubectl delete -f examples/k8s/pvc.yaml       # drops the workspaces cache
kubectl delete -f examples/k8s/secret.example.yaml
kubectl delete -f examples/k8s/serviceaccount.yaml
kubectl delete -f examples/k8s/namespace.yaml
```
