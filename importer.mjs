#!/usr/bin/env node
//
// pi-import-opencode.mjs — convert an opencode.json provider block into pi's models.json.
//
// WHAT IT DOES ................ reads one JSON file, prints the pi equivalent
// WHAT IT WRITES .............. nothing, unless you pass --write
// NETWORK ..................... none. There is no fetch/http/child_process import in this file.
// SECRETS ..................... never copied into the output, never printed. Inline keys are
//                               replaced by an environment-variable reference and reported by
//                               NAME only, so this script's output is safe to paste in a ticket.
// DEPENDENCIES ................ none. Node standard library, two modules, both listed below.
//
// Usage:
//   node pi-import-opencode.mjs ~/.config/opencode/opencode.json            # preview (default)
//   node pi-import-opencode.mjs ~/.config/opencode/opencode.json --write    # merge into models.json
//   node pi-import-opencode.mjs <file> --out ./models.json --write          # write somewhere else
//
// Scope: provider endpoints, API selection, headers, auth references, and model entries.
// Everything else in an opencode config (mcp, agents, commands, keybinds, themes, permissions)
// is out of scope and is REPORTED, not silently dropped.

import fs from "node:fs";
import path from "node:path";

// ===========================================================================
// THE MAPPING — the whole translation lives in these two tables.
// ===========================================================================

// opencode picks an implementation by npm package; pi picks one by API name.
const NPM_TO_PI_API = {
  "@ai-sdk/openai-compatible": "openai-completions",
  "@ai-sdk/openai": "openai-completions",
  "@ai-sdk/anthropic": "anthropic-messages",
  "@ai-sdk/google": "google-generative-ai",
  "@ai-sdk/google-generative-ai": "google-generative-ai",
};

// Provider ids that pi already ships. For these, an endpoint override is all we emit —
// pi knows the API and the models already.
const PI_BUILTIN_PROVIDERS = new Set([
  "anthropic",
  "openai",
  "google",
  "deepseek",
  "nvidia",
  "opencode",
  "opencode-go",
  "together",
  "xai",
  "groq",
  "mistral",
  "openrouter",
]);

// ===========================================================================
// Secret handling. Read this part twice; it is the part that matters.
// ===========================================================================
//
// opencode supports {env:VAR} and {file:path} substitution plus plain literals.
//   {env:VAR}    -> pi "$VAR"            (a reference moves; no secret is read)
//   {file:path}  -> pi "!cat <path>"     (pi runs this per request, opencode read it once)
//   literal      -> depends on the field, see below.
//
// A literal value that we treat as secret is NEVER written into the output and NEVER printed.
// You copy it across by hand, which means this script cannot leak it into a terminal transcript,
// a shell history, or a file you forgot was world-readable.

// Step 1: opencode's template syntax -> pi's. Literals come back unchanged.
function convertTemplate(value, providerId, field, report) {
  if (typeof value !== "string") return { value, isLiteral: false };

  const env = value.match(/^\{env:([A-Za-z_][A-Za-z0-9_]*)\}$/);
  if (env) return { value: `$${env[1]}`, isLiteral: false };

  const file = value.match(/^\{file:(.+)\}$/);
  if (file) {
    report.notes.push(
      `${providerId}.${field}: {file:} became "!cat ${file[1]}". pi runs that command on every ` +
        `request (opencode read the file once at startup).`,
    );
    return { value: `!cat ${file[1]}`, isLiteral: false };
  }

  return { value, isLiteral: true };
}

// Step 2: replace a literal with an environment reference, reporting the NAME only.
function toEnvReference(providerId, field, report, suffix = "API_KEY") {
  const sanitize = (s) => s.toUpperCase().replace(/[^A-Z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  const varName = `PI_${sanitize(providerId)}_${sanitize(suffix)}`;
  report.secrets.push({ providerId, field, varName });
  return `$${varName}`;
}

// A header value that looks like a credential. Deliberately conservative: when in doubt we keep
// the literal and say nothing, because rewriting a functional header into a broken env reference
// is worse than leaving a non-secret in place. Anything matched here is reported, so a false
// positive is visible rather than silent.
function looksLikeCredential(value) {
  if (typeof value !== "string") return false;
  return (
    /^(Bearer|Basic|Token)\s+\S+/i.test(value) ||
    /\b(sk|pk|api|key|secret|token|pat)[-_][A-Za-z0-9_-]{12,}/i.test(value) ||
    /^[A-Za-z0-9_-]{32,}$/.test(value)
  );
}

// ===========================================================================
// Conversion
// ===========================================================================

function convertModel(modelId, model, report, providerId) {
  const out = { id: model.id ?? modelId };
  if (model.name) out.name = model.name;
  if (typeof model.reasoning === "boolean") out.reasoning = model.reasoning;
  if (model.limit?.context) out.contextWindow = model.limit.context;
  if (model.limit?.output) out.maxTokens = model.limit.output;

  const inputs = [];
  if (model.modalities?.input?.includes("text") ?? true) inputs.push("text");
  if (model.modalities?.input?.includes("image")) inputs.push("image");
  if (inputs.length > 1) out.input = inputs;

  // Deliberately NOT converted: cost. opencode and pi both express per-token pricing but this
  // script has not verified that the units match, and a wrong price is worse than none.
  if (model.cost) {
    report.notes.push(
      `${providerId}.models.${modelId}: cost was dropped — units unverified between the two ` +
        `formats. Add it by hand if you want spend display.`,
    );
  }
  return out;
}

function convertProvider(providerId, provider, report) {
  const options = provider.options ?? {};
  const out = {};

  const baseUrl = options.baseURL ?? options.endpoint;
  if (baseUrl) out.baseUrl = baseUrl;

  const npm = provider.npm;
  if (npm) {
    const api = NPM_TO_PI_API[npm];
    if (api) out.api = api;
    else report.unmapped.push(`${providerId}.npm = "${npm}" — no pi API equivalent known.`);
  }

  // An apiKey literal is always treated as a secret — that field has no innocent literal use.
  if (options.apiKey !== undefined) {
    const { value, isLiteral } = convertTemplate(options.apiKey, providerId, "options.apiKey", report);
    out.apiKey = isLiteral ? toEnvReference(providerId, "options.apiKey", report) : value;
  }

  // A header literal is usually innocuous ("true", a tenant name), so it passes through unless it
  // looks like a credential.
  if (options.headers && typeof options.headers === "object") {
    out.headers = {};
    for (const [name, raw] of Object.entries(options.headers)) {
      const field = `options.headers.${name}`;
      const { value, isLiteral } = convertTemplate(raw, providerId, field, report);
      out.headers[name] =
        isLiteral && looksLikeCredential(value)
          ? toEnvReference(providerId, field, report, name)
          : value;
    }
  }

  if (provider.models && typeof provider.models === "object") {
    const models = Object.entries(provider.models).map(([id, model]) =>
      convertModel(id, model ?? {}, report, providerId),
    );
    if (models.length) out.models = models;
  }

  // Report every option we did not translate rather than dropping it quietly. A TLS or proxy
  // setting you rely on shows up here instead of vanishing.
  const HANDLED = new Set(["baseURL", "endpoint", "apiKey", "headers"]);
  for (const key of Object.keys(options)) {
    if (!HANDLED.has(key)) {
      report.unmapped.push(`${providerId}.options.${key} — not translated, review by hand.`);
    }
  }
  for (const key of ["blacklist", "whitelist", "env", "api", "id"]) {
    if (provider[key] !== undefined) {
      report.unmapped.push(`${providerId}.${key} — no pi models.json equivalent.`);
    }
  }

  if (!out.baseUrl && !PI_BUILTIN_PROVIDERS.has(providerId) && out.models) {
    report.unmapped.push(
      `${providerId}: has models but no baseURL, and pi has no built-in provider by that id. ` +
        `pi needs baseUrl + api for a custom provider; this entry will not load as written.`,
    );
  }

  return out;
}

// ===========================================================================
// Main — argument parsing, then read one file, then print. Writes only with --write.
// ===========================================================================

const args = process.argv.slice(2);
const write = args.includes("--write");
const outIndex = args.indexOf("--out");
const explicitOut = outIndex !== -1 ? args[outIndex + 1] : undefined;
const inputPath = args.find((a) => !a.startsWith("--") && a !== explicitOut);

if (!inputPath) {
  console.error("usage: node pi-import-opencode.mjs <opencode.json> [--out <models.json>] [--write]");
  process.exit(2);
}

const agentDir = process.env.PI_AGENT_DIR ?? path.join(process.env.HOME ?? "", ".pi", "agent");
const outPath = explicitOut ?? path.join(agentDir, "models.json");

const source = JSON.parse(fs.readFileSync(inputPath, "utf8"));
const report = { unmapped: [], notes: [], secrets: [] };

if (!source.provider || typeof source.provider !== "object") {
  console.error(`no "provider" block in ${inputPath} — nothing to convert.`);
  process.exit(1);
}

const providers = {};
for (const [id, provider] of Object.entries(source.provider)) {
  const converted = convertProvider(id, provider ?? {}, report);
  if (Object.keys(converted).length) providers[id] = converted;
}

// Sections this script does not handle at all.
for (const key of ["mcp", "agent", "command", "keybinds", "theme", "permission", "plugin"]) {
  if (source[key] !== undefined) {
    report.unmapped.push(`top-level "${key}" — out of scope for this converter.`);
  }
}

const result = { providers };

console.log("─── proposed pi models.json ".padEnd(78, "─"));
console.log(JSON.stringify(result, null, 2));
console.log("─".repeat(78));

if (report.secrets.length) {
  console.log("\nInline secrets found. They were NOT copied. Export these yourself:\n");
  for (const s of report.secrets) {
    console.log(`  export ${s.varName}=...   # value is in ${inputPath} -> ${s.providerId}.${s.field}`);
  }
}
if (report.notes.length) {
  console.log("\nNotes:");
  for (const note of report.notes) console.log(`  - ${note}`);
}
if (report.unmapped.length) {
  console.log("\nNOT converted (review by hand):");
  for (const item of report.unmapped) console.log(`  - ${item}`);
}

if (!write) {
  console.log(`\nPreview only. Nothing was written. Re-run with --write to merge into ${outPath}`);
  process.exit(0);
}

// --write: merge into the existing models.json, keeping providers this import did not touch.
let current = {};
if (fs.existsSync(outPath)) {
  const raw = fs.readFileSync(outPath, "utf8").trim();
  current = raw ? JSON.parse(raw) : {};
  fs.copyFileSync(outPath, `${outPath}.bak`);
  console.log(`\nbackup: ${outPath}.bak`);
}
const merged = { ...current, providers: { ...(current.providers ?? {}), ...providers } };
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, `${JSON.stringify(merged, null, 2)}\n`);
console.log(`wrote ${outPath}`);
