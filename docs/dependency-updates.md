## Dependency and pin updates

Every version pin in this repo is watched by [Renovate](https://docs.renovatebot.com/)
(`renovate.json`, config preset `config:recommended`). Renovate also owns the
GitHub Actions pins — there is no Dependabot config, and none should be added:
two tools on the same lines means duplicate PRs.

New versions surface on the Dependency Dashboard issue (`Dependency Dashboard`,
opened by `app/renovate`) and as `chore(deps): …` PRs.

### What is watched

| Pin (where) | Datasource | Notes |
| --- | --- | --- |
| `ARG MULTICA_VERSION` (Dockerfile) | `github-releases` `multica-ai/multica` | Upstream tag `vX.Y.Z`, ARG holds `X.Y.Z` |
| `ARG ASDF_VERSION` (Dockerfile) | `github-releases` `asdf-vm/asdf` | Upstream tag `vX.Y.Z`, ARG holds `vX.Y.Z` (URL is built from the raw value) |
| `ARG GH_VERSION` (Dockerfile) | `github-releases` `cli/cli` | Upstream tag `vX.Y.Z`, ARG holds `X.Y.Z` |
| `ARG AWS_SSO_VERSION` (Dockerfile) | `github-releases` `synfinatic/aws-sso-cli` | Upstream tag `vX.Y.Z`, ARG holds `X.Y.Z` |
| `FROM debian:bookworm-slim@sha256:…` (Dockerfile) | built-in `dockerfile` manager | Digest tracking, see below |
| `actions/checkout`, `docker/login-action`, `googleapis/release-please-action` | built-in `github-actions` manager | Bumped as normal version PRs |
| `FuelLabs/github-actions/…@<sha>` (docker-publish.yml) | custom `git-refs` manager | Branch-tip digest tracking, see below |

`CURSOR_AGENT_VERSION`, `CLAUDE_CODE_VERSION`, `AWS_CLI_VERSION`, `CODEX_VERSION`
and the `CODEX_PACKAGE_SHA256_*` checksums are **not** watched yet — see
"What is still manual".

### Base image: why the `FROM` line is digest-pinned

`debian:bookworm-slim` is a floating codename tag, not a version: Renovate's
`dockerfile` manager reports it as `invalid-value` and the dependency never
reaches the dashboard, so a renewal of the base image is invisible.

Decision: **pin the manifest-list digest** and let Renovate track it
(`FROM debian:bookworm-slim@sha256:…`). With a `currentDigest` present Renovate
stops skipping the dependency and produces a `digest` update whenever the
`bookworm-slim` tag moves, which is exactly a Debian point release.

Consequences to keep in mind:

- A digest bump is a reviewable PR, not a silent rebuild — that is the point,
  but it does mean Debian security updates land only when such a PR merges.
- Digest PRs touch `Dockerfile`, so `boot-seam.yml` rebuilds the image. Treat a
  failing seam build as a blocker for that digest.
- The digest is the multi-arch index digest, so `linux/amd64` and
  `linux/arm64/v8` both resolve from the same pin.

### `FuelLabs/github-actions` reusable workflow

`FuelLabs/github-actions` publishes **no tags and no releases** (its default
branch is `master`), so the SHA pin cannot be given a version comment and the
built-in `github-actions` manager extracts it as `unversioned-reference` with
`enabled: false` — invisible on the dashboard, which is why it went untracked.

The custom manager matches the `uses:` line and uses the `git-refs` datasource
with `currentValueTemplate: "master"`, so the dependency tracks the `master`
tip by digest. When upstream commits, Renovate opens a PR that rewrites only
the SHA in the `uses:` line.

Caveats:

- Updates are untagged commits, so PR titles cannot say which upstream version
  they carry. Read the upstream commit before merging.
- `git-refs` shells out to `git ls-remote`. Verified working in a self-hosted
  Renovate run; if the hosted Renovate app sandbox blocks git, this dependency
  stays silent and needs the fallback below.
- If upstream ever starts tagging releases, replace this with the built-in
  manager plus a `# vX.Y.Z` comment on the `uses:` line.

### What is still manual

| Pin | Why not automated |
| --- | --- |
| `CURSOR_AGENT_VERSION` | `downloads.cursor.com` has no GitHub-release-style feed |
| `CLAUDE_CODE_VERSION` | `downloads.claude.ai` manifest needs the version in the URL first |
| `AWS_CLI_VERSION` | AWS installer versioning, no machine-readable "latest" |
| `CODEX_VERSION` + `CODEX_PACKAGE_SHA256_*` | GitHub-hosted, but the checksum ARGs must be bumped in the same commit as the version (the build fails closed on mismatch), so a plain bump PR would go red until the checksums are updated by hand |

Check the Cursor, Claude Code, AWS CLI and Codex pins by hand when touching the
`Dockerfile`: see each pin's comment block in the `Dockerfile` for how the value
is consumed, and the upstream release pages for the current version.

### Review and merge policy

- **No auto-merge anywhere** (`automerge: false`). Every bump PR goes through
  review plus `boot-seam.yml` (which builds the image, so a broken download URL
  fails CI) and `conventional-commits.yml`.
- Renovate PRs carry no issue-tracker key: their subjects are `chore(deps): …`,
  and a fixed tracker key in `prTitle` would go stale. Bot work is tracked by
  the Dependency Dashboard issue instead.
- Rollback of any bump is a revert of its PR.

### Validating config changes locally

```bash
# Schema/config check
docker run --rm -v "$PWD":/usr/src/app -w /usr/src/app \
  renovate/renovate:44.221.1 renovate-config-validator

# Resolve every dependency against the real upstreams (no branches, no PRs).
# GITHUB_COM_TOKEN is what lets the github-* datasources look up releases in
# local mode; without it they are skipped as "github-token-required".
docker run --rm -v "$PWD":/usr/src/app -w /usr/src/app \
  -e GITHUB_TOKEN="$(gh auth token)" -e GITHUB_COM_TOKEN="$(gh auth token)" \
  -e LOG_LEVEL=debug \
  renovate/renovate:44.221.1 --platform=local --dry-run=lookup
```

The debug output lists every extracted dependency with its `updates` array. To
prove a pin is actually watched, drop it to an older version in a scratch copy
and re-run: the pin must show a `newValue`/`newDigest` update.
