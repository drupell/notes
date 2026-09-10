# Docker

The Docker `sbx` shell template provides docker within the microVM. It looks like:
```text
Host
│
└── SBX microVM
    │
    └── your Debian/Ubuntu/Alpine container (privileged inside VM)
        │
        ├── dockerd
        │   └── /var/lib/docker -> dedicated SBX volume
        │
        ├── containerd
        └── docker CLI
```

Meaning that these are necessary:
```text
# In Dockerfile for template
LABEL com.docker.sandboxes.start-docker=true

docker       CLI
dockerd      daemon
containerd   runtime
```
Docker's own kit publishing checks explicitly say that when this label is present, the image must actually contain dockerd, docker, and containerd; the label itself is a request for Docker-in-Docker.


The default shell template is supposed to be more minimal than the other templates but still roughly includes:
```text
Base setup
├── agent user, UID 1000
├── passwordless sudo
├── proxy env preservation
├── /home/agent/workspace
├── npm global prefix owned by agent
└── /home/agent/.local/bin on PATH

Sandbox integration
├── tini
├── /etc/sandbox-persistent.sh
├── BASH_ENV=/etc/sandbox-persistent.sh
├── NO_PROXY localhost + Docker bridge
├── clipboard bridge
├── SSH tooling
└── socat

Useful CLI tools
├── git
├── gh
├── curl
├── jq
├── ripgrep
├── rsync
├── less
├── lsof
├── procps
└── unzip

Language/dev environment
├── uv
├── Node/npm
├── Python
├── Go
├── Java
└── build tooling

Docker-enabled variant additionally
├── docker CLI
├── Docker Engine / dockerd
├── containerd
├── buildx
├── compose
└── start-docker=true label
```

and includes some special environment plumbing:
```bash
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global

ENV PATH="/home/agent/.local/bin:/usr/local/share/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ENV NO_PROXY="localhost,127.0.0.1,::1,172.17.0.0/16"
ENV no_proxy="localhost,127.0.0.1,::1,172.17.0.0/16"

# Probably also gives ownership over npm global prefix like so
RUN mkdir -p /usr/local/share/npm-global \
    && chown -R agent:agent /usr/local/share/npm-global
```

The template img is explorable locally with:
```bash
docker pull docker/sandbox-templates:shell-docker

# Dockerfile-like layer history
docker history --no-trunc \
  docker/sandbox-templates:shell-docker

# Labels, env vars, entrypoint, user, etc.
docker image inspect \
  docker/sandbox-templates:shell-docker | jq '.[0].Config'

# Actual Debian packages installed
docker run --rm \
  --entrypoint bash \
  docker/sandbox-templates:shell-docker \
  -lc 'dpkg-query -W -f="\${Package}\t\${Version}\n" | sort'

# If docker scout is installed
docker scout sbom \
  docker/sandbox-templates:shell-docker \
  --format list
```
