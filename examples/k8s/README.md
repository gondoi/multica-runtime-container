# Kubernetes mount parity (examples)

Illustrative manifests for the Secret + ConfigMap projection contract.
Namespace is **deploy-time** — replace `multica-runtime` with your namespace.
No Ingress.

| Mount | Path in pod | Role |
| --- | --- | --- |
| Secret `multica-runtime-home` | `/run/secrets/multica-home/{config.json,daemon.id}` | Multica identity (no Multica-home PVC) |
| Secret `multica-runtime-cursor` | `/run/secrets/cursor/CURSOR_API_KEY` | Cursor harness (`MULTICA_AGENT_CLI` includes `cursor`, the default) |
| Secret `multica-runtime-claude` *(optional, commented)* | `/run/secrets/claude/{ANTHROPIC_API_KEY,CLAUDE_CODE_OAUTH_TOKEN,ANTHROPIC_AUTH_TOKEN}` | Claude Code harness (`MULTICA_AGENT_CLI` includes `claude`) — mount only the one key present |
| Secret `multica-runtime-git` | `/run/secrets/git/GITHUB_TOKEN` **or** `GITHUB_APP_*` | git HTTPS for lazy `repo checkout` (PAT or App) |
| ConfigMap `multica-runtime-aws` | `/run/config/aws/config` | Literal `~/.aws/config` fragment (generic stub in examples) |
| ConfigMap `multica-runtime-aws-sso` | `/run/config/aws-sso/config.yaml` | `aws-sso` config (StartUrl, UrlAction=print) |
| PVC `multica-runtime-workspaces` | `/home/agent/workspaces` | `.repos`, worktrees, asdf, **AWS SSO cache** under `.provider-homes/` |
| ServiceAccount `multica-runtime` | pod identity (not a mount) | IRSA hook for AWS creds (annotation optional) |
| Secret `multica-runtime-aws-static` *(optional, commented)* | `/run/secrets/aws/{config,credentials}` | AWS tier 3 static-key fallback only |

Apply order (example only — production uses GitOps + SOPS):

```bash
kubectl apply -f namespace.yaml
kubectl apply -f serviceaccount.yaml     # plain SA; annotation optional (IRSA)
kubectl apply -f secret.example.yaml     # replace placeholder values first
kubectl apply -f aws-configmap.yaml      # replace stubs with consumer allowlist
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
```

When switching from PAT to GitHub App, update **both** the Secret keys and the
Deployment `volumes.git.secret.items` list so they match (missing keys fail the
pod mount). See comments in `deployment.yaml` / `secret.example.yaml`.

Same rule for Claude Code: mount only the credential key you actually put in
`multica-runtime-claude`, and set `MULTICA_AGENT_CLI=claude` (or
`cursor,claude`). See [docs/kubernetes.md → Agent CLI harnesses](../../docs/kubernetes.md#agent-cli-harnesses-cursor--claude-code).

## AWS credentials

The image ships `aws` (AWS CLI v2) + upstream `aws-sso` but **no** baked
credentials. Prefer the SDK default chain first (full table in the
[root README](../../README.md#aws-auth-tiers)):

| Tier | What to wire | Manifests touched | Static keys? |
| --- | --- | --- | --- |
| 1 · IRSA (EKS) | IAM role trusting the cluster OIDC provider, annotated onto the ServiceAccount | `serviceaccount.yaml` (uncomment `eks.amazonaws.com/role-arn`) | No |
| 2 · Instance / ECS task role | Node IAM role or ECS task role — nothing in these manifests | none | No |
| 3a · aws-sso ConfigMaps | Curated `~/.aws/config` + `aws-sso` YAML; SSO cache on PVC | `aws-configmap.yaml` + Deployment mounts | No (SSO tokens on PVC) |
| 3b · Mounted static config | Secret + `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` | `secret.example.yaml` + `deployment.yaml` (uncomment) | Yes — least preferred |

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

## AWS SSO login (operator-exec only)

When using ConfigMap profiles (tier 3a) without IRSA, agents do **not** run
`aws-sso login`. After the pod is Ready:

```bash
kubectl exec -it deploy/multica-runtime -n multica-runtime -- \
  env AWS_SSO_OPERATOR_LOGIN=1 aws-sso login --url-action=print
```

Open the printed URL. Cache persists on the workspaces PVC. Without
`AWS_SSO_OPERATOR_LOGIN=1`, `aws-sso login` exits non-zero. `AWS_PROFILE` is
unset — pass `--profile` / `AWS_PROFILE` per call.
