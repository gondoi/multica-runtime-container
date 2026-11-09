# Pinned dependency updates

Every version this image builds against is pinned in `Dockerfile` (`ARG X_VERSION=…`)
or in `.github/workflows/`. Renovate tracks those pins from `renovate.json` and
opens a bump PR for each one it can resolve. No auto-merge is configured: a bump
only lands after review, `boot-seam.yml` and `conventional-commits.yml` pass.

This page exists because three of the pins are **not** on GitHub releases and are
therefore tracked through Renovate `customDatasources` (HTTP fetch + JSONata
extraction) instead of a built-in datasource. If one of those feeds changes
shape, that pin silently stops producing updates — the sections below say how to
notice and how to check by hand.

## Tracked pins

| Dockerfile `ARG` | Upstream | Renovate datasource | Versioning |
| --- | --- | --- | --- |
| `MULTICA_VERSION` | `multica-ai/multica` GitHub releases | `github-releases` | semver |
| `CLAUDE_CODE_VERSION` | `downloads.claude.ai/claude-code-releases/latest` | `custom.claude-code-releases` | semver |
| `CURSOR_AGENT_VERSION` | version embedded in `https://cursor.com/install` | `custom.cursor-agent-lab` | loose |
| `AWS_CLI_VERSION` | first version heading of `aws/aws-cli` `CHANGELOG.rst` | `custom.aws-cli-changelog` | semver |

The remaining GitHub-hosted pins (`ASDF_VERSION`, `GH_VERSION`, `CODEX_VERSION`,
`AWS_SSO_VERSION`) get plain `github-releases` custom managers; they are added by
a separate change, so this table only lists what `renovate.json` covers today.

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

## Validate a config change

Two commands, both run from the repo root:

```bash
# schema validation
npx --yes --package=renovate@42.99.0 -- renovate-config-validator renovate.json

# resolve every pin against the live upstreams without opening PRs
LOG_LEVEL=debug npx --yes --package=renovate@42.99.0 -- renovate \
  --platform=local --dry-run=lookup
```

A healthy run ends with `N flattened updates found: …` and no
`Failed to look up`, `Invalid JSONata expression` or
`Error while evaluating JSONata expression` warnings.

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
