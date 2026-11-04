# AWS profile stubs (compose + ConfigMap source)

Literal `~/.aws/config` fragment and `~/.config/aws-sso/config.yaml` for the
home-base. Published copies are **generic placeholders** — put real account
allowlists in a private overlay, not in this tree.

| File | Mounted as |
| --- | --- |
| `config` | `/run/config/aws/config` → linked into PVC-backed `~/.aws/config` |
| `config.yaml` | `/run/config/aws-sso/config.yaml` → linked into PVC-backed `~/.config/aws-sso/config.yaml` |

SSO cache (`cache.json`, etc.) is written under the workspaces volume at
`.provider-homes/aws-sso/` and survives pod recreate.

## Operator login (agents must not)

```bash
# Compose
docker compose exec -e AWS_SSO_OPERATOR_LOGIN=1 runtime \
  aws-sso login --url-action=print

# Kubernetes
kubectl exec -it deploy/multica-runtime -n <ns> -- \
  env AWS_SSO_OPERATOR_LOGIN=1 aws-sso login --url-action=print
```

Open the printed Identity Center URL in a browser. After consent, agents use
existing cache via `credential_process` / `--profile`. `aws-sso login` without
`AWS_SSO_OPERATOR_LOGIN=1` exits non-zero (guard wrapper).
