## Running in Kubernetes

Usage walkthrough for the example manifests in
[`examples/k8s/`](../examples/k8s/). They implement the same Secret-projection
contract as the local Compose setup — see the [root README](../README.md) for
the full boot contract and GitHub auth tier precedence.

### What's here

| Manifest | Role |
| --- | --- |
| [`namespace.yaml`](../examples/k8s/namespace.yaml) | `multica-runtime` namespace (deploy-time name — replace it) |
| [`secret.example.yaml`](../examples/k8s/secret.example.yaml) | Placeholder Secrets: Multica home, Cursor key, git auth |
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

### Tear down

```bash
kubectl delete -f examples/k8s/deployment.yaml
kubectl delete -f examples/k8s/pvc.yaml       # drops the workspaces cache
kubectl delete -f examples/k8s/secret.example.yaml
kubectl delete -f examples/k8s/namespace.yaml
```
