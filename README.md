# Multica runtime home-base

Thin container image for a **[Multica](https://multica.ai) agent runtime home-base**.

It boots a Multica daemon with Cursor as the v1 agent CLI, persists workspaces on a volume, and relies on Multica **lazy** `repo checkout` for source — no consumer monorepos are baked into the image, and there is **no** boot-time inventory clone-all.

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
| `git`, `openssh-client`, `jq`, `curl`, `procps` | Checkout, scripting, readiness probes |
| `tini` | PID 1 — reaps orphans, forwards signals |
| non-root `agent` user | Default runtime identity |
| `/usr/local/bin/ready.sh` | Shallow Ready probe (daemon up — not full inventory) |

**Not** in the image: language toolchains (install via asdf at runtime), AWS profile wiring (deferred), multi-CLI agent sets (Claude/Codex/etc.), or any private consumer inventory.

## Boot contract

Order:

1. Source config (`.env` / Secret env-file mounts)
2. Materialize Secret-projected Multica home (`config.json` + `daemon.id`) into ephemeral `~/.multica`; load Cursor/git token (and optional GitHub App) files
3. Hard gates — required binaries (`multica`, `cursor-agent`, `git`, `jq`, `curl`, `asdf`, `openssl`) and secrets (Multica auth, `CURSOR_API_KEY`, forge token **or** GitHub App credentials)
4. Configure git HTTPS credential helper (static store and/or GitHub App installation-token helper)
5. `multica login` (token refresh) → **re-pin workspace** (login can clobber `workspace_id`) → `exec multica daemon start --foreground`

**Ready** = daemon is up after gates. **Crash** = missing secret/binary/git-auth (non-zero exit → CrashLoop).

**Workspace pin** (after login): `MULTICA_WORKSPACE` (preferred; slug, display name, or UUID) → `MULTICA_WORKSPACE_ID` (same resolution) → projected Secret `config.json` `.workspace_id` → leave login default.

There is **no** ConfigMap inventory sync at boot. Repo trees land on the workspaces volume when Multica runs `repo checkout` for a task. The **first task may cold-clone**; that is expected and is not a Ready gate.

Scratch shell (bypasses gates): `docker run --rm -it --entrypoint /bin/bash ghcr.io/gondoi/multica-runtime:sha-…`

## Secrets (compose + Kubernetes parity)

Multica home is **Secret-projected** — there is **no** Multica-home PVC. Only the workspaces volume is durable.

| Secret keys | Mount path | Purpose |
| --- | --- | --- |
| `config.json`, `daemon.id` | `/run/secrets/multica-home/` | Multica identity (copied to ephemeral `~/.multica`) |
| `CURSOR_API_KEY` | `/run/secrets/cursor/CURSOR_API_KEY` | Cursor agent |
| `GITHUB_TOKEN` (etc.) | `/run/secrets/git/GITHUB_TOKEN` | git HTTPS via static PAT (personal / orgs that allow PATs) |
| `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY` | `/run/secrets/git/` | git HTTPS via short-lived App installation tokens (org-safe; preferred when PATs are banned) |

Provide **either** a static forge token **or** the GitHub App trio (App wins for `github.com` when both are present). Env vars override files when set. Layout details: [`examples/secrets/`](examples/secrets/). Kubernetes examples: [`examples/k8s/`](examples/k8s/).

### GitHub App git auth (no PAT)

For orgs that disallow PATs, create a GitHub App with **minimum** permissions:

| Permission | Access | Why |
| --- | --- | --- |
| Metadata | Read | Required baseline |
| Contents | Read and write | Clone + push agent feature branches |
| Pull requests | Read and write | Open PRs |

**Do not** grant administration or “bypass branch protection / rules”. Protected `main` stays PR-only; the App cannot push straight to protected branches.

Install the App on the target account/org (select only the repos agents need). Project App ID, installation ID, and the downloaded PEM under `/run/secrets/git/`. Boot mints an installation token and configures a git credential helper that remints when the ~1h token expires.

## Build locally

```bash
docker build -t multica-runtime:local .
```

Smoke that baseline binaries exist:

```bash
docker run --rm --entrypoint /bin/bash multica-runtime:local -lc \
  'command -v multica cursor-agent asdf git ssh jq curl tini ready.sh materialize-secrets.sh'
```

### Compose (laptop parity)

```bash
mkdir -p secrets/multica-home secrets/cursor secrets/git
cp examples/secrets/multica-home/config.json.example secrets/multica-home/config.json
cp examples/secrets/multica-home/daemon.id.example   secrets/multica-home/daemon.id
# edit secrets/… then:
printf '%s' "$CURSOR_API_KEY" > secrets/cursor/CURSOR_API_KEY
printf '%s' "$GITHUB_TOKEN"   > secrets/git/GITHUB_TOKEN
docker compose up -d --build
docker compose ps      # healthy when ready.sh passes
```

### Boot seam (Ready vs Crash)

Automated fixture check (stub Multica for happy path — no live cloud required):

```bash
./test/boot/run-seam.sh
```

## Configuration (placeholders)

See [`.env.example`](.env.example) for optional non-secret knobs. Tokens prefer Secret file mounts under `secrets/` — never bake them into layers.

| Source | Purpose |
| --- | --- |
| `secrets/multica-home/config.json` | Multica PAT + server/workspace (**required** unless `MULTICA_TOKEN` env) |
| `secrets/multica-home/daemon.id` | Stable daemon id across recreates |
| `secrets/cursor/CURSOR_API_KEY` | Cursor agent auth (**required**) |
| `secrets/git/GITHUB_TOKEN` | git HTTPS PAT (**required** unless GitLab/Gitea **or** GitHub App trio) |
| `secrets/git/GITHUB_APP_*` | App ID + installation ID + PEM (alternative to `GITHUB_TOKEN`) |
| `MULTICA_WORKSPACES_ROOT` | Configurable workspaces root (default `/home/agent/workspaces`) |
| `MULTICA_WORKSPACE` | Default workspace after login: slug, display name, or UUID (e.g. `fuel-labs`). Fallback: `MULTICA_WORKSPACE_ID`, then Secret `config.json` `.workspace_id`. |
| `MULTICA_WORKSPACE_ID` | Legacy alias of `MULTICA_WORKSPACE` (same resolution) |

## Design notes

- Repos are **not** cloned at image build or at container start. Register them in Multica workspace/project metadata; materialize with `multica repo checkout` during tasks (first task may cold-clone).
- `asdf` is installed with plugin-install capability; pin tool versions on the workspaces volume, not in the image.
- Patterns inspired by community Multica runtimes (`tini`, non-root user, forge HTTPS helpers) — adapted for a Cursor-first, asdf-based baseline.
- AWS ConfigMap / aws-sso wiring is deferred past first daemon smoke.

## License

MIT — see [LICENSE](LICENSE).
