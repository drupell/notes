# Installing Pi with Gondolin

Written 2026-08-11 from the checked-out sources of `pi` (v0.84.1) and `gondolin`. Upstream moves;
re-check against those repos if a command fails.

## What this gets you

`pi` runs on the **host**. Its built-in tools — `read`, `write`, `edit`, `bash`, `grep`, `find`,
`ls` — and your `!` commands execute inside a local Linux micro-VM. Your project directory is
mounted at `/workspace` in the guest and writes through to the host.

Provider auth stays on the host: API keys never enter the VM. That is the main reason to prefer
this over running all of `pi` inside a container.

## Requirements

| | |
|---|---|
| OS | macOS or Linux. **ARM64 is the best-tested path**; Linux x86_64 is CI smoke-tested |
| Node | **>= 23.6.0** (required by `@earendil-works/gondolin`) |
| Hypervisor | QEMU (default backend). `brew install qemu` / `sudo apt install qemu-system-arm` |
| Disk + network | ~200MB of guest assets (kernel, initramfs, rootfs) fetched from GitHub **on first use**, cached in `~/.cache/gondolin/images/` |

The optional `krun` backend is experimental and needs Zig + Rust toolchains (`make krun-runner` in
the gondolin repo). Skip it unless you have a reason.

---

# Install

## 1. Turn everything off, before the first run

**Order matters.** `enableInstallTelemetry` defaults to **true** and the install ping fires after
the first run of a newly installed version, so this has to happen *before* you start `pi` for the
first time. Run this whole block as-is:

```bash
#!/usr/bin/env bash
# Force pi's telemetry, analytics and startup network operations off, persistently.
# Safe to re-run: merges into existing settings, appends to the shell profile once.
set -euo pipefail

# ============================================================================
# WHAT THIS TURNS OFF — edit these two blocks, the rest is plumbing.
# ============================================================================

FORCE_SETTINGS='{
  "enableInstallTelemetry": false,
  "enableAnalytics": false
}'

FORCE_ENV='export PI_OFFLINE=1
export PI_TELEMETRY=0
export PI_SKIP_VERSION_CHECK=1'

# ============================================================================

AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
SETTINGS="$AGENT_DIR/settings.json"
MARKER="# pi: telemetry and startup network off"

mkdir -p "$AGENT_DIR"

# Merge FORCE_SETTINGS over any existing settings.json, keeping your other keys.
node -e '
const fs = require("node:fs");
const [file, overrides] = process.argv.slice(1);
const existed = fs.existsSync(file);
if (existed) fs.copyFileSync(file, file + ".bak");
const raw = existed ? fs.readFileSync(file, "utf8").trim() : "";
const current = raw ? JSON.parse(raw) : {};          // malformed JSON stops the script
const merged = { ...current, ...JSON.parse(overrides) };
fs.writeFileSync(file, JSON.stringify(merged, null, 2) + "\n");
console.log(`${existed ? "updated" : "created"} ${file}`);
' "$SETTINGS" "$FORCE_SETTINGS"

# Append FORCE_ENV to the shell profile, once.
case "${SHELL##*/}" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) RC="$HOME/.bashrc" ;;
  *)    RC="$HOME/.profile" ;;
esac

if grep -qF "$MARKER" "$RC" 2>/dev/null; then
  echo "already present in $RC"
else
  printf '\n%s\n%s\n' "$MARKER" "$FORCE_ENV" >> "$RC"
  echo "appended to $RC"
fi

echo
echo "Open a new shell, or: source $RC"
```

Everything it changes is in the two blocks at the top. Below that it only does three things:
create `~/.pi/agent/` if missing, merge those settings into `settings.json` (backing up the old
one as `settings.json.bak` and keeping every key you already had), and append those exports to
your shell profile once, guarded by the marker comment so a re-run is a no-op.

`node` is the only requirement, and you need it for pi anyway.

`PI_SKIP_VERSION_CHECK` is redundant while `PI_OFFLINE=1` is set — kept explicit so the intent
survives someone unsetting offline mode later.

### Doing it by hand instead

The environment variable wins over the settings file whenever it is defined at all
(`isInstallTelemetryEnabled`, `src/core/telemetry.ts`), so the settings file is the belt and the
exports are the braces — worth having both, since a GUI launcher or a cron job may not read your
shell profile.

```bash
mkdir -p ~/.pi/agent
cat > ~/.pi/agent/settings.json <<'JSON'
{
  "enableInstallTelemetry": false,
  "enableAnalytics": false
}
JSON
```

Note the env parser only accepts `1`/`true`/`yes` as "on"; anything else defined counts as off.

What each switch actually covers:

| Switch | Stops | Does **not** stop |
|---|---|---|
| `enableInstallTelemetry: false` / `PI_TELEMETRY=0` | the anonymous version ping to `https://pi.dev/api/report-install`, and provider attribution headers on OpenRouter / Cloudflare / direct NVIDIA NIM requests | the update check |
| `PI_SKIP_VERSION_CHECK=1` | the `https://pi.dev/api/latest-version` fetch | telemetry, catalog refresh, package checks |
| `PI_OFFLINE=1` | all of the startup network operations below | model traffic, tool traffic |

`enableAnalytics` is a separate setting and already defaults to `false`; it is only offered during
the experimental first-run setup (`PI_EXPERIMENTAL=1`).

## 2. Install pi

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

`--ignore-scripts` is upstream's own recommendation — pi needs no lifecycle scripts for a normal
npm install. The alternative installer is `curl -fsSL https://pi.dev/install.sh | sh`.

Authenticate:

```bash
export ANTHROPIC_API_KEY=sk-ant-...   # or
pi                                    # then /login and pick a provider
```

## 3. Install the Gondolin extension

The extension ships **inside the pi repo**, not the gondolin one:

```bash
cp -R packages/coding-agent/examples/extensions/gondolin ~/.pi/agent/extensions/gondolin
cd ~/.pi/agent/extensions/gondolin
npm install --ignore-scripts
```

That pulls `@earendil-works/gondolin` (pinned to `0.12.0` by the extension's `package.json`).

If you only have the gondolin checkout, its `host/examples/pi-gondolin.ts` is an older, thinner
variant — it overrides `read`/`write`/`edit`/`bash` only and wants `pnpm install` in the gondolin
repo first so imports resolve. Prefer pi's copy.

## 4. Run it

```bash
cd /path/to/project
pi
```

The VM starts eagerly on `session_start`, so a missing QEMU surfaces immediately rather than on
the first tool call. You should see a status line reporting the mount, and the model's system
prompt has its working directory rewritten to `/workspace`.

Sanity check inside a session: ask it to run `uname -a` and `ls /`. You should get an Alpine
guest, not your host.

## Is the extension used by default?

**Yes — the `cp -R` in step 3 is what turns it on, permanently and for every project.** No alias
needed, and `-e` is redundant.

`~/.pi/agent/extensions/` is an auto-discovered global location. The loader walks project-local
`.pi/extensions/`, then `~/.pi/agent/extensions/`, then anything named explicitly, deduplicating
by resolved path — so `pi -e ~/.pi/agent/extensions/gondolin` loads exactly the same thing as bare
`pi`. The `-e` form in upstream's own docs is just being explicit.

| Location | Scope |
|---|---|
| `~/.pi/agent/extensions/*.ts` | global, every project |
| `~/.pi/agent/extensions/*/index.ts` | global, every project (this is where the `cp -R` puts it) |
| `.pi/extensions/*.ts`, `.pi/extensions/*/index.ts` | project-local, **loaded only after the project is trusted** |
| `settings.json` → `"extensions": ["/abs/path"]` | explicit paths, any location |

Auto-discovered extensions also hot-reload with `/reload`; `-e` paths are meant for quick tests.

### If you'd rather it be opt-in

Always-on means *every* project runs its tools inside Alpine — a slower session start, and a guest
toolchain that may not have what a given project needs. To keep it deliberate, put the extension
somewhere that is not auto-discovered and name it when you want it:

```bash
mv ~/.pi/agent/extensions/gondolin ~/.pi/gondolin
alias pisafe='pi -e ~/.pi/gondolin'      # or just type the -e when you want it
```

Per-project instead: copy it to `<project>/.pi/extensions/gondolin` and trust the project once.
Note that project-local extensions load only after the trust decision, so the VM starts slightly
later in the boot sequence.

---

# Offline mode

## Making it the default

There is no `settings.json` key for offline mode — it is a flag or an environment variable only:

```bash
export PI_OFFLINE=1        # in your shell profile
```

Prefer the variable over `alias pi='pi --offline'`: an alias does not apply in scripts or
non-interactive shells, and anything that spawns `pi` on your behalf misses it. The two are
equivalent at startup — `pi` reads either, and when set it writes both `PI_OFFLINE=1` and
`PI_SKIP_VERSION_CHECK=1` back into the process environment, so child processes inherit them.

**Set it to exactly `1`, `true`, or `yes`.** Never `0` — see the parsing trap below.

## What offline mode prevents

All of these are **startup** operations:

| Operation | Endpoint |
|---|---|
| Model catalog refresh | pi.dev per-provider overlays, cached to `~/.pi/agent/models-store.json`. 15s abort timeout |
| Version check | `https://pi.dev/api/latest-version` |
| Install/update telemetry | `https://pi.dev/api/report-install?version=…` |
| Package update checks | npm registry / git remotes for pi packages |
| Managed tool downloads | `api.github.com/repos/sharkdp/fd` and `BurntSushi/ripgrep` releases, then the release asset from `github.com`. 10s network / 120s download timeout |

Offline mode also makes the catalog cache authoritative: pi keeps using whatever is already in
`models-store.json` rather than refreshing it, which is the intended behaviour for a machine that
cannot reach pi.dev.

**One thing to install yourself.** Offline mode blocks the `fd` and `ripgrep` downloads, and pi
prints `not found. Offline mode enabled, skipping download.` But `getToolPath` checks your `PATH`
before it considers downloading, so a system install is used if present:

```bash
brew install ripgrep fd          # or: apt install ripgrep fd-find
```

Worth doing before you flip offline mode on, or the `grep` and `find` tools come back empty.

## What it does not prevent

- **Model provider API calls.** The agent's actual traffic is untouched — offline mode is about
  startup chores, not inference.
- **Anything a tool does.** `bash`, `curl`, a `npm install` the model decides to run.
- **MCP servers and extensions**, which run with the pi process's permissions.
- **Gondolin's own first-use fetch.** The ~200MB of guest assets comes from a GitHub-hosted
  registry and pi's flag has no bearing on it. To avoid it, pre-populate the cache or point
  Gondolin at local assets:

  ```bash
  export GONDOLIN_GUEST_DIR=/path/to/assets        # use these instead of downloading
  export GONDOLIN_IMAGE_STORE=/path/to/image/store # default ~/.cache/gondolin/images
  export GONDOLIN_IMAGE_REGISTRY_URL=...           # default: raw.githubusercontent.com/earendil-works/gondolin
  ```

So `PI_OFFLINE=1` is a "do not phone home on boot" switch, not a network boundary. A real boundary
has to come from outside the process — which is the conclusion pi's own `docs/security.md`
reaches too.

## The parsing trap

Two different offline checks exist in the tree:

- **Strict** (`1`/`true`/`yes` only): `main.ts:113`, `package-manager.ts:43`,
  `tools-manager.ts:15`, `telemetry.ts:3`
- **Bare truthiness** (`if (process.env.PI_OFFLINE)`): `interactive-mode.ts:1015,1106,1202`,
  `version-check.ts:55`

`PI_OFFLINE=0` therefore lands in a mixed state: catalog refresh, version check and package-update
check are skipped because a non-empty string is truthy, while the package manager and managed-tool
downloads still reach the network because they parse the value properly. Every site individually
fails toward *less* network, so it is not dangerous — but "0" meaning "partially on" is a trap if
you ever template this into a config.

---

# Sandbox posture out of the box

The bundled extension calls `VM.create` with a filesystem mount and **no `httpHooks`**. Two
consequences, both in the source:

- The egress policy hooks (`isRequestAllowed`, `isIpAllowed`, `onRequest`, `onResponse`) are only
  consulted when hooks are configured — `host/src/qemu/http.ts` early-returns without them.
- `createHttpHooks` treats an omitted `allowedHosts` as `["*"]` (`host/src/http/hooks.ts:162`).

So the default is **process and filesystem isolation, no destination allowlist, no secret
injection**. The parts of Gondolin that make it interesting for egress control are opt-in. To get
them, build hooks and pass them to `VM.create` in the extension's `index.ts`:

```ts
import { createHttpHooks } from "@earendil-works/gondolin";

const { httpHooks, env } = createHttpHooks({
  allowedHosts: ["api.github.com", "*.crates.io"],
  secrets: {
    GITHUB_TOKEN: { hosts: ["api.github.com"], value: process.env.GITHUB_TOKEN! },
  },
  // blockInternalRanges defaults to true
});

const created = await VM.create({ httpHooks, env, vfs: { /* existing mounts */ } });
```

Secret injection gives the guest a **placeholder**; the host substitutes the real value into
headers only for allowlisted destinations. It relies on TLS interception — Gondolin generates a
local CA under `~/.cache/gondolin/ssl` and injects it into the guest — so anything doing
certificate pinning inside the VM will break.

# Limitations that will actually bite

From gondolin's `docs/limitations.md`:

- **No HTTP/2, HTTP/3, or QUIC.** Mediation is HTTP/1.x and TLS-over-TCP. UDP-based application
  protocols and WebRTC do not work in the default network model.
- **Alpine only**, and the default image is deliberately minimal. Extra compilers or language
  runtimes mean building a custom guest image (`docs/custom-images.md`).
- **No full VM save/restore.** Disk-only qcow2 checkpoints exist; in-VM process state and RAM are
  not captured. `/root`, `/tmp`, `/var/tmp`, `/var/cache`, `/var/log` are tmpfs-backed and are not
  part of a checkpoint.
- **Backend parity gaps** between `qemu` and `krun`; qemu-specific knobs are rejected under krun.

Explicit non-goals in gondolin's `docs/security.md`: a malicious host, a malicious local user on
the same account, VM escape through a QEMU bug, side channels, and denial of service. The host
Node process is trusted.

# Porting model providers from opencode

There is no importer in pi — I checked; `opencode` appears in its source only as the names of the
Zen and Go *gateways*, which pi supports natively (`OPENCODE_API_KEY`, provider ids `opencode` and
`opencode-go`). Everything else is a manual translation between two config shapes:

| opencode (`opencode.json`) | pi (`~/.pi/agent/models.json`) |
|---|---|
| `provider.<id>.options.baseURL` / `.endpoint` | `baseUrl` |
| `provider.<id>.npm` | `api` — `@ai-sdk/openai-compatible` → `openai-completions`, `@ai-sdk/anthropic` → `anthropic-messages`, `@ai-sdk/google` → `google-generative-ai` |
| `options.apiKey` | `apiKey` |
| `options.headers` | `headers` |
| `models.<id>` (`name`, `reasoning`, `limit.context`, `limit.output`) | `models[]` (`id`, `name`, `reasoning`, `contextWindow`, `maxTokens`) |
| `{env:VAR}` | `$VAR` |
| `{file:path}` | `!cat path` — **note the semantic change**: pi runs the command on every request, opencode read the file once at startup |
| `blacklist` / `whitelist` | no equivalent |
| `mcp` | **nothing.** pi has no MCP support by design |

`pi-import-opencode.mjs` in this directory does the mechanical part:

```bash
node pi-import-opencode.mjs ~/.config/opencode/opencode.json           # preview, writes nothing
node pi-import-opencode.mjs ~/.config/opencode/opencode.json --write   # merge into models.json
```

## Why you can trust that script

Read it before running it — it is ~230 lines and the whole translation lives in two tables at the
top. Concretely:

- **It previews by default.** Without `--write` it prints the proposed JSON and exits. With
  `--write` it backs the old file up to `models.json.bak` and merges, so providers it did not
  import survive.
- **It cannot reach the network, and you can prove it in one command:**
  `grep -nE "fetch|http|child_process|exec|spawn|import " pi-import-opencode.mjs` returns exactly
  two lines, `node:fs` and `node:path`. No dependencies, so there is no transitive code either.
- **It never copies or prints a secret.** `{env:VAR}` references move across as references.
  Literal keys are replaced with `$PI_<PROVIDER>_API_KEY` and reported **by variable name only**,
  with a pointer back to the field in your opencode file — so the output is safe to paste
  somewhere, and you move the actual value by hand.
- **It reports rather than drops.** Any provider option it does not understand, any unknown npm
  package, any out-of-scope section is listed under "NOT converted". A TLS or proxy setting you
  depend on surfaces there instead of vanishing.
- **It declines to guess.** Per-model `cost` is not translated, because the two formats' units
  were not verified — a wrong price is worse than a missing one.

## TLS and custom CAs

Neither tool has a config field for a custom CA bundle or client certificate; both are Node
processes, so it is Node's lever:

```bash
export NODE_EXTRA_CA_CERTS=/path/to/corp-ca.pem
```

That covers a corporate TLS-inspecting proxy in front of your model endpoint. Client-certificate
(mTLS) auth is not expressible in either config file — it needs a pi extension registering a
provider with its own fetch, per `docs/custom-provider.md`.

# Sources

| Claim | Where |
|---|---|
| Install steps, requirements, tool list | pi `packages/coding-agent/docs/containerization.md` |
| pi install, auth, telemetry and update checks | pi `packages/coding-agent/README.md`, `docs/settings.md`, `docs/environment-variables.md` |
| Offline behaviour and flag parsing | pi `src/main.ts`, `src/core/telemetry.ts`, `src/core/package-manager.ts`, `src/utils/tools-manager.ts`, `src/utils/version-check.ts`, `src/modes/interactive/interactive-mode.ts` |
| Extension source, pinned gondolin version | pi `packages/coding-agent/examples/extensions/gondolin/` |
| Network model, defaults, hooks | gondolin `docs/network.md`, `docs/sdk-network.md`, `host/src/http/hooks.ts` |
| Guest assets, cache paths, env vars | gondolin `docs/cli.md`, `docs/snapshots.md` |
| Limitations, security non-goals | gondolin `docs/limitations.md`, `docs/security.md` |
