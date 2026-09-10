FROM alpine:3.24

# Packages we explicitly want in the sandbox.
#
# bash: shell we want the agent user to use
# sudo: required by the Docker sandbox image contract
# ca-certificates: HTTPS/TLS
# nodejs + npm: Node/npm from the Alpine 3.24 repositories
RUN apk add --no-cache \
    bash \
    sudo \
    ca-certificates \
    nodejs \
    npm

# Install uv without adding curl/Python/Rust just to install it.
# Astral specifically recommends copying the binaries from their
# distroless image when building containers.
COPY --from=ghcr.io/astral-sh/uv:0.12.12 /uv /uvx /usr/local/bin/

# Docker Sandbox image contract:
#   user: agent
#   UID: 1000
#   home: /home/agent
#   passwordless sudo
RUN adduser \
      -D \
      -u 1000 \
      -h /home/agent \
      -s /bin/bash \
      agent \
    && mkdir -p /home/agent/workspace /etc/sudoers.d \
    && chown -R agent:agent /home/agent \
    && printf 'agent ALL=(ALL) NOPASSWD: ALL\n' \
         > /etc/sudoers.d/agent \
    && printf '%s\n' \
         'Defaults env_keep += "HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy"' \
         > /etc/sudoers.d/sandbox-proxy \
    && chmod 0440 \
         /etc/sudoers.d/agent \
         /etc/sudoers.d/sandbox-proxy

ENV SHELL=/bin/bash

USER agent
WORKDIR /home/agent/workspace

CMD ["/bin/bash"]
