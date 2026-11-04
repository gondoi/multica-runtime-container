## Running locally with Docker

Local-laptop usage of the `multica-runtime` image: a bare `docker run` for a
quick smoke, and `docker compose` for the full Secret-mount-parity setup used
day to day.

See the [root README](../README.md) for the full boot contract, secret layout,
and GitHub auth tiers. This doc only covers the Docker-specific mechanics.

### Build

```bash
docker build -t multica-runtime:local .
```

### Smoke test (no secrets, no daemon)

Verify the baseline binaries exist without booting the daemon:

```bash
docker run --rm --entrypoint /bin/bash multica-runtime:local -lc \
  'command -v multica cursor-agent gh aws asdf git ssh jq curl tini ready.sh materialize-secrets.sh && gh --version && aws --version'
```

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

### Scratch shell

Bypass the hard gates (missing secrets/binaries) to poke around:

```bash
docker compose run --rm --entrypoint bash runtime
# or, without compose:
docker run --rm -it --entrypoint /bin/bash ghcr.io/gondoi/multica-runtime:sha-<tag>
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
never prints a credential value. `aws-sso` / `aws configure sso` stays deferred:
the device-authorization flow needs an interactive browser step.

### Boot seam tests

Fixture-driven Ready-vs-Crash checks (stub `multica`, no live cloud needed):

```bash
./test/boot/run-seam.sh
```

Fast unit suites (auth-tier precedence, App token mint; no Docker/network):

```bash
./test/unit/run-unit.sh
```
