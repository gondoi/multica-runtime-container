## Running locally with Docker

Local-laptop usage of the `multica-runtime` image: a bare `docker run` for a
quick smoke, and `docker compose` for the full Secret-mount-parity setup used
day to day.

See the [root README](../README.md) for the full boot contract, secret layout,
and GitHub auth tiers. This doc only covers the Docker-specific mechanics.

### Build

```bash
# All harnesses (default): Cursor + Claude Code + OpenAI Codex
docker build -t multica-runtime:local .

# Cursor-only, ~330 MB smaller (the claude gate then fails with a clear message)
docker build --build-arg INSTALL_CLAUDE_CLI=false -t multica-runtime:local-cursor .

# Never run the codex harness? Leave it out (~320 MB smaller; the codex gate
# then fails with an actionable message):
docker build --build-arg INSTALL_CODEX_CLI=false -t multica-runtime:local-nocodex .
```

### Smoke test (no secrets, no daemon)

Verify the baseline binaries exist without booting the daemon:

```bash
docker run --rm --entrypoint /bin/bash multica-runtime:local -lc \
  'command -v multica cursor-agent claude codex gh aws asdf git ssh jq curl tini ready.sh materialize-secrets.sh agent-harness.sh && claude --version && codex --version && gh --version && aws --version'
```

### Agent CLI harnesses

`MULTICA_AGENT_CLI` (default `cursor`) decides which harnesses the entrypoint
provisions and hard-gates — `cursor`, `claude`, `codex`, or any comma
combination. Claude needs one of `ANTHROPIC_API_KEY`,
`CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_AUTH_TOKEN`; Cursor needs
`CURSOR_API_KEY`; Codex needs `OPENAI_API_KEY` or a pre-provisioned `auth.json`.
Each selected harness must have **both** its binary and a credential or the
container exits non-zero (CrashLoop) with an actionable message. Full semantics
and the credential-tier risk note:
[README → Agent CLI harnesses](../README.md#agent-cli-harnesses-multica_agent_cli).

Claude-only compose run (no Cursor key needed):

```bash
MULTICA_AGENT_CLI=claude docker compose up -d --build
```

#### Codex: credential + bubblewrap

Codex ignores `OPENAI_API_KEY` in the environment and reads
`$CODEX_HOME/auth.json`, so the entrypoint projects the key into that file
(`codex login --with-api-key`, mode 0600). Mount a `codex login` `auth.json`
instead when you want a ChatGPT-OAuth login.

Codex also runs commands through `bubblewrap`, which needs unprivileged user
namespaces. Docker's default seccomp + AppArmor profiles block that on Ubuntu,
so a **task** fails with `bwrap: No permissions to create new namespace` or
`bwrap: Failed to make / slave`. Add both opts to the service when running the
codex harness (verified minimum here; `--privileged` also works):

```yaml
services:
  runtime:
    security_opt:
      - seccomp=unconfined
      - apparmor=unconfined
```

```bash
# and check it — needs no credential
docker compose exec runtime codex sandbox -- /bin/echo ok
```

These weaken isolation for every harness in the container, so they are not
defaults: they ship commented out in `docker-compose.yml`.

Harnesses you did **not** select are masked from the PATH the daemon and its
tasks inherit (all three CLIs are installed in the image, so a Cursor-only
deployment would otherwise still expose `claude` and `codex`). Check it against
the daemon environment — `docker compose exec` shells start from the image env
instead:

```bash
# Cursor-only deployment: the daemon must not resolve claude or codex
docker compose exec runtime bash -c 'p=$(pgrep -f "multica daemon" | head -1); d=$(tr "\0" "\n" </proc/$p/environ | sed -n "s/^PATH=//p"); for b in claude codex; do PATH=$d command -v $b || echo "$b masked"; done'
```

Masking is a boot-time PATH rewrite (no uninstall): restart with a different
`MULTICA_AGENT_CLI` and the previous PATH is back. A selected harness is never
masked, so its hard gate still decides on CrashLoop.

### Run with Compose (recommended)

The repo ships a working [`docker-compose.yml`](../docker-compose.yml) at the
repo root that mirrors the Kubernetes Secret-mount contract using a local
`secrets/` tree and a named volume for `/home/agent/workspaces`.

1. Lay out the local secret files (bind-mounted read-only, never baked into
   the image):

   ```bash
   mkdir -p secrets/multica-home secrets/cursor secrets/git
   cp examples/secrets/multica-home/config.json.example secrets/multica-home/config.json
   cp examples/secrets/multica-home/daemon.id.example   secrets/multica-home/daemon.id
   # edit secrets/multica-home/config.json with your real workspace_id + token
   printf '%s' "$CURSOR_API_KEY" > secrets/cursor/CURSOR_API_KEY
   printf '%s' "$GITHUB_TOKEN"   > secrets/git/GITHUB_TOKEN
   ```

   For the Claude Code harness instead of (or alongside) Cursor, also create
   `secrets/claude/` with **one** credential file and set `MULTICA_AGENT_CLI`:

   ```bash
   mkdir -p secrets/claude
   printf '%s' "$ANTHROPIC_API_KEY" > secrets/claude/ANTHROPIC_API_KEY
   # or: printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" > secrets/claude/CLAUDE_CODE_OAUTH_TOKEN
   # then run compose with MULTICA_AGENT_CLI=claude (or cursor,claude)
   ```

   For the OpenAI Codex harness, create `secrets/codex/` with the API key (it is
   projected into `~/.codex/auth.json` at boot) — and uncomment the
   `security_opt` block in `docker-compose.yml` (see
   [Codex: credential + bubblewrap](#codex-credential--bubblewrap)):

   ```bash
   mkdir -p secrets/codex
   printf '%s' "$OPENAI_API_KEY" > secrets/codex/OPENAI_API_KEY
   # or: cp ~/.codex/auth.json secrets/codex/auth.json   # a `codex login` login
   # then run compose with MULTICA_AGENT_CLI=codex (or cursor,claude,codex)
   ```

   To use the GitHub App tier instead of a PAT, drop `secrets/git/GITHUB_TOKEN`
   and add `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and
   `GITHUB_APP_PRIVATE_KEY` files under `secrets/git/` instead — see the
   [GitHub auth precedence](../README.md#github-auth-precedence-app--pat--password)
   section in the README.

2. Optional non-secret knobs via `.env` (log level, workspace pin, etc.):

   ```bash
   cp .env.example .env
   ```

3. Bring it up:

   ```bash
   docker compose up -d --build
   docker compose ps          # "healthy" once ready.sh passes
   docker compose logs -f
   ```

4. Tear down:

   ```bash
   docker compose down
   ```

   Add `-v` to also drop the `multica-workspaces` named volume (loses the
   `.repos` cache, worktrees, and asdf installs — the next task cold-clones).

### Name the runtime (`MULTICA_MACHINE_NAME`)

Multica lists this container's runtime as `<Provider> (<machine name>)`, and the
machine name defaults to the container hostname (`multica-runtime-6cc749d9f7-dr2gh`
under Kubernetes). Give it a name that describes its scope:

```bash
# .env (picked up by the compose env_file)
MULTICA_MACHINE_NAME=fuel-general
```

The runtime list then shows `Cursor (fuel-general)` (and `Claude (fuel-general)`
when both harnesses are enabled), and the daemon's device info reads
`fuel-general · <harness version>`. Unset keeps the hostname default.
A full custom name without the provider prefix is a one-time server-side rename:
`multica runtime rename <runtime-id> fuel-general --machine` (survives recreates).
Details: [Machine name](../README.md#machine-name-multica_machine_name).

### Scratch shell

Bypass the hard gates (missing secrets/binaries) to poke around:

```bash
docker compose run --rm --entrypoint bash runtime
# or, without compose:
docker run --rm -it --entrypoint /bin/bash ghcr.io/gondoi/multica-runtime:v0.1.0
```

### AWS access from the container

The image installs the AWS CLI v2 with **no** credentials and no AWS auth
plumbing of its own — the SDK default chain resolves them, so what you wire
outside the container decides the tier ([README](../README.md#aws-auth-tiers)).

- **On an EC2 instance / ECS task with a role:** nothing to do. The chain picks
  up the instance profile / task role. This is compose's best option.
- **Static keys or a named profile (fallback only):** bind-mount a config tree
  and point the env vars at it — never bake keys into the image or `.env`:

  ```bash
  mkdir -p secrets/aws
  # secrets/aws/config       → [default] / region = us-east-1 / output = json
  # secrets/aws/credentials  → [default] / aws_access_key_id = … / aws_secret_access_key = …
  # then uncomment the two env vars + the ./secrets/aws bind-mount in
  # docker-compose.yml (or set them in .env)
  docker compose up -d
  ```

Verify and read the resolved tier:

```bash
docker compose exec runtime aws sts get-caller-identity
docker compose logs runtime | grep 'aws auth:'
```

That boot line names the source the chain resolved (`static env keys`,
`web identity / IRSA`, `container credentials endpoint`, `mounted AWS config`,
or `none detected …`). It is informational only — it never fails a boot and
never prints a credential value.

For Identity Center profiles without IRSA, compose mounts
`examples/aws/{config,config.yaml}` at `/run/config/aws*` (override with a
private allowlist). After healthy:

```bash
docker compose exec -e AWS_SSO_OPERATOR_LOGIN=1 runtime \
  aws-sso login --url-action=print
```

Agents must not run `aws-sso login` (guard exits non-zero without
`AWS_SSO_OPERATOR_LOGIN=1`). SSO cache persists on the workspaces volume.

### Optional egress control (iron-proxy)

Default-deny egress through a MITM sidecar is available but **off by default**.
The container half is small: `MULTICA_EGRESS_PROXY=iron-proxy`
+ `MULTICA_EGRESS_PROXY_CA=<ca.crt>` makes boot trust the proxy CA and fail
closed without it; the routing and the allowlist live in the deployment.

```bash
./examples/iron-proxy/gen-ca.sh
# then lay out secrets/ as above and:
docker compose -f examples/iron-proxy/docker-compose.yml up -d --build
```

Worked example, verify steps and rollback: [`examples/iron-proxy/`](../examples/iron-proxy/).
Evaluation and what is deliberately not enabled: [`docs/egress-control.md`](egress-control.md).

### Boot seam tests

Fixture-driven Ready-vs-Crash checks (stub `multica`, no live cloud needed):

```bash
./test/boot/run-seam.sh
```

Fast unit suites (auth-tier precedence, App token mint; no Docker/network):

```bash
./test/unit/run-unit.sh
```

Opt-in integration check for the egress-proxy example (Docker + internet; pulls
the upstream proxy image, so it is not part of CI):

```bash
./test/integration/egress-proxy.sh
```
