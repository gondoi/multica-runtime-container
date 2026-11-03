# Multica runtime home-base

Thin container image for a **[Multica](https://multica.ai) agent runtime home-base**.

It boots a Multica daemon with Cursor as the v1 agent CLI, persists workspaces on a volume, and relies on Multica **lazy** `repo checkout` for source — no consumer monorepos are baked into the image.

Published image: `ghcr.io/gondoi/multica-runtime` (public GHCR, anonymous pull).

### CI publish

GitHub Actions (`.github/workflows/docker-publish.yml`) builds **linux/amd64 + linux/arm64** via `FuelLabs/github-actions` `docker-build-push` and pushes pin-friendly tags only (no `latest`):

| Trigger | When |
| --- | --- |
| `workflow_dispatch` | Manual |
| Push to `main` | Dockerfile / entrypoint / `bin/**` / `.dockerignore` / this workflow |
| Git tag `v*` | Semver releases |

| Tag shape | Example |
| --- | --- |
| Semver (on `v*` tags) | `v0.1.0`, `0.1.0` |
| Short SHA | `sha-<12>` |

## What's in the image

| Component | Role |
| --- | --- |
| `multica` CLI + daemon | Runtime identity and task execution |
| `cursor-agent` | First agent provider (Cursor) |
| `asdf` | Versioned tool plugins (languages / CLIs) on the workspaces volume |
| `git`, `openssh-client`, `jq`, `curl` | Checkout and scripting baseline |
| `tini` | PID 1 — reaps orphans, forwards signals |
| non-root `agent` user | Default runtime identity |

**Not** in the image: language toolchains (install via asdf at runtime), AWS profile wiring (deferred), multi-CLI agent sets (Claude/Codex/etc.), or any private consumer inventory.

## Build locally

```bash
docker build -t multica-runtime:local .
```

Smoke that baseline binaries exist:

```bash
docker run --rm --entrypoint /bin/bash multica-runtime:local -lc \
  'command -v multica cursor-agent asdf git ssh jq curl tini'
```

Without `MULTICA_TOKEN`, the entrypoint drops to an interactive shell (useful as a scratch container). Headless daemon boot, Secret mounts, and compose/K8s packages land in follow-up slices.

## Configuration (placeholders)

See [`.env.example`](.env.example). Tokens and keys are supplied at run time (Secret / env-file) — never baked into layers.

| Variable | Purpose |
| --- | --- |
| `MULTICA_TOKEN` | Multica PAT for daemon mode |
| `CURSOR_API_KEY` | Cursor agent auth |
| `GITHUB_TOKEN` | git HTTPS for lazy checkout |
| `MULTICA_WORKSPACES_ROOT` | Configurable workspaces root (default `/home/agent/workspaces`) |
| `MULTICA_DAEMON_ID` | Stable daemon id across recreates |

## Design notes

- Repos are **not** cloned at image build or (in the MVP boot path) at container start. Register them in Multica workspace/project metadata; materialize with `multica repo checkout` during tasks.
- `asdf` is installed with plugin-install capability; pin tool versions on the workspaces volume, not in the image.
- Patterns inspired by community Multica runtimes (`tini`, non-root user, forge HTTPS helpers) — adapted for a Cursor-first, asdf-based baseline.

## License

MIT — see [LICENSE](LICENSE).
