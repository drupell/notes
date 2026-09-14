# syntax=docker/dockerfile:1

ARG UBUNTU_VERSION="26.04"
ARG UV_VERSION="0.9.26"
# Pinned release of dvdksn/clipboardbridge — the prebuilt clipboard-bridge
# binary copied into the base image below. Bump in lockstep with a CI build.
ARG CLIPBOARD_BRIDGE_VERSION="v0.1.0"

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

##############
# Base image #
##############
FROM ubuntu:${UBUNTU_VERSION} AS base

# Declare build platform args to ensure cache invalidation across platforms
ARG TARGETPLATFORM

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/home/agent/.local/bin:/usr/local/share/npm-global/bin:$PATH

# Configure NO_PROXY to include Docker bridge network for Testcontainers-like compatibility
# Testcontainers-like environments need to access container IPs (172.17.0.0/16) without going through proxy
ENV NO_PROXY=localhost,127.0.0.1,::1,172.17.0.0/16
ENV no_proxy=localhost,127.0.0.1,::1,172.17.0.0/16

WORKDIR /home/agent/workspace

# Install packages
RUN <<EOF
set -euxo pipefail
# Add Docker repos
apt-get update
apt-get install -yy --no-install-recommends \
    ca-certificates \
    curl \
    gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
EOF

# Configure users, sandbox config, and npm
RUN <<EOF
set -ex
# Remove base image user
userdel ubuntu || true

# Create non-root user
useradd --create-home --uid 1000 --shell /bin/bash agent
groupadd -f docker
usermod -aG sudo agent
usermod -aG docker agent

# Configure sudoers
mkdir /etc/sudoers.d
chmod 0755 /etc/sudoers.d
echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent
echo "Defaults:%sudo env_keep += \"http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY SSL_CERT_FILE NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE JAVA_TOOL_OPTIONS\"" > /etc/sudoers.d/proxyconfig

# Create sandbox config
mkdir -p /home/agent/.docker/sandbox/locks

# Pre-create .local directories with correct ownership to prevent OCI runtime
# from creating them as root when mounting volumes at deep paths like
# /home/agent/.local/share/opencode (see docker/dash#914).
mkdir -p /home/agent/.local/share /home/agent/.local/state

chown -R agent:agent /home/agent

# Set up npm global package folder under /usr/local/share
mkdir -p /usr/local/share/npm-global
chown -R agent:agent /usr/local/share/npm-global
EOF

# Create persistent environment shell script that will be sourced by all shell sessions
RUN touch /etc/sandbox-persistent.sh && \
    chmod 644 /etc/sandbox-persistent.sh && \
    chown agent:agent /etc/sandbox-persistent.sh

# Set BASH_ENV to auto-source persistent env for non-interactive shells
ENV BASH_ENV=/etc/sandbox-persistent.sh

# Configure login shells to source persistent environment
RUN <<EOF
set -ex
cat > /etc/profile.d/sandbox-persistent.sh << 'PROFILEEOF'
# Source the sandbox persistent environment file
if [ -f /etc/sandbox-persistent.sh ]; then
    . /etc/sandbox-persistent.sh
fi

# Export BASH_ENV so non-interactive child shells also source the persistent env
export BASH_ENV=/etc/sandbox-persistent.sh
PROFILEEOF
chmod 644 /etc/profile.d/sandbox-persistent.sh
EOF

# Configure bash to always source persistent environment
# IMPORTANT: Prepend to existing /etc/bash.bashrc to preserve Ubuntu defaults
RUN <<EOF
set -ex
# Create our prepend content
cat > /tmp/sandbox-bashrc-prepend << 'PREPEND'
# Docker Sandbox: Source persistent environment for interactive shells
if [ -f /etc/sandbox-persistent.sh ]; then
    . /etc/sandbox-persistent.sh
fi

# Export BASH_ENV so non-interactive child shells also source the persistent env
export BASH_ENV=/etc/sandbox-persistent.sh

PREPEND

# Prepend our content to existing bashrc
cat /tmp/sandbox-bashrc-prepend /etc/bash.bashrc > /tmp/new-bashrc
mv /tmp/new-bashrc /etc/bash.bashrc
chmod 644 /etc/bash.bashrc
rm /tmp/sandbox-bashrc-prepend
EOF

# Create user bashrc to source persistent environment for interactive shells
RUN <<EOF
set -ex
cat > /home/agent/.bashrc << 'BASHRCEOF'
# Source the sandbox persistent environment file
if [ -f /etc/sandbox-persistent.sh ]; then
    . /etc/sandbox-persistent.sh
fi

# Export BASH_ENV for child non-interactive shells
export BASH_ENV=/etc/sandbox-persistent.sh

# Enable colorized ls output by default
alias ls='ls --color=auto'
BASHRCEOF
chmod 644 /home/agent/.bashrc
chown agent:agent /home/agent/.bashrc
EOF

# Install uv from official GitHub releases
COPY --link --from=uv /uv /usr/local/bin/uv

# Clipboard bridge: a minimal Wayland wlr-data-control server that lets agents
# paste host images/screenshots (Ctrl+V) when they read the clipboard via a
# native library rather than wl-paste/xclip (e.g. Codex via arboard). Fetched
# as a prebuilt binary from the github.com/dvdksn/clipboardbridge release
# pinned by CLIPBOARD_BRIDGE_VERSION; SHA256SUMS verification is mandatory.
ARG TARGETARCH
ARG CLIPBOARD_BRIDGE_VERSION
RUN <<EOF
set -euxo pipefail
base="https://github.com/dvdksn/clipboardbridge/releases/download/${CLIPBOARD_BRIDGE_VERSION}"
asset="clipboard-bridge-linux-${TARGETARCH}"
tmp=$(mktemp -d)
curl -fsSL "${base}/${asset}"     -o "${tmp}/${asset}"
curl -fsSL "${base}/SHA256SUMS"   -o "${tmp}/SHA256SUMS"
(cd "${tmp}" && grep " ${asset}\$" SHA256SUMS | sha256sum -c -)
install -m 0755 "${tmp}/${asset}" /usr/local/bin/clipboard-bridge
rm -rf "${tmp}"
EOF

FROM base AS tools-minimal

################################
# Tools for the minimal images #
################################

USER root
RUN <<EOF
set -euxo pipefail
apt-get update
apt-get install -yy --no-install-recommends \
    bubblewrap \
    dnsutils \
    docker-buildx-plugin \
    docker-ce-cli \
    docker-compose-plugin \
    git \
    gh \
    jq \
    less \
    lsof \
    make \
    openssh-client \
    procps \
    psmisc \
    ripgrep \
    rsync \
    socat \
    sudo \
    tini \
    unzip

apt-get clean
rm -rf /var/lib/apt/lists/*

EOF
USER agent

# Use tini as PID 1 so processes launched via `docker exec` (e.g. `sbx exec`)
# get properly reaped instead of accumulating as zombies. Declared here so
# every downstream template inherits it without each stage repeating it. The
# container's CMD (`sleep infinity` set by sandboxlib, or the per-agent CMDs
# below when run standalone) is appended to this ENTRYPOINT by Docker.
ENTRYPOINT ["tini", "--"]

FROM tools-minimal AS tools

#############################
# Tools for the full images #
#############################

USER root
RUN <<EOF
set -euxo pipefail
apt-get update
apt-get install -yy --no-install-recommends \
    bc \
    default-jdk-headless \
    golang \
    man-db \
    nodejs \
    npm \
    python3 \
    python3-pip

apt-get clean
rm -rf /var/lib/apt/lists/*

EOF
USER agent

#########################################
# Base for Docker-in-Docker variants    #
# Installs docker-ce once so the 10     #
# -docker targets don't each run their  #
# own apt-get against the same mirror.  #
#########################################
FROM tools AS tools-docker
USER root
RUN <<EOF
set -euxo pipefail
apt-get update
apt-get install -yy --no-install-recommends \
    containerd.io \
    docker-ce

apt-get clean
rm -rf /var/lib/apt/lists/*
EOF
USER agent

##################
# Claude Minimal #
##################
FROM tools-minimal AS claude-code-minimal
RUN <<EOF
set -ex
# Install Claude Code
curl -fsSL https://claude.ai/install.sh | bash
EOF

# Configure Claude Code to source persistent env before every Bash command.
ENV CLAUDE_ENV_FILE=/etc/sandbox-persistent.sh

CMD [ "claude", "--dangerously-skip-permissions" ]

##########
# Claude #
##########
FROM tools AS claude-code
RUN <<EOF
set -ex
# Install Claude Code
curl -fsSL https://claude.ai/install.sh | bash
EOF

# Configure Claude Code to source persistent env before every Bash command.
ENV CLAUDE_ENV_FILE=/etc/sandbox-persistent.sh

CMD [ "claude", "--dangerously-skip-permissions" ]

##########
# Gemini #
##########
FROM tools AS gemini
# Install Gemini CLI
# Disable corepack's npm shim so /usr/bin/npm is available at runtime (see #863).
RUN corepack npm install -g @google/gemini-cli@latest \
    && (corepack disable npm 2>&1 || echo "corepack disable npm not needed")

CMD [ "gemini" ]

################
# Docker Agent #
################
FROM tools AS docker-agent
ARG TARGETARCH
# DOCKER_AGENT_VERSION is normally resolved by the caller (CI passes the
# latest tag via the bake variable) to avoid hitting api.github.com's
# unauthenticated rate limit from inside the build. If unset, fall back
# to resolving it here for local builds.
ARG DOCKER_AGENT_VERSION=""

RUN <<EOF
set -euxo pipefail
TAG="${DOCKER_AGENT_VERSION}"
if [ -z "${TAG}" ]; then
    TAG=$(
        curl -fsSL "https://api.github.com/repos/docker/docker-agent/releases/latest" |
        sed -nE 's/.*"tag_name": *"([^"]+)".*/\1/p'
    )
fi
if [ -z "${TAG}" ]; then
    echo "Failed to resolve docker-agent release tag from DOCKER_AGENT_VERSION or GitHub API response" >&2
    exit 1
fi

sudo curl -fsSL "https://github.com/docker/docker-agent/releases/download/${TAG}/docker-agent-linux-${TARGETARCH}" -o /usr/local/bin/docker-agent
sudo chmod +x /usr/local/bin/docker-agent
EOF

CMD [ "docker-agent" ]

################
# Cursor Agent #
################
FROM tools AS cursor-agent
RUN <<EOF
set -ex
# Install Cursor Agent (directions copied from https://cursor.com/cli)
curl -fsS https://cursor.com/install | bash
EOF

CMD [ "/home/agent/.local/bin/cursor-agent" ]

#########
# Devin #
#########
FROM tools AS devin
RUN <<EOF
set -eu
curl -fsSL https://cli.devin.ai/install.sh | bash || true
devin --version
ln -s "$(readlink /home/agent/.local/bin/devin)" /home/agent/.local/bin/devin-cli
rm /home/agent/.local/bin/devin
EOF
COPY --chown=agent:agent --chmod=0755 devin-entrypoint.sh /home/agent/.local/bin/devin

CMD [ "devin" ]

#########
# Codex #
#########
FROM tools AS codex

RUN mkdir -p /home/agent/.codex

# The codex package is large (370MB), so we increase timeout and add retries
# --include=optional ensures the platform-specific native binary (@openai/codex-linux-x64) is installed
# After install, disable corepack's npm shim so the apt-installed /usr/bin/npm
# is available at runtime — Codex's self-updater spawns `npm` directly and
# fails with ENOENT if only the corepack shim is present (see #863).
RUN corepack npm install -g @openai/codex@latest \
    --include=optional \
    --fetch-timeout=300000 \
    --fetch-retries=3 \
    --fetch-retry-mintimeout=60000 \
    && (corepack disable npm 2>&1 || echo "corepack disable npm not needed")

CMD [ "codex" ]

############
# OpenCode #
############
FROM tools AS opencode

# Install OpenCode CLI (directions copied from https://opencode.ai/)
# --include=optional ensures platform-specific native binaries (e.g. opencode-linux-x64) are installed
# opencode-ai publishes bin/opencode.exe as a stub that aborts at runtime until
# its postinstall replaces it with the platform binary, and `corepack npm` does
# not run lifecycle scripts — installing through the shim ships that stub and
# still exits 0. Disable the shim before installing (which is also what keeps
# /usr/bin/npm available at runtime, see #863) so postinstall runs, then assert
# the real binary is in place instead of trusting the install's exit code.
RUN (corepack disable npm 2>&1 || echo "corepack disable npm not needed") \
    && npm install -g opencode-ai \
    --include=optional \
    && opencode --version

CMD [ "opencode" ]

#########
# Shell #
#########
FROM tools AS shell

# Shell is a minimal sandbox without any pre-installed agent.
# Users can install any agent they want and the proxy will inject
# credentials for all supported providers.

# Configure a cleaner shell prompt: user@sandbox:dirname$
# Uses \W (directory basename) instead of \w (full path) for readability
# Ensure login shells also source .bashrc so the prompt applies with "bash -l".
RUN <<EOF
set -ex
echo 'PS1='"'"'\u@\h:\W\$ '"'" >> /home/agent/.bashrc
printf '\n# Source .bashrc for login shells\nif [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n' >> /home/agent/.bash_profile
chown agent:agent /home/agent/.bashrc /home/agent/.bash_profile
EOF

CMD [ "bash" ]

####################################################################
# Docker-in-Docker variants                                        #
#                                                                  #
# These stages add Docker Engine (daemon + containerd) on top of   #
# their parent agent image. The com.docker.sandboxes.start-docker label    #
# tells the sandbox runtime to configure privileged mode, a block  #
# volume at /var/lib/docker, and automatic dockerd startup.        #
#                                                                  #
# All variants inherit from tools-docker (which installs           #
# containerd.io + docker-ce once) rather than each running their   #
# own apt-get against the same mirror in parallel.                 #
####################################################################

FROM tools-docker AS claude-code-docker
RUN <<EOF
set -ex
# Install Claude Code
curl -fsSL https://claude.ai/install.sh | bash
# Pre-create the session-state directories that the claude kit's
# spec.yaml mounts as persistent volumes. Two distinct concerns at
# this layer:
#
#  1. Docker's overlay-mount trap — when a tmpfs/overlay volume mounts
#     on a *missing* path, Docker auto-creates the target as root,
#     leaving the agent user unable to write. mkdir here ensures the
#     mount-point shape exists in the image; the runtime spec.yaml
#     startup chown (concern 2 below) then re-owns the resulting
#     volume mount root to the agent user.
#
#  2. The block-volume mount trap — block volumes are formatted as
#     ext4 at create time; their root directory is owned by root
#     (mkfs's default), regardless of what the image had at the
#     mount point. Image-time chown is overwritten by the mount.
#     This is fixed at runtime by the claude agent kit's
#     commands.startup entry (sandboxlib/agentkits/agents/claude/
#     spec.yaml) which runs `chown -R agent:agent` as user:"0" on
#     every container start, including the swap container produced
#     by `sbx kit add`. Doing the chown here in a Dockerfile
#     entrypoint would not help — the image USER is `agent`, so any
#     entrypoint runs as agent and cannot chown a root-owned mount
#     root. (The claude template is consumed only via sandboxd's
#     kit-composition flow; there is no direct-image-run path that
#     would bypass the kit's startup commands.)
mkdir -p \
  /home/agent/.claude/projects \
  /home/agent/.claude/sessions \
  /home/agent/.claude/todos \
  /home/agent/.claude/shell-snapshots \
  /home/agent/.claude/statsig
EOF

ENV CLAUDE_ENV_FILE=/etc/sandbox-persistent.sh
LABEL com.docker.sandboxes.start-docker="true"
CMD [ "claude", "--dangerously-skip-permissions" ]

FROM tools-docker AS gemini-docker
# Disable corepack's npm shim so /usr/bin/npm is available at runtime (see #863).
RUN corepack npm install -g @google/gemini-cli@latest \
    && (corepack disable npm 2>&1 || echo "corepack disable npm not needed")
LABEL com.docker.sandboxes.start-docker="true"
CMD [ "gemini" ]

FROM tools-docker AS docker-agent-docker
ARG TARGETARCH
# DOCKER_AGENT_VERSION is normally resolved by the caller (CI passes the
# latest tag via the bake variable) to avoid hitting api.github.com's
# unauthenticated rate limit from inside the build. If unset, fall back
# to resolving it here for local builds.
ARG DOCKER_AGENT_VERSION=""
RUN <<EOF
set -euxo pipefail
TAG="${DOCKER_AGENT_VERSION}"
if [ -z "${TAG}" ]; then
    TAG=$(
        curl -fsSL "https://api.github.com/repos/docker/docker-agent/releases/latest" |
        sed -nE 's/.*"tag_name": *"([^"]+)".*/\1/p'
    )
fi
if [ -z "${TAG}" ]; then
    echo "Failed to resolve docker-agent release tag from DOCKER_AGENT_VERSION or GitHub API response" >&2
    exit 1
fi

sudo curl -fsSL "https://github.com/docker/docker-agent/releases/download/${TAG}/docker-agent-linux-${TARGETARCH}" -o /usr/local/bin/docker-agent
sudo chmod +x /usr/local/bin/docker-agent
EOF
LABEL com.docker.sandboxes.start-docker="true"
CMD [ "docker-agent" ]

FROM tools-docker AS cursor-agent-docker
RUN <<EOF
set -ex
# Install Cursor Agent (directions copied from https://cursor.com/cli)
curl -fsS https://cursor.com/install | bash
EOF
LABEL com.docker.sandboxes.start-docker="true"
CMD [ "/home/agent/.local/bin/cursor-agent" ]

FROM tools-docker AS devin-docker
RUN <<EOF
set -eu
curl -fsSL https://cli.devin.ai/install.sh | bash || true
devin --version
ln -s "$(readlink /home/agent/.local/bin/devin)" /home/agent/.local/bin/devin-cli
rm /home/agent/.local/bin/devin
EOF
COPY --chown=agent:agent --chmod=0755 devin-entrypoint.sh /home/agent/.local/bin/devin
LABEL com.docker.sandboxes.start-docker="true"
CMD [ "devin" ]

FROM tools-docker AS codex-docker
RUN mkdir -p /home/agent/.codex
# The codex package is large (370MB), so we increase timeout and add retries
# --include=optional ensures the platform-specific native binary (@openai/codex-linux-x64) is installed
# After install, disable corepack's npm shim so the apt-installed /usr/bin/npm
# is available at runtime — Codex's self-updater spawns `npm` directly and
# fails with ENOENT if only the corepack shim is present (see #863).
RUN corepack npm install -g @openai/codex@latest \
    --include=optional \
    --fetch-timeout=300000 \
    --fetch-retries=3 \
    --fetch-retry-mintimeout=60000 \
    && (corepack disable npm 2>&1 || echo "corepack disable npm not needed")
LABEL com.docker.sandboxes.start-docker="true"
CMD [ "codex" ]

FROM tools-docker AS opencode-docker
# Install OpenCode CLI (directions copied from https://opencode.ai/)
# --include=optional ensures platform-specific native binaries (e.g. opencode-linux-x64) are installed
# opencode-ai publishes bin/opencode.exe as a stub that aborts at runtime until
# its postinstall replaces it with the platform binary, and `corepack npm` does
# not run lifecycle scripts — installing through the shim ships that stub and
# still exits 0. Disable the shim before installing (which is also what keeps
# /usr/bin/npm available at runtime, see #863) so postinstall runs, then assert
# the real binary is in place instead of trusting the install's exit code.
RUN (corepack disable npm 2>&1 || echo "corepack disable npm not needed") \
    && npm install -g opencode-ai \
    --include=optional \
    && opencode --version
LABEL com.docker.sandboxes.start-docker="true"
CMD [ "opencode" ]

FROM tools-docker AS shell-docker
# Configure a cleaner shell prompt: user@sandbox:dirname$
# Uses \W (directory basename) instead of \w (full path) for readability
# Ensure login shells also source .bashrc so the prompt applies with "bash -l".
RUN <<EOF
set -ex
echo 'PS1='"'"'\u@\h:\W\$ '"'" >> /home/agent/.bashrc
printf '\n# Source .bashrc for login shells\nif [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n' >> /home/agent/.bash_profile
chown agent:agent /home/agent/.bashrc /home/agent/.bash_profile
EOF
LABEL com.docker.sandboxes.start-docker="true"
CMD [ "bash" ]
