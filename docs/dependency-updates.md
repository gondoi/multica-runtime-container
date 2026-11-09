# Pinned dependency updates

Every version this image builds against is pinned in `Dockerfile` (`ARG X_VERSION=…`,
the digest-pinned base image) or in `.github/workflows/`. Renovate tracks those pins
from `renovate.json` and opens a bump PR for each one it can resolve. No auto-merge is
configured: a bump only lands after review, `boot-seam.yml` (which builds the image)
and `conventional-commits.yml` pass. Renovate PRs carry no tracker key — their subjects
are `chore(deps): …` and a fixed key in `prTitle` would go stale — so bot work is
tracked through the Dependency Dashboard issue instead. Rollback of any bump is a
revert of its PR.

This page exists because some pins cannot be expressed as a plain `github-releases`
lookup: three have no GitHub releases at all and use Renovate `customDatasources`
(HTTP fetch + JSONata extraction), the base image tag is a codename rather than a
version, and one pin is a SHA on an upstream that tags nothing. If one of those feeds
changes shape, that pin silently stops producing updates — the sections below say how
to notice and how to check by hand.

## Tracked pins

| Pin (where) | Upstream | Renovate datasource | Versioning |
| --- | --- | --- | --- |
| `ARG MULTICA_VERSION` | `multica-ai/multica` GitHub releases | `github-releases` | semver |
| `ARG ASDF_VERSION` | `asdf-vm/asdf` GitHub releases | `github-releases` | semver-coerced |
| `ARG GH_VERSION` | `cli/cli` GitHub releases | `github-releases` | semver |
| `ARG AWS_SSO_VERSION` | `synfinatic/aws-sso-cli` GitHub releases | `github-releases` | semver |
| `ARG CLAUDE_CODE_VERSION` | `downloads.claude.ai/claude-code-releases/latest` | `custom.claude-code-releases` | semver |
| `ARG CURSOR_AGENT_VERSION` | version embedded in `https://cursor.com/install` | `custom.cursor-agent-lab` | loose |
| `ARG AWS_CLI_VERSION` | first version heading of `aws/aws-cli` `CHANGELOG.rst` | `custom.aws-cli-changelog` | semver |
| `FROM debian:bookworm-slim@sha256:…` | Docker Hub `debian` tag digest | built-in `dockerfile` manager | digest only |
| `actions/*`, `docker/*`, `googleapis/release-please-action` | action tags | built-in `github-actions` manager | github-actions |
| `FuelLabs/github-actions/…@<sha>` (`.github/workflows/docker-publish.yml`) | `FuelLabs/github-actions` `master` branch tip | `git-refs` (custom manager) | branch digest |

`CODEX_VERSION` and the `*_PACKAGE_SHA256_*` checksum `ARG`s are **not** tracked — see
"Pins that still need a manual check".

Two tag-format details are load-bearing, because the Dockerfile builds its download
URLs from the raw `ARG` values:

- `ASDF_VERSION` keeps upstream's `v` prefix, so its manager uses no
  `extractVersionTemplate` and `semver-coerced` versioning (which orders the tags
  without rewriting them). Stripping the `v` there breaks the asdf download URL.
- `MULTICA_VERSION`, `GH_VERSION` and `AWS_SSO_VERSION` hold bare `X.Y.Z`, so their
  managers strip the tag's `v` with `extractVersionTemplate` and the Dockerfile re-adds
  it (`…/download/v${GH_VERSION}/…`).

## Base image: why the `FROM` line is digest-pinned

`debian:bookworm-slim` is a floating codename tag, not a version: Renovate's
`dockerfile` manager reports it as `invalid-value` and the dependency never reaches the
dashboard, so a renewal of the base image is invisible. Renovate's lookup clears that
skip once a `currentDigest` (or `pinDigests`) is present, so the `FROM` line pins the
manifest-list digest and Renovate proposes a digest update whenever the
`bookworm-slim` tag moves — which is exactly a Debian point release.

Consequences to keep in mind:

- A digest bump is a reviewable PR, not a silent rebuild. That is the point, but it
  does mean Debian security updates land only when such a PR merges.
- Digest PRs touch `Dockerfile`, so `boot-seam.yml` rebuilds the image. Treat a
  failing seam build as a blocker for that digest.
- The digest is the multi-arch index digest, so `linux/amd64` and `linux/arm64/v8`
  both resolve from the same pin.

## `FuelLabs/github-actions` reusable workflow

`FuelLabs/github-actions` publishes **no tags and no releases** (default branch
`master`), so the SHA pin cannot be given a version comment. The built-in
`github-actions` manager does extract the `uses:` line — as `depType: workflow` — but
with no comment to resolve it sets `enabled: false` / `skipReason:
unversioned-reference`, and a disabled dependency never reaches the dashboard. That is
why this pin had zero automated visibility.

The custom manager matches the `uses:` line and uses the `git-refs` datasource with
`currentValueTemplate: "master"`, so the dependency tracks the `master` tip by digest.
When upstream commits, Renovate opens a PR that rewrites only the SHA.

Caveats:

- Updates are untagged commits, so the PR title cannot say which upstream change it
  carries. Read the upstream commit before merging.
- `git-refs` shells out to `git ls-remote`. Verified in a self-hosted run; if the
  hosted Renovate app blocks git, this dependency stays silent (see "How you notice a
  broken feed").
- If upstream ever starts tagging releases, replace this with the built-in manager plus
  a `# vX.Y.Z` comment on the `uses:` line.

## Why custom datasources for the three

- **Claude Code CLI** — `downloads.claude.ai/claude-code-releases/<version>/…` needs
  the version in the path, so the version cannot be read from the artifact URL.
  The same host serves the newest published version as a one-line plain-text body
  at `/claude-code-releases/latest` (identical to the npm `latest` dist-tag of
  `@anthropic-ai/claude-code`). That body is the datasource.
  `/claude-code-releases/stable` exists too and lags `latest`; switching to it is a
  one-line URL change if the more conservative channel is wanted.
- **cursor-agent CLI** — `downloads.cursor.com` is a bucket with no listing and no
  version feed (`/`, `/lab/`, `/lab/versions` all return 403). Cursor's own
  installer script does hardcode the current build path
  (`https://downloads.cursor.com/lab/<version>/<os>/<arch>/agent-cli-package.tar.gz`),
  so the version is extracted from that script body. The script is only read as
  text — it is never executed.
- **AWS CLI v2** — AWS publishes no machine-readable "current v2 version" file at a
  stable URL (`awscli.amazonaws.com/V2/latest.txt` does not exist; the unversioned
  installer zip carries no version metadata). `aws/aws-cli`'s own `CHANGELOG.rst`
  is the authoritative release list and every released version is its own line,
  so the changelog doubles as the version list. The file is ~1.5 MB; that is the
  cost of one lookup per Renovate run. Homebrew's `awscli` formula API
  (`https://formulae.brew.sh/api/formula/awscli.json`) is a lighter alternative,
  but it lags AWS by a release or two.

## Pins that still need a manual check

| Pin | Why it is not automated |
| --- | --- |
| `CODEX_VERSION` + `CODEX_PACKAGE_SHA256_LINUX_*` | GitHub-hosted (`openai/codex`, tags `rust-vX.Y.Z`), but the build fails closed when the checksum does not match, so a version bump and its paired hashes must land in the same commit. Tracking it would produce red PRs until the hashes are recomputed by hand. |
| `CURSOR_AGENT_PACKAGE_SHA256_LINUX_*` | Same pairing rule: a `CURSOR_AGENT_VERSION` bump PR fails the build until both hashes are recomputed and pushed to the Renovate branch (recipe: README "Checksum verification and version bumps"). The red CI is the reminder, not a defect. |

Check the Codex pin by hand when touching the `Dockerfile`: see its comment block for
how the value and hashes are consumed, and the `openai/codex` release assets for the
current version.

## Manual check

Run these when a dashboard entry looks stale, or when a bump PR does not appear
after an upstream release you expected. Weekly is enough; the repo maintainer owns
this check.

```bash
# Claude Code CLI — expected: a bare version, e.g. 2.1.321
curl -fsSL https://downloads.claude.ai/claude-code-releases/latest

# cursor-agent — expected: the build path Cursor's installer would use
curl -fsSL https://cursor.com/install | grep -o 'downloads\.cursor\.com/lab/[^/]*'

# AWS CLI v2 — expected: newest version as the first release heading
curl -fsSL https://raw.githubusercontent.com/aws/aws-cli/v2/CHANGELOG.rst | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+$'

# FuelLabs/github-actions — expected: the master tip commit that the workflow pin should carry
git ls-remote https://github.com/FuelLabs/github-actions refs/heads/master
```

If a command no longer returns a version, the datasource in `renovate.json` needs
updating. Until it is fixed that pin is **not** tracked, so bump the `ARG` by hand
in the meantime.

## How you notice a broken feed

- Renovate's Dependency Dashboard issue lists the pin with
  `Failed to look up …` under warnings instead of an update. The dashboard header
  also points back here.
- A pin that resolves but yields nothing newer shows no update, which looks the
  same as "already current" — that is why the manual check above exists.
- The `FuelLabs` digest dependency fails differently: a git error surfaces as the
  dependency's `internal-error` skip reason, so it disappears from the dashboard
  rather than warning. Confirm it is still listed after a config change.

## Validate a config change

Run from the repo root. The pinned Renovate image keeps the result independent of the
local Node version:

```bash
# schema validation
docker run --rm -v "$PWD":/usr/src/app -w /usr/src/app \
  renovate/renovate:44.221.1 renovate-config-validator

# resolve every pin against the live upstreams without opening PRs.
# GITHUB_COM_TOKEN is what lets the github-* datasources look up releases in local
# mode; without it every GitHub-hosted pin is skipped as "github-token-required".
docker run --rm -v "$PWD":/usr/src/app -w /usr/src/app \
  -e GITHUB_TOKEN="$(gh auth token)" -e GITHUB_COM_TOKEN="$(gh auth token)" \
  -e LOG_LEVEL=debug \
  renovate/renovate:44.221.1 --platform=local --dry-run=lookup
```

A healthy run ends with `N flattened updates found: …` and no `Failed to look up`,
`Invalid JSONata expression` or `Error while evaluating JSONata expression` warnings.
Run it from a copy whose `.git` is a real directory (a `git` worktree's gitfile points
outside the container mount and makes the `git-refs` lookup fail).

To prove a pin is actually watched, drop it to an older version in that copy and re-run:
the dependency must show a `newValue`/`newDigest` update. Note that `--dry-run=full` on
`--platform=local` does not create local branches, so the lookup diff is the evidence.

## Editing a custom datasource

Each entry is a `customDatasources.<key>` object plus a `customManagers` rule that
points at it through `datasourceTemplate: "custom.<key>"`:

- `format` is `plain` for all three. The plain fetcher splits the response on
  newlines and turns **each line** into a `releases[].version` entry, then trims
  it. That is why the Claude and AWS sources need no `transformTemplates` — the
  version already sits on its own line — and why cursor-agent does: its version is
  embedded in a line of shell, so a JSONata `$match` extracts it.
- `transformTemplates` receive the already-parsed object
  (`{ "releases": [ { "version": "<line>" }, … ] }`), not the raw body string.
- The JSONata string functions (`$trim`, `$split`, `$match`) reject the whole
  object, so operate on `releases.version` and join it first when a regex has to
  span the document.
