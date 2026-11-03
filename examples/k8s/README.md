# Kubernetes mount parity (examples)

Illustrative manifests for the Secret projection contract. Namespace is
**deploy-time** — replace `multica-runtime` with your namespace. No Ingress.

| Mount | Path in pod | Role |
| --- | --- | --- |
| Secret `multica-runtime-home` | `/run/secrets/multica-home/{config.json,daemon.id}` | Multica identity (no Multica-home PVC) |
| Secret `multica-runtime-cursor` | `/run/secrets/cursor/CURSOR_API_KEY` | Cursor agent |
| Secret `multica-runtime-git` | `/run/secrets/git/GITHUB_TOKEN` | git HTTPS for lazy `repo checkout` |
| PVC `multica-runtime-workspaces` | `/home/agent/workspaces` | `.repos`, worktrees, asdf, provider homes |

Apply order (example only — production uses GitOps + SOPS):

```bash
kubectl apply -f namespace.yaml
kubectl apply -f secret.example.yaml   # replace placeholder values first
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
```

AWS ConfigMaps / aws-sso wiring is deferred.
