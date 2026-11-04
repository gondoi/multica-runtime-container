# Multica runtime home-base — thin baseline image.
#
# Ships: OS essentials, Multica CLI, cursor-agent + Claude Code CLIs (the two
# agent CLI harnesses this image gates/authenticates), asdf (+ plugin install),
# tini, non-root agent user. No consumer repo trees. No other agent CLIs.
# Harness invocation/protocol parsing belongs to the Multica CLI, not this image.
# No mise (asdf is the locked version manager).
#
# Build:  docker build -t multica-runtime:local .
# Shell:  docker run -it --rm multica-runtime:local
#
# Base: Debian bookworm-slim (stack-agnostic; language toolchains via asdf later).
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG ASDF_VERSION=v0.20.2
# Pin Multica CLI + Cursor agent for reproducible builds; bump deliberately.
ARG MULTICA_VERSION=0.8.0
ARG CURSOR_AGENT_VERSION=2026.10.22-27dcf5f
# Claude Code CLI (native binary, no Node in the image). Pinned + checksum
# verified against downloads.claude.ai's manifest. INSTALL_CLAUDE_CLI=false
# produces a Cursor-only image (~330 MB smaller) for deployments that never run
# the claude harness — the boot gate then rejects MULTICA_AGENT_CLI=claude.
ARG CLAUDE_CODE_VERSION=2.1.316
ARG INSTALL_CLAUDE_CLI=true
# GitHub CLI (pinned). Installed as gh-real; /usr/local/bin/gh is bin/gh-wrapper.sh.
ARG GH_VERSION=2.103.3
# AWS CLI v2 (pinned). No baked-in credentials — see README AWS auth tiers.
ARG AWS_CLI_VERSION=2.31.11
# Upstream synfinatic/aws-sso-cli (not fuel-internal -eks). Pin deliberately.
ARG AWS_SSO_VERSION=2.1.0

# ── System deps (language-agnostic) ──────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    openssl \
    openssh-client \
    procps \
    tini \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# ── Non-root user ─────────────────────────────────────────────────────────
RUN groupadd -g 10001 agent && \
    useradd -u 10001 -g agent -m -s /bin/bash agent && \
    mkdir -p /home/agent/.local/bin \
             /home/agent/.local/share/asdf \
             /home/agent/.asdf \
             /home/agent/.multica \
             /home/agent/workspaces \
             /home/agent/.cache \
             /home/agent/.config && \
    chown -R agent:agent /home/agent
ENV HOME=/home/agent

# ── asdf (Go binary; plugin install at runtime — no toolchains baked) ────
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) asdf_arch=amd64 ;; \
      arm64) asdf_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-${asdf_arch}.tar.gz" \
      | tar -xz -C /usr/local/bin asdf && \
    chmod +x /usr/local/bin/asdf

# ── Multica CLI (pinned release tarball) ─────────────────────────────────
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) m_arch=amd64 ;; \
      arm64) m_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${m_arch}.tar.gz" \
      | tar -xz -C /usr/local/bin multica && \
    chmod +x /usr/local/bin/multica

# ── cursor-agent (pinned lab package) ────────────────────────────────────
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) c_arch=x64 ;; \
      arm64) c_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    mkdir -p /home/agent/.local/share/cursor-agent/versions/${CURSOR_AGENT_VERSION} && \
    curl -fsSL "https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${c_arch}/agent-cli-package.tar.gz" \
      | tar --strip-components=1 -xzf - -C /home/agent/.local/share/cursor-agent/versions/${CURSOR_AGENT_VERSION} && \
    ln -sf /home/agent/.local/share/cursor-agent/versions/${CURSOR_AGENT_VERSION}/cursor-agent /usr/local/bin/cursor-agent && \
    ln -sf /home/agent/.local/share/cursor-agent/versions/${CURSOR_AGENT_VERSION}/cursor-agent /usr/local/bin/agent && \
    chown -R agent:agent /home/agent/.local

# ── Claude Code CLI (pinned native binary; no Node, no baked credentials) ──
# Downloaded straight from Anthropic's release host and verified against the
# documented per-platform SHA-256 (not `curl | bash`), so the build is
# reproducible and the pin is auditable. Auth is env-only at runtime
# (ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_AUTH_TOKEN) — see
# README "Agent CLI harnesses".
RUN set -eux; \
    if [ "${INSTALL_CLAUDE_CLI}" != "true" ]; then \
      echo "claude CLI: skipped (INSTALL_CLAUDE_CLI=${INSTALL_CLAUDE_CLI})"; \
      exit 0; \
    fi; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) c_platform=linux-x64 ;; \
      arm64) c_platform=linux-arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}"; \
    want="$(curl -fsSL "$base/manifest.json" | jq -r --arg p "$c_platform" '.platforms[$p].checksum // empty')"; \
    if ! printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$'; then \
      echo "claude CLI: no manifest checksum for $c_platform (version ${CLAUDE_CODE_VERSION})" >&2; \
      exit 1; \
    fi; \
    mkdir -p /usr/local/lib/claude; \
    curl -fsSL "$base/$c_platform/claude" -o /usr/local/lib/claude/claude; \
    printf '%s  %s\n' "$want" /usr/local/lib/claude/claude | sha256sum -c -; \
    chmod 755 /usr/local/lib/claude/claude; \
    ln -sf /usr/local/lib/claude/claude /usr/local/bin/claude; \
    mkdir -p /home/agent/.claude; \
    chown agent:agent /home/agent/.claude; \
    claude --version

# ── GitHub CLI (pinned release tarball; wrapper installed below) ─────────
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) gh_arch=amd64 ;; \
      arm64) gh_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz" \
      | tar -xz -C /usr/local/bin --strip-components=2 "gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" && \
    mv /usr/local/bin/gh /usr/local/bin/gh-real && \
    chmod +x /usr/local/bin/gh-real && \
    /usr/local/bin/gh-real --version

# ── AWS CLI v2 (pinned official installer; no credentials baked in) ──────
# Auth is resolved at runtime by the SDK's default chain (env vars, IRSA web
# identity token, EC2/ECS instance role, or a mounted ~/.aws config/credentials
# file) — see README "AWS CLI auth tiers". Nothing here writes credentials.
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) aws_arch=x86_64 ;; \
      arm64) aws_arch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}-${AWS_CLI_VERSION}.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws && \
    aws --version

# ── Upstream aws-sso (Aaron Turner) — fixed path for credential_process ──
RUN mkdir -p /usr/local/libexec && \
    arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) sso_arch=amd64 ;; \
      arm64) sso_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/synfinatic/aws-sso-cli/releases/download/v${AWS_SSO_VERSION}/aws-sso-${AWS_SSO_VERSION}-linux-${sso_arch}" \
      -o /usr/local/libexec/aws-sso && \
    chmod 755 /usr/local/libexec/aws-sso

# ── Forge HTTPS helper + GitHub App mint + secret/AWS materialize + ready ─
COPY bin/agent-harness.sh /usr/local/bin/agent-harness.sh
COPY bin/configure-git-auth.sh /usr/local/bin/configure-git-auth.sh
COPY bin/mint-github-app-token.sh /usr/local/bin/mint-github-app-token.sh
COPY bin/github-app-credential-helper.sh /usr/local/bin/github-app-credential-helper.sh
COPY bin/materialize-secrets.sh /usr/local/bin/materialize-secrets.sh
COPY bin/log-level-filter.sh /usr/local/bin/log-level-filter.sh
COPY bin/aws-credential-source.sh /usr/local/bin/aws-credential-source.sh
COPY bin/materialize-aws.sh /usr/local/bin/materialize-aws.sh
COPY bin/aws-sso-guard.sh /usr/local/bin/aws-sso
COPY bin/ready.sh /usr/local/bin/ready.sh
COPY bin/gh-wrapper.sh /usr/local/bin/gh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/agent-harness.sh \
      /usr/local/bin/configure-git-auth.sh \
      /usr/local/bin/mint-github-app-token.sh \
      /usr/local/bin/github-app-credential-helper.sh \
      /usr/local/bin/materialize-secrets.sh \
      /usr/local/bin/gh \
      /usr/local/bin/log-level-filter.sh \
      /usr/local/bin/aws-credential-source.sh \
      /usr/local/bin/materialize-aws.sh \
      /usr/local/bin/aws-sso \
      /usr/local/bin/ready.sh /entrypoint.sh && \
    chown agent:agent /entrypoint.sh

# asdf data dir on the workspaces volume path by default; plugins installable.
ENV ASDF_DATA_DIR=/home/agent/.asdf \
    PATH="/home/agent/.local/bin:/home/agent/.asdf/shims:/usr/local/bin:${PATH}" \
    MULTICA_AGENT_RUNTIME_NAME=multica-runtime \
    MULTICA_WORKSPACES_ROOT=/home/agent/workspaces

USER agent
WORKDIR /home/agent

# asdf Go binary: put shims on PATH; plugins install into ASDF_DATA_DIR at runtime.
RUN printf '%s\n' \
      '' \
      '# asdf' \
      'export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"' \
      'export PATH="$ASDF_DATA_DIR/shims:$PATH"' \
      >> /home/agent/.bashrc

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["bash"]
