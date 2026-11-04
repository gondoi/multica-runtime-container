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
  claude/           # only when MULTICA_AGENT_CLI includes `claude`
    ANTHROPIC_API_KEY          # option 1: API key
    # CLAUDE_CODE_OAUTH_TOKEN  # option 2: from `claude setup-token`
    # ANTHROPIC_AUTH_TOKEN     # option 3: gateway bearer token (+ ANTHROPIC_BASE_URL env)
  git/
    GITHUB_TOKEN    # Option A: static PAT (and/or GITLAB_TOKEN, GITEA_TOKEN)
    # Option B: GitHub App (org-safe; use instead of or preferred over PAT)
    # GITHUB_APP_ID
    # GITHUB_APP_INSTALLATION_ID
    # GITHUB_APP_PRIVATE_KEY   # full PEM including BEGIN/END lines
    # Option C: GitHub Enterprise Server username + password (lowest priority;
    # github.com rejects password auth for git-over-HTTPS — pair it with a
    # GITHUB_HOST pointing at the GHES instance)
    # GITHUB_USER
    # GITHUB_PASSWORD
    # GITHUB_HOST              # host for all GitHub tiers (default github.com)
```

GitHub tiers resolve **App > PAT > password** (first complete one wins; an
incomplete App config falls through to the next tier). Force one with
`GITHUB_AUTH_TIER=app|token|password` when several are configured. The resolved
tier also seeds `gh` CLI auth via `~/.multica/git-auth.env` (0600, never logged);
no extra Secret is needed for `gh`.

## Agent CLI harnesses

`MULTICA_AGENT_CLI` (default `cursor`) names the harnesses this container
provisions and hard-gates: `cursor`, `claude`, or `cursor,claude`. Claude needs
**one** of `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_AUTH_TOKEN`;
Cursor needs `CURSOR_API_KEY`. A selected harness with no credential is a hard
boot failure (CrashLoop), not a silent fallback — see the root README
[Agent CLI harnesses](../README.md#agent-cli-harnesses-multica_agent_cli).

## Compose

```bash
mkdir -p secrets/multica-home secrets/cursor secrets/git
cp examples/secrets/multica-home/config.json.example secrets/multica-home/config.json
cp examples/secrets/multica-home/daemon.id.example   secrets/multica-home/daemon.id
# edit config.json (server/app URLs, workspace_id, token)
printf '%s' 'cursor_…' > secrets/cursor/CURSOR_API_KEY
# Optional — Claude Code harness (needs MULTICA_AGENT_CLI=claude or cursor,claude):
# mkdir -p secrets/claude
# printf '%s' 'sk-ant-…' > secrets/claude/ANTHROPIC_API_KEY
# Option A — PAT:
printf '%s' 'ghp_…'    > secrets/git/GITHUB_TOKEN
# Option B — GitHub App (omit GITHUB_TOKEN when switching fully):
# printf '%s' '123456'   > secrets/git/GITHUB_APP_ID
# printf '%s' '12345678' > secrets/git/GITHUB_APP_INSTALLATION_ID
# cp /path/to/app.private-key.pem secrets/git/GITHUB_APP_PRIVATE_KEY
# Option C — GitHub Enterprise Server username + password (lowest priority):
# printf '%s' 'ghe.example.com' > secrets/git/GITHUB_HOST
# printf '%s' 'agent'           > secrets/git/GITHUB_USER
# printf '%s' '…'               > secrets/git/GITHUB_PASSWORD
docker compose up -d --build
```

`secrets/` is gitignored — never commit real tokens or App PEMs.

`multica login` may rewrite `workspace_id` to the token's default workspace.
The entrypoint re-pins after login from (in order): env `MULTICA_WORKSPACE`
(or `MULTICA_WORKSPACE_ID`) → projected `config.json` `.workspace_id` → leave
login default. Prefer a slug in env (e.g. `MULTICA_WORKSPACE=fuel-labs`) so
GitOps need not bake UUIDs.

## Kubernetes

See [`examples/k8s/`](../k8s/) for a Deployment that projects the same keys to
`/run/secrets/...`. Consumer overlays (SOPS / Flux) stay out of this published
tree — wire App PEM + IDs in the private overlay only.
