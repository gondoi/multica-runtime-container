# Multica runtime home-base

Thin container image for a **[Multica](https://multica.ai) agent runtime home-base**.

It boots a Multica daemon with Cursor as the v1 agent CLI, persists workspaces on a volume, and relies on Multica **lazy** `repo checkout` for source — no consumer monorepos are baked into the image, and there is **no** boot-time inventory clone-all.

Published image: `ghcr.io/gondoi/multica-runtime` (public GHCR, anonymous pull).

**Usage docs:** [Running locally with Docker](docs/docker.md) (incl. a working Compose setup) · [Running in Kubernetes](docs/kubernetes.md)

### Releases

Versions are cut by [Release Please](https://github.com/googleapis/release-please) from
[Conventional Commits](https://www.conventionalcommits.org/) on `main` — no manual tagging.

1. `.github/workflows/release-please.yml` keeps a **release PR** open on `main` with the next
   version, a `CHANGELOG.md` entry per commit, and a `version.txt` bump.
2. Merging that PR creates the GitHub release and the **`vX.Y.Z` tag**.
3. `.github/workflows/docker-publish.yml` publishes the images for that tag.

Config lives in-repo: `release-please-config.json` (release type `simple`, tag `v<version>`) and
`.release-please-manifest.json` (last released version). The manifest is bootstrapped at
**`0.0.0`** — nothing has been released yet — so the first release PR proposes **`v0.1.0`** with the
changelog accumulated from the repo history. While below `1.0.0`: `fix` → patch, `feat` → minor,
`BREAKING CHANGE` → minor (no `1.0.0` until you ask for it).

`.github/workflows/conventional-commits.yml` gates every PR on commit subjects
(`<type>(<scope>): <summary>`) via `test/ci/check-conventional-commits.sh`; a subject that
Release Please cannot parse would silently vanish from the changelog. Merge commits, `Revert "..."`,
and squash-merge of a conventional PR title are fine — keep commit subjects conventional, even
though the PR title carries the tracker key (e.g. `BOX-89: …`).

One-time repo setting: **Settings → Actions → General → Workflow permissions → “Allow GitHub
Actions to create and approve pull requests”** must be on, otherwise Release Please cannot open the
release PR. Optionally set a `RELEASE_PLEASE_TOKEN` secret (PAT or GitHub App token) if CI should
run on the release PR itself; without it, `release-please.yml` dispatches the image publish
directly, because tags created with `GITHUB_TOKEN` never trigger other workflows.

### CI publish

GitHub Actions (`.github/workflows/docker-publish.yml`) builds **linux/amd64 + linux/arm64** via `FuelLabs/github-actions` `docker-build-push` and pushes pin-friendly tags only (no `latest`):

| Trigger | When |
| --- | --- |
| Git tag `vX.Y.Z` | Release tagged by Release Please (or pushed by hand for the same shape) |
| `workflow_dispatch` | Manual re-publish — select an existing `vX.Y.Z` tag as the ref |

Anything that is not a semver tag fails the `prepare` job; there are no per-commit image tags.

| Tag shape | Example |
| --- | --- |
| Release version | `v0.1.0` |
| Release version (no `v`) | `0.1.0` |

Deployments (Compose, Kubernetes) should pin a release tag such as `v0.1.0`.

## What's in the image

| Component | Role |
| --- | --- |
| `multica` CLI + daemon | Runtime identity and task execution |
| `cursor-agent` | First agent provider (Cursor) |
| `asdf` | Versioned tool plugins (languages / CLIs) on the workspaces volume |
| `git`, `openssh-client`, `jq`, `curl`, `procps` | Checkout, scripting, readiness probes |
| `gh` (GitHub CLI) | Agent tooling (`gh pr create`, `gh api`, `gh run`); authenticates from the resolved tier — App tier re-mints per invocation |
| `aws` (AWS CLI v2) | Agent tooling to inspect/manage AWS resources; auth resolved by the SDK default chain (IRSA / instance profile / mounted config / aws-sso) — no keys baked in |
| `aws-sso` | Upstream synfinatic CLI at `/usr/local/bin/aws-sso` (guard → `/usr/local/libexec/aws-sso`); operator-exec login only |
| `tini` | PID 1 — reaps orphans, forwards signals |
| non-root `agent` user | Default runtime identity |
| `/usr/local/bin/ready.sh` | Shallow Ready probe (daemon up — not full inventory) |

**Not** in the image: language toolchains (install via asdf at runtime), AWS credentials of any kind, multi-CLI agent sets (Claude/Codex/etc.), or any private consumer AWS allowlist / inventory.

## Boot contract

Order:

1. Source config (`.env` / Secret env-file mounts)
2. Materialize Secret-projected Multica home (`config.json` + `daemon.id`) into ephemeral `~/.multica`; load Cursor/git token (and optional GitHub App) files
3. Wire optional AWS ConfigMaps into PVC-backed `~/.aws` + `~/.config/aws-sso` (SSO cache on workspaces volume)
4. Hard gates — required binaries (`multica`, `cursor-agent`, `gh`, `git`, `jq`, `curl`, `asdf`, `aws`, `aws-sso`) and secrets (Multica auth, `CURSOR_API_KEY`, forge token **or** GitHub App / GHES credentials)
5. Configure git HTTPS credential helper; validate `MULTICA_LOG_LEVEL`; report AWS credential source
6. `multica login` (token refresh) → **re-pin workspace** → daemon start --foreground

**Ready** = daemon is up after gates. **Crash** = missing Multica/Cursor/git secret or required binary (non-zero exit → CrashLoop). Missing AWS ConfigMaps → continue degraded (daemon still Ready).

**Workspace pin** (after login): `MULTICA_WORKSPACE` (preferred; slug, display name, or UUID) → `MULTICA_WORKSPACE_ID` (same resolution) → projected Secret `config.json` `.workspace_id` → leave login default.

There is **no** ConfigMap inventory sync at boot. Repo trees land on the workspaces volume when Multica runs `repo checkout` for a task. The **first task may cold-clone**; that is expected and is not a Ready gate.

Scratch shell (bypasses gates): `docker run --rm -it --entrypoint /bin/bash ghcr.io/gondoi/multica-runtime:v0.1.0`

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

### AWS profiles (ConfigMaps + PVC cache)

| ConfigMap / file | Mount path | Purpose |
| --- | --- | --- |
| `multica-runtime-aws` → `config` | `/run/config/aws/config` | Literal `~/.aws/config` (`credential_process` → `/usr/local/bin/aws-sso`) |
| `multica-runtime-aws-sso` → `config.yaml` | `/run/config/aws-sso/config.yaml` | aws-sso StartUrl / UrlAction=print / profile format |

Entrypoint links those files into **workspaces PVC** provider homes (`.provider-homes/aws` and `.provider-homes/aws-sso`) so the SSO token cache survives recreate. Published examples ship **generic stubs** only — curated account allowlists stay in a private overlay.

- **`AWS_PROFILE` unset** — callers pass `--profile` / `AWS_PROFILE` per command.
- **Login is operator-exec only.** Agents must not drive SSO:

```bash
# Compose
docker compose exec -e AWS_SSO_OPERATOR_LOGIN=1 runtime \
  aws-sso login --url-action=print

# Kubernetes
kubectl exec -it deploy/multica-runtime -n <ns> -- \
  env AWS_SSO_OPERATOR_LOGIN=1 aws-sso login --url-action=print
```

Without `AWS_SSO_OPERATOR_LOGIN=1`, `aws-sso login` exits non-zero (guard wrapper). Dead cache → AWS calls fail closed until an operator re-logins. Details: [`examples/aws/`](examples/aws/).

### GitHub App git auth (no PAT)

For orgs that disallow PATs, create a GitHub App with **minimum** permissions:

| Permission | Access | Why |
| --- | --- | --- |
| Metadata | Read | Required baseline |
| Contents | Read and write | Clone + push agent feature branches |
| Pull requests | Read and write | Open PRs |

**Do not** grant administration or “bypass branch protection / rules”. Protected `main` stays PR-only; the App cannot push straight to protected branches.

Install the App on the target account/org (select only the repos agents need). Project App ID, installation ID, and the downloaded PEM under `/run/secrets/git/`. Boot mints an installation token and configures a git credential helper that remints when the ~1h token expires.

## AWS CLI

`aws` (v2, pinned in the `Dockerfile`) is installed for agents to inspect and
manage AWS resources (`aws sts get-caller-identity`, `aws s3 ls`, `aws ec2
describe-instances`, …). **No AWS credentials are baked into the image or
written by any script here** — this container does zero credential plumbing
for AWS; it only installs the binary and documents how the AWS SDK's own
default credential chain finds credentials wherever you run it.

### AWS auth tiers

Highest trust first — pick the topmost tier your platform supports:

⚠️ **Flagging this as higher-risk, same as the GitHub auth tiers**: whichever
tier you pick grants the container (and therefore every agent task running in
it) whatever AWS permissions that identity has. Scope the IAM role/policy to
the minimum the agents actually need, and prefer the tiers that avoid
long-lived static keys.

| Tier | Mechanism | Where it's wired | Static keys in the container? |
| --- | --- | --- | --- |
| 1 · IRSA (EKS, best) | Pod's ServiceAccount is annotated with an IAM role ARN; EKS injects `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` and projects the token — the AWS SDK default chain picks it up with zero container-side config | `examples/k8s/serviceaccount.yaml` (annotation) + `serviceAccountName` in `deployment.yaml` — see [`docs/kubernetes.md`](docs/kubernetes.md) | No |
| 2 · Instance profile / ECS task role | EC2 instance profile or ECS task role; the SDK default chain calls the metadata service automatically | Node/task IAM role — nothing in this repo to configure | No |
| 3 · Mounted `~/.aws` config (fallback, lowest priority) | Secret-projected (or compose bind-mounted) `config`/`credentials` files, pointed to via `AWS_CONFIG_FILE`/`AWS_SHARED_CREDENTIALS_FILE` | `docker-compose.yml`, `examples/k8s/secret.example.yaml` (commented) | Only if you put static `aws_access_key_id`/`aws_secret_access_key` in the mounted file — avoid this when tiers 1 or 2 are available |

This image never writes `~/.aws` itself — there is no `materialize-secrets.sh`
step for AWS, deliberately, so a mounted `config`/`credentials` file is read
straight from the Secret/bind-mount path via the two env vars above and
nothing is copied or logged. Tier selection is **by what you wire outside the
container** (ServiceAccount annotation, instance role, or a mounted file) —
there is no `AWS_AUTH_TIER` switch to force one, because the SDK's own chain
already tries them in a fixed, well-documented order.

Footprint: the official v2 installer adds ~236 MB (`/usr/local/aws-cli`) to the
image (~1.05 GB built here). There is no opt-out build arg — a slim variant
would need a second Dockerfile stage/target rather than a flag.

Boot logs which source the chain resolves (`aws auth: …` from
`bin/aws-credential-source.sh`) — informational only, never a gate, never a
credential value. Docker/compose specifics: [`docs/docker.md`](docs/docker.md);
Kubernetes/IRSA walkthrough: [`docs/kubernetes.md`](docs/kubernetes.md).

## Build locally

```bash
docker build -t multica-runtime:local .
```

Smoke that baseline binaries exist:

```bash
docker run --rm --entrypoint /bin/bash multica-runtime:local -lc \
  'command -v multica cursor-agent gh aws aws-sso asdf git ssh jq curl tini ready.sh materialize-secrets.sh materialize-aws.sh && gh --version && aws --version && aws-sso version'
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
- `asdf` is installed with plugin-install capability; pin tool versions (including AWS CLI) on the workspaces volume, not in the image. Upstream `aws-sso` is image-pinned at a fixed path for stable `credential_process` lines.
- Patterns inspired by community Multica runtimes (`tini`, non-root user, forge HTTPS helpers) — adapted for a Cursor-first, asdf-based baseline.
- AWS CLI ships with no baked credentials — prefer IRSA / instance role (see [AWS CLI auth tiers](#aws-auth-tiers)). ConfigMap `aws-sso` profiles + operator-exec login are supported for homelab (see [AWS profiles](#aws-profiles-configmaps--pvc-cache)); SSO cache lives on the workspaces PVC.

## License

MIT — see [LICENSE](LICENSE).
