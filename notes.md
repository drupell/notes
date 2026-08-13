# Installing Pi with Gondolin, offline

Written 2026-08-12 against `pi` v0.84.1 and `gondolin` 0.12.0. Upstream moves; re-check if a
command fails.

`pi` runs on the **host**. Its built-in tools — `read`, `write`, `edit`, `bash`, `grep`,
`find`, `ls` — and your `!` commands execute inside a local Linux micro-VM, with your project
mounted at `/workspace` and writes passing through to the host. Provider auth stays on the
host: **API keys never enter the VM**. That is the main reason to prefer this over running
all of `pi` in a container.

This document configures for **offline use only**. Every step below is required.

| | |
|---|---|
| OS | macOS or Linux. ARM64 best-tested; Linux x86_64 CI smoke-tested |
| Node | >= 23.6.0 (required by `@earendil-works/gondolin`) |
| Hypervisor | QEMU. `brew install qemu` / `sudo apt install qemu-system-arm` |
| First-run download | ~200MB of guest assets from GitHub, cached in `~/.cache/gondolin/images/` |

The `krun` backend is experimental and needs Zig + Rust. Skip it.

---

## 1. Kill the phone-home, before the first run

**Order matters.** `enableInstallTelemetry` defaults to `true` and the ping fires after the
first run of a newly installed version.

```bash
mkdir -p ~/.pi/agent
cat > ~/.pi/agent/settings.json <<'JSON'
{
  "enableInstallTelemetry": false,
  "enableAnalytics": false
}
JSON
```

**This overwrites `settings.json`.** If you already have one, add those two keys by hand
instead.

Then add to your shell profile — `~/.zshrc`, `~/.bashrc`, or `~/.bash_profile` for bash on macOS (Terminal
starts login shells, which do not read `~/.bashrc`):

```bash
export PI_OFFLINE=1
export PI_TELEMETRY=0
export PI_SKIP_VERSION_CHECK=1
```

Open a new shell. Both layers are worth having: the environment variable wins whenever it is
defined at all (`isInstallTelemetryEnabled`, `src/core/telemetry.ts`), but a GUI launcher or
cron job may not read your profile, so the settings file is the backstop.

Set the flags to exactly `1`, `true`, or `yes`. **Never `0`** — two different offline checks
exist in the tree, strict (`src/main.ts`, `package-manager.ts`, `tools-manager.ts`,
`telemetry.ts`) and bare truthiness (`interactive-mode.ts`, `version-check.ts`), so `0` lands
in a mixed state. Every site fails toward *less* network, so it is not dangerous — but it is a
trap if you template this into a config.

`PI_SKIP_VERSION_CHECK` is redundant while `PI_OFFLINE=1` is set. Keep it explicit so the
intent survives someone unsetting offline mode later.

## 2. Install the search tools first

Offline mode blocks pi's `fd`/`ripgrep` downloads, but `getToolPath` checks `PATH` first — so
a system install is used when present. Without this, the `grep` and `find` tools come back
empty.

```bash
brew install ripgrep fd          # or: apt install ripgrep fd-find
```

## 3. Install pi

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
export ANTHROPIC_API_KEY=sk-ant-...   # or run `pi` and use /login
```

`--ignore-scripts` is upstream's own recommendation — pi needs no lifecycle scripts.

## 4. Install the Gondolin extension

It ships **inside the pi repo**, not the gondolin one:

```bash
cp -R packages/coding-agent/examples/extensions/gondolin ~/.pi/agent/extensions/gondolin
cd ~/.pi/agent/extensions/gondolin
npm install --ignore-scripts
```

That `cp -R` is what turns it on — permanently, for every project, no alias and no `-e` flag.
`~/.pi/agent/extensions/` is auto-discovered.

To make it deliberate instead: `mv ~/.pi/agent/extensions/gondolin ~/.pi/gondolin` and run
`pi -e ~/.pi/gondolin` when you want it.

## 5. Close the guest's egress

**The bundled extension ships with no egress policy.** It calls `VM.create` with a filesystem
mount and no `httpHooks`, and `createHttpHooks` treats an omitted `allowedHosts` as `["*"]`
(`host/src/http/hooks.ts`). Out of the box you get process and filesystem isolation, **no
destination allowlist**.

Edit the extension's `index.ts`:

```ts
import { createHttpHooks } from "@earendil-works/gondolin";

const { httpHooks, env } = createHttpHooks({
  allowedHosts: [],            // [] denies everything; omitting the key allows everything
  // blockInternalRanges defaults to true
});

const created = await VM.create({ httpHooks, env, vfs: { /* existing mounts */ } });
```

An empty array is not the same as leaving the option out. Check this after every extension
update.

## 6. Get the guest assets on the machine

The guest is three files — a kernel, an initramfs, and a rootfs — totalling ~200MB. Gondolin
fetches them from a GitHub-hosted registry on first use. **`PI_OFFLINE` does not cover this**;
it is pi's flag and has no bearing on Gondolin.

**If this machine has network:** just run `pi` once (step 7). They download to
`~/.cache/gondolin/images/` and are reused forever after. Nothing to configure.

**If it does not:** copy them from a machine that does — same CPU architecture, since the
assets are per-arch. On the networked machine, run `pi` once, then find them:

```bash
ls ~/.cache/gondolin/images/objects/*/
# vmlinuz-virt  initramfs.cpio.lz4  rootfs.ext4  [manifest.json]
```

That object directory is the whole guest. Copy it to the offline machine at a **stable path
outside any cache**, then point Gondolin at it:

```bash
mkdir -p ~/gondolin-assets
# copy the contents of that objects/<id>/ directory into ~/gondolin-assets
export GONDOLIN_GUEST_DIR=~/gondolin-assets      # add to your shell profile
```

`GONDOLIN_GUEST_DIR` is a hard override, first in the lookup order (`host/src/assets.ts`) — set
it and the registry is never consulted. Gondolin checks for exactly those three filenames; a
`manifest.json` in the directory renames them, so copy it too if one is present.

Do not use `GONDOLIN_IMAGE_STORE` for this. It relocates the download cache, it does not avoid
downloading — on an air-gapped box it gives you an empty directory and a failed fetch.

Get it working online before pinning the variable. Pinning a path you have never booted from
means debugging the VM and the asset path at the same time.

## 7. Run

```bash
cd /path/to/project && pi
```

The VM starts eagerly on `session_start`, so a missing QEMU surfaces immediately rather than
on the first tool call. Sanity check inside a session: ask it to run `uname -a` and `ls /`.
You should get an Alpine guest, not your host.

---

## What offline mode does and does not cover

`PI_OFFLINE=1` is a "do not phone home on boot" switch, not a network boundary.

| Stopped (all at startup) | Endpoint |
|---|---|
| Model catalog refresh | pi.dev overlays → `~/.pi/agent/models-store.json` |
| Version check | `pi.dev/api/latest-version` |
| Install telemetry | `pi.dev/api/report-install` |
| Package update checks | npm registry / git remotes |
| Managed tool downloads | `api.github.com` (fd, ripgrep) then the release asset |

**Not stopped:** model provider API calls (the agent's actual traffic), anything a tool does
(`bash`, `curl`, an `npm install` the model runs), MCP servers and extensions — which run with
the pi process's permissions — and Gondolin's guest-asset fetch.

Offline mode also makes the catalog cache authoritative: pi keeps using whatever is already in
`models-store.json`.

**A real boundary has to come from outside the process** — a host firewall rule, or a network
namespace with no route. This is the conclusion pi's own `docs/security.md` reaches too.
Gondolin's explicit non-goals: a malicious host, a malicious local user on the same account, VM
escape through a QEMU bug, side channels, denial of service. The host Node process is trusted.

## Limitations that will actually bite

- **No HTTP/2, HTTP/3, or QUIC.** Mediation is HTTP/1.x and TLS-over-TCP. UDP-based protocols
  and WebRTC do not work.
- **Alpine only**, deliberately minimal. Extra compilers or language runtimes mean a custom
  guest image (`docs/custom-images.md`).
- **Anything on the host is invisible to the guest.** Only the project directory is mounted, so
  a globally installed CLI the model expects to call will not be there.
- **No full VM save/restore.** Disk-only qcow2 checkpoints; RAM and process state are not
  captured, and `/root`, `/tmp`, `/var/tmp`, `/var/cache`, `/var/log` are tmpfs-backed.

## Porting model providers from opencode

There is no importer in pi — `opencode` appears in its source only as the names of the Zen and
Go *gateways*, which pi supports natively (`OPENCODE_API_KEY`, provider ids `opencode` and
`opencode-go`). Everything else is a manual translation into `~/.pi/agent/models.json`:

| opencode (`opencode.json`) | pi (`models.json`) |
|---|---|
| `provider.<id>.options.baseURL` / `.endpoint` | `baseUrl` |
| `provider.<id>.npm` | `api` — `@ai-sdk/openai-compatible` → `openai-completions`, `@ai-sdk/anthropic` → `anthropic-messages`, `@ai-sdk/google` → `google-generative-ai` |
| `options.apiKey` / `options.headers` | `apiKey` / `headers` |
| `models.<id>` (`name`, `reasoning`, `limit.context`, `limit.output`) | `models[]` (`id`, `name`, `reasoning`, `contextWindow`, `maxTokens`) |
| `{env:VAR}` | `$VAR` |
| `{file:path}` | `!cat path` — **pi runs the command on every request**; opencode read the file once at startup |
| `blacklist` / `whitelist` | no equivalent |
| `mcp` | **nothing.** pi has no MCP support by design |

Per-model `cost` has no verified unit mapping between the two formats — set it by hand or leave
it out.

## TLS and custom CAs

Neither tool has a config field for a custom CA bundle or client certificate; both are Node
processes, so it is Node's lever:

```bash
export NODE_EXTRA_CA_CERTS=/path/to/corp-ca.pem
```

That covers a TLS-inspecting proxy in front of your model endpoint. Client-certificate (mTLS)
auth is not expressible in either config file — it needs a pi extension registering a provider
with its own fetch (`docs/custom-provider.md`).

Note this interacts with Gondolin: secret injection and the egress allowlist rely on TLS
interception, with a local CA generated under `~/.cache/gondolin/ssl` and injected into the
guest. Anything doing certificate pinning inside the VM will break.

## Sources

| Claim | Where |
|---|---|
| Install steps, requirements, tool list | pi `docs/containerization.md` |
| Telemetry, settings, update checks | pi `README.md`, `docs/settings.md`, `docs/environment-variables.md` |
| Offline behaviour and flag parsing | pi `src/main.ts`, `src/core/telemetry.ts`, `src/core/package-manager.ts`, `src/utils/tools-manager.ts`, `src/utils/version-check.ts`, `src/modes/interactive/interactive-mode.ts` |
| Extension source, pinned gondolin version | pi `examples/extensions/gondolin/` |
| Network model, hook defaults | gondolin `docs/network.md`, `docs/sdk-network.md`, `host/src/http/hooks.ts` |
| Guest assets, cache paths, env vars | gondolin `docs/cli.md`, `docs/snapshots.md` |
| Limitations, security non-goals | gondolin `docs/limitations.md`, `docs/security.md` |
