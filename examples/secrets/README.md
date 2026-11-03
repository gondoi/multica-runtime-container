# Secret file layout (compose + K8s parity)

The runtime expects the same paths in docker compose bind-mounts and in
Kubernetes Secret projections. There is **no** Multica-home PVC — only
`config.json` + `daemon.id` are projected; the entrypoint copies them into a
writable ephemeral `$HOME/.multica` so the daemon can write logs/lock/pid.

```text
secrets/
  multica-home/
    config.json     # Multica CLI config (includes token)
    daemon.id       # stable daemon identity (UUID or name)
  cursor/
    CURSOR_API_KEY  # single-line Cursor API key
  git/
    GITHUB_TOKEN    # and/or GITLAB_TOKEN, GITEA_TOKEN
```

## Compose

```bash
mkdir -p secrets/multica-home secrets/cursor secrets/git
cp examples/secrets/multica-home/config.json.example secrets/multica-home/config.json
cp examples/secrets/multica-home/daemon.id.example   secrets/multica-home/daemon.id
# edit config.json (server/app URLs, workspace_id, token)
printf '%s' 'cursor_…' > secrets/cursor/CURSOR_API_KEY
printf '%s' 'ghp_…'    > secrets/git/GITHUB_TOKEN
docker compose up -d --build
```

`secrets/` is gitignored — never commit real tokens.

## Kubernetes

See [`examples/k8s/`](../k8s/) for a Deployment that projects the same keys to
`/run/secrets/...`. Homelab SOPS / Flux packaging is a later GitOps slice.
