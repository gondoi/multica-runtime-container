# Kubernetes mount parity (examples)

Illustrative manifests for the Secret projection contract. Namespace is
**deploy-time** — replace `multica-runtime` with your namespace. No Ingress.

| Mount | Path in pod | Role |
| --- | --- | --- |
| Secret `multica-runtime-home` | `/run/secrets/multica-home/{config.json,daemon.id}` | Multica identity (no Multica-home PVC) |
| Secret `multica-runtime-cursor` | `/run/secrets/cursor/CURSOR_API_KEY` | Cursor agent |
| Secret `multica-runtime-git` | `/run/secrets/git/GITHUB_TOKEN` **or** `GITHUB_APP_*` | git HTTPS for lazy `repo checkout` (PAT or App) |
| PVC `multica-runtime-workspaces` | `/home/agent/workspaces` | `.repos`, worktrees, asdf, provider homes |
| ServiceAccount `multica-runtime` | pod identity (not a mount) | IRSA hook for AWS creds (annotation optional) |
| Secret `multica-runtime-aws` *(optional, commented)* | `/run/secrets/aws/{config,credentials}` | AWS tier 3 fallback only |

Apply order (example only — production uses GitOps + SOPS):

```bash
kubectl apply -f namespace.yaml
kubectl apply -f serviceaccount.yaml     # plain SA; annotation optional (IRSA)
kubectl apply -f secret.example.yaml     # replace placeholder values first
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
```

When switching from PAT to GitHub App, update **both** the Secret keys and the
Deployment `volumes.git.secret.items` list so they match (missing keys fail the
pod mount). See comments in `deployment.yaml` / `secret.example.yaml`.

## AWS credentials

The image ships `aws` (AWS CLI v2) but **no** credentials and no auth-tier
plumbing of its own — the AWS SDK's default chain resolves them. Precedence,
highest trust first (full table in the [root README](../../README.md#aws-auth-tiers)):

| Tier | What to wire | Manifests touched | Static keys? |
| --- | --- | --- | --- |
| 1 · IRSA (EKS) | IAM role trusting the cluster OIDC provider, annotated onto the ServiceAccount | `serviceaccount.yaml` (uncomment `eks.amazonaws.com/role-arn`) | No |
| 2 · Instance / ECS task role | Node IAM role or ECS task role — nothing in these manifests | none | No |
| 3 · Mounted config | `multica-runtime-aws` Secret + `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` | `secret.example.yaml` + `deployment.yaml` (uncomment) | Yes — least preferred |

Boot logs the tier it resolves, e.g.:

```
aws auth: web identity / IRSA (AWS_WEB_IDENTITY_TOKEN_FILE, role arn:aws:iam::…:role/…) — tier 1
aws auth: none detected in env/mounts — SDK falls back to an EC2 instance profile (IMDSv2) if present, else AWS calls fail; …
```

That line is informational only — it never fails a boot and never prints a
credential value. Verify from inside a pod with:

```bash
kubectl -n multica-runtime exec deploy/multica-runtime -- aws sts get-caller-identity
```

`aws-sso` / `aws configure sso` is still deferred: the device-authorization
flow needs an interactive browser step that doesn't fit a headless pod.
