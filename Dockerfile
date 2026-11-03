# Multica runtime home-base — thin baseline image.
#
# Ships: OS essentials, Multica CLI, cursor-agent, asdf (+ plugin install),
# tini, non-root agent user. No consumer repo trees. No multi-CLI agent set.
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

# ── System deps (language-agnostic) ──────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
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

# ── Forge HTTPS helper + entrypoint + ready probe ────────────────────────
COPY bin/configure-git-auth.sh /usr/local/bin/configure-git-auth.sh
COPY bin/ready.sh /usr/local/bin/ready.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/configure-git-auth.sh /usr/local/bin/ready.sh /entrypoint.sh && \
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
