# Multica runtime home-base

Thin container image for a **[Multica](https://multica.ai) agent runtime home-base**.

It boots a Multica daemon with Cursor as the v1 agent CLI, persists workspaces on a volume, and relies on Multica **lazy** `repo checkout` for source — no consumer monorepos are baked into the image, and there is **no** boot-time inventory clone-all.

Published image: `ghcr.io/gondoi/multica-runtime` (public GHCR, anonymous pull).

**Usage docs:** [Running locally with Docker](docs/docker.md) (incl. a working Compose setup) · [Running in Kubernetes](docs/kubernetes.md)

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
| `gh` (GitHub CLI) | Agent tooling (`gh pr create`, `gh api`, `gh run`); authenticates from the resolved tier — App tier re-mints per invocation |
| `tini` | PID 1 — reaps orphans, forwards signals |
| non-root `agent` user | Default runtime identity |
| `/usr/local/bin/ready.sh` | Shallow Ready probe (daemon up — not full inventory) |

**Not** in the image: language toolchains (install via asdf at runtime), AWS profile wiring (deferred), multi-CLI agent sets (Claude/Codex/etc.), or any private consumer inventory.

## Boot contract

Order:

1. Source config (`.env` / Secret env-file mounts)
2. Materialize Secret-projected Multica home (`config.json` + `daemon.id`) into ephemeral `~/.multica`; load Cursor/git token (and optional GitHub App) files
3. Hard gates — required binaries (`multica`, `cursor-agent`, `git`, `jq`, `curl`, `asdf`, `openssl`) and secrets (Multica auth, `CURSOR_API_KEY`, forge token **or** GitHub App credentials **or** GitHub Enterprise Server password pair)
4. Configure git HTTPS credential helper (static store and/or GitHub App installation-token helper), resolving GitHub auth as **App → PAT → password**; seed `GH_TOKEN` in the daemon environment so the `gh` CLI is authenticated too
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
| `GITHUB_USER`, `GITHUB_PASSWORD` | `/run/secrets/git/` | git HTTPS via username + password — **GitHub Enterprise Server only**, lowest priority |
| `GITHUB_HOST` | `/run/secrets/git/GITHUB_HOST` | GitHub host for all three GitHub tiers (default `github.com`) |

Provide **either** a static forge token, **or** the GitHub App trio, **or** a GHES username/password pair — the GitHub tier is picked by precedence (next section). Env vars override files when set. Layout details: [`examples/secrets/`](examples/secrets/). Kubernetes examples: [`examples/k8s/`](examples/k8s/) — usage walkthrough: [`docs/kubernetes.md`](docs/kubernetes.md).

### GitHub auth precedence (App > PAT > password)

Tiers are ordered **most → least secure for managed credentials**. `bin/configure-git-auth.sh` resolves exactly one GitHub tier — the first **complete** one wins:

| Tier | Credentials | Result | gh CLI |
| --- | --- | --- | --- |
| 1 · App (best) | `GITHUB_APP_ID` + `GITHUB_APP_INSTALLATION_ID` + PEM | live credential helper; remints installation tokens before the ~1h expiry | `gh` wrapper re-mints per invocation — never goes stale |
| 2 · PAT | `GITHUB_TOKEN` | static `~/.git-credentials` entry, username `GITHUB_USER` (default `x-access-token`) | `GH_TOKEN` in the daemon env |
| 3 · Password (fallback) | `GITHUB_USER` + `GITHUB_PASSWORD` | static `~/.git-credentials` entry, percent-encoded (git decodes on read) | unauthenticated — gh has no password auth; git still works |

- An **incomplete** higher tier falls through: App ID + installation ID without a PEM → PAT → password.
- **Force a tier** with `GITHUB_AUTH_TIER=app|token|password` when more than one is configured (e.g. App present but you want to test a PAT). A forced tier that is incomplete is a hard boot error — never a silent fallback.
- **github.com removed password (basic) auth for git-over-HTTPS in Aug 2021.** A password-only config pointed at `github.com` therefore **hard-fails at boot** with an actionable message instead of writing credentials that clone would reject. Set `GITHUB_HOST` to a GitHub Enterprise Server host (e.g. `ghe.example.com`) to use tier 3; the App tier then derives its API base as `https://<host>/api/v3`, and `GITHUB_API_URL` still overrides.
- `GITHUB_HOST` selects the host for all three GitHub tiers (not GitHub Enterprise-aware for other forges — GitLab/Gitea settings are independent).
- Boot logs the chosen tier (`git HTTPS: GitHub auth tier=…`) and never echoes `GITHUB_PASSWORD`, the PAT, or the App PEM.

### `gh` CLI auth

`gh` is installed (`/usr/local/bin/gh-real`) behind a thin wrapper (`/usr/local/bin/gh`, [`bin/gh-wrapper.sh`](bin/gh-wrapper.sh)). `configure-git-auth.sh` writes `~/.multica/git-auth.env` (0600) with `GH_TOKEN`/`GITHUB_TOKEN`/`GH_HOST` for the resolved tier and the entrypoint exports it, so the daemon and the tasks it spawns inherit gh auth without the token ever being logged. There is no interactive `gh auth login`: the container is headless and `~` is ephemeral, so state is re-derived from the tier at every boot instead of persisted.

- App tier: the wrapper **re-mints the installation token on each `gh` call**, so a long-running container never hits the ~1h expiry (`gh --version`/`help` skip the mint). If a mint fails the command runs with the boot token rather than erroring.
- PAT tier: `GH_TOKEN` is static, like the git credential.
- Password tier: gh stays unauthenticated (gh has no password auth); use tier 1 or 2 when agents need `gh pr create`/`gh api`.
- SSH/deploy keys are deliberately **not** a tier — git auth here is HTTPS-only.

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
  'command -v multica cursor-agent gh asdf git ssh jq curl tini ready.sh materialize-secrets.sh && gh --version'
```

### Compose (laptop parity)

Full walkthrough: [`docs/docker.md`](docs/docker.md).

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

Fast unit suites (auth precedence + App token mint; no Docker, no network):

```bash
./test/unit/run-unit.sh
```

## Configuration (placeholders)

See [`.env.example`](.env.example) for optional non-secret knobs. Tokens prefer Secret file mounts under `secrets/` — never bake them into layers.

| Source | Purpose |
| --- | --- |
| `secrets/multica-home/config.json` | Multica PAT + server/workspace (**required** unless `MULTICA_TOKEN` env) |
| `secrets/multica-home/daemon.id` | Stable daemon id across recreates |
| `secrets/cursor/CURSOR_API_KEY` | Cursor agent auth (**required**) |
| `secrets/git/GITHUB_TOKEN` | git HTTPS PAT (**required** unless GitLab/Gitea **or** GitHub App trio **or** GHES password pair) |
| `secrets/git/GITHUB_APP_*` | App ID + installation ID + PEM (alternative to `GITHUB_TOKEN`) |
| `secrets/git/GITHUB_USER` + `GITHUB_PASSWORD` | GitHub Enterprise Server password pair (lowest priority; `github.com` rejects it) |
| `secrets/git/GITHUB_HOST` | GitHub host for all GitHub tiers (default `github.com`) |
| `MULTICA_WORKSPACES_ROOT` | Configurable workspaces root (default `/home/agent/workspaces`) |
| `MULTICA_LOG_LEVEL` | Log level mirrored to container stdout: `DEBUG` \| `INFO` (default) \| `WARN` \| `ERROR`. See [Daemon log level](#daemon-log-level-multica_log_level). |
| `MULTICA_WORKSPACE` | Default workspace after login: slug, display name, or UUID (e.g. `fuel-labs`). Fallback: `MULTICA_WORKSPACE_ID`, then Secret `config.json` `.workspace_id`. |
| `MULTICA_WORKSPACE_ID` | Legacy alias of `MULTICA_WORKSPACE` (same resolution) |

## Daemon log level (`MULTICA_LOG_LEVEL`)

`MULTICA_LOG_LEVEL` (default `INFO`) controls which daemon log records reach
**container stdout** (`docker logs` / `docker compose logs` / `kubectl logs`).
Accepted values: `DEBUG`, `INFO`, `WARN`, `ERROR` (case-insensitive). An
unrecognised value is a hard boot failure, not a silent fallback.

```bash
docker run -e MULTICA_LOG_LEVEL=WARN … multica-runtime:local
```

### What it does — and does not — do

**The daemon itself is not re-leveled.** As of Multica CLI 0.8.0 (the version
pinned in the `Dockerfile`) `multica daemon start` exposes no log-level knob:

| Check | Result |
| --- | --- |
| `multica daemon start --help` | no `--log-level` (nearest is global `multica --debug` / `MULTICA_DEBUG`, which only adds error detail) |
| `MULTICA_LOG_LEVEL` / any level env | not read by the CLI (binary string scan: only `MULTICA_DEBUG`) |
| `multica config set <key>` | supported keys have no log level |
| `multica daemon logs` | `-f/--follow`, `-n/--lines` only — no filtering |

The daemon's handler level is fixed at debug, so `~/.multica/daemon.log` always
records `DBG` lines (and is rotated/compressed as usual). What this image
controls is the **collection side**: `bin/log-level-filter.sh` sits on the
`multica daemon logs --follow` pipeline that the entrypoint mirrors to stdout,
keeping records at or above the configured level. Lines carrying no level token
(multiline continuations, stack traces) always pass through, since the filter
is stateless — a dropped `DBG` record can therefore leave an orphan
continuation line behind.

Consequences worth knowing:

- `MULTICA_HOME/daemon.log` (inside the container) is still verbose — pull it
  when you need DEBUG detail: `docker exec <c> tail -n 200 ~/.multica/daemon.log`.
- The daemon process's own (unlevelled) stdout/boot banner is not filtered.
- Real quieting needs an upstream `--log-level` / `MULTICA_LOG_LEVEL` on
  `multica daemon start`; that ask is tracked on the issue that produced this
  feature. Once the CLI supports it, this filter becomes a pass-through and can
  be dropped.

## Design notes

- Repos are **not** cloned at image build or at container start. Register them in Multica workspace/project metadata; materialize with `multica repo checkout` during tasks (first task may cold-clone).
- `asdf` is installed with plugin-install capability; pin tool versions on the workspaces volume, not in the image.
- Patterns inspired by community Multica runtimes (`tini`, non-root user, forge HTTPS helpers) — adapted for a Cursor-first, asdf-based baseline.
- AWS ConfigMap / aws-sso wiring is deferred past first daemon smoke.

## License

MIT — see [LICENSE](LICENSE).
