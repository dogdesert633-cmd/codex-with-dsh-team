// security.mjs
//
// Single, testable confidentiality policy for the public Codex x DSH team toolkit.
//
// Release Blocker A lives here: one place decides
//   * which names (keys, environment variables, file names) are secret-bearing,
//   * how secret-bearing text is rewritten to `<REDACTED>`,
//   * which parent environment variables may reach a DSH child process.
//
// The module is deliberately dependency free (node: builtins only) so the policy can be
// unit tested without installing the DSH runtime, and so every caller — bridge, monitor,
// launcher helpers — can reuse the exact same rules instead of re-inventing them.
//
// Hard rules encoded here:
//   1. A value behind a secret-bearing name is never emitted; it becomes `<REDACTED>`.
//   2. Text that merely *mentions* a secret-bearing word is not touched; only text that
//      actually carries a value after a separator is rewritten. This keeps authoritative
//      work packages readable while still removing real bearer/basic/key material.
//   3. A DSH child process receives a minimal, explicitly constructed environment. The
//      parent `*_TOKEN/*_KEY/*_PASSWORD/*_SECRET/*_COOKIE/AUTHORIZATION` families are
//      never inherited.

export const SECURITY_POLICY_VERSION = "security-policy/v1";

/** The single replacement token used by every redaction path. */
export const REDACTED = "<REDACTED>";

// ---------------------------------------------------------------------------
// 1. Name-level deny policy
// ---------------------------------------------------------------------------

// Words that are secret-bearing when they form a whole normalized name. Normalization
// lowercases and strips every non-alphanumeric character, so `X-DSH-Monitor-Token`,
// `x_dsh_monitor_token` and `accessToken` all collapse onto the same key.
const DENIED_NAME_EXACT = Object.freeze(new Set([
  "authorization",
  "proxyauthorization",
  "auth",
  "authtoken",
  "cookie",
  "cookies",
  "setcookie",
  "sessiontoken",
  "sessioncookie",
  "sessionkey",
  "accesstoken",
  "refreshtoken",
  "idtoken",
  "token",
  "tokens",
  "bearer",
  "apikey",
  "apikeys",
  "apikeyenv",
  "secret",
  "secrets",
  "clientsecret",
  "password",
  "passwd",
  "pwd",
  "passphrase",
  "credential",
  "credentials",
  "credentialstore",
  "privatekey",
  "privatekeys",
]));

// Suffixes/prefixes that are secret-bearing as part of a longer name, e.g.
// `X-DSH-Monitor-Token`, `DEEPSEEK_API_KEY`, `SESSION_COOKIE`, `githubPatSecret`.
const DENIED_NAME_SUFFIXES = Object.freeze([
  "token",
  "tokens",
  "apikey",
  "apikeys",
  "secret",
  "secrets",
  "password",
  "passwd",
  "passphrase",
  "credential",
  "credentials",
  "cookie",
  "cookies",
  "privatekey",
]);

const DENIED_NAME_PREFIXES = Object.freeze([
  "authorization",
  "credential",
  "credentials",
  "privatekey",
]);

// Numeric telemetry that merely *contains* a denied word. `maxTokens`, `promptTokens` and
// friends are model-catalog measurements, not credentials: redacting them would corrupt the
// model catalog the Monitor publishes. A measurement name is recognised by a qualifier
// (max/min/total/prompt/completion/input/output/cache/reasoning/used/usage/budget/limit/
// count/avg/remaining) next to the denied word; real credential names
// (`access_token`, `refresh_token`, `session_token`, `github_token`, `idToken`) carry none.
// Ordered longest-first so `cached` is stripped before `cache`, `average` before `avg`.
const TELEMETRY_QUALIFIERS = Object.freeze([
  "completion", "reasoning", "remaining", "average", "number", "cached", "count",
  "total", "prompt", "input", "output", "cache", "usage", "limit", "budget", "used",
  "max", "min", "avg", "per", "num",
]);
const TELEMETRY_DENIED_WORDS = Object.freeze(["token", "tokens", "key", "keys", "secret"]);

function isTelemetryName(normalized) {
  let remainder = normalized;
  let sawQualifier = false;
  for (const qualifier of TELEMETRY_QUALIFIERS) {
    if (!remainder.includes(qualifier)) continue;
    sawQualifier = true;
    remainder = remainder.split(qualifier).join("");
  }
  if (!sawQualifier) return false;
  return TELEMETRY_DENIED_WORDS.includes(remainder);
}

// Bare `key` / `keys` names. A long, whitespace-free string value under such a name is
// treated as a credential (many tools spell a raw key exactly `key`); a short value, an
// array of names or a numeric id is not.
const BARE_KEY_NAMES = Object.freeze(new Set(["key", "keys", "keyvalue", "keyvalues"]));
export const BARE_KEY_VALUE_MIN_LENGTH = 16;

/** True when a bare `key`/`keys` entry holds a value that must be treated as a credential. */
export function isBareKeyCredentialValue(value) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed.length < BARE_KEY_VALUE_MIN_LENGTH) return false;
    // A phrase (whitespace) or CJK text is prose, not a key.
    if (/\s/.test(trimmed)) return false;
    if (/[^\x20-\x7e]/.test(trimmed)) return false;
    return true;
  }
  if (Array.isArray(value)) return value.some((item) => isBareKeyCredentialValue(item));
  return false;
}

function normalizeName(name) {
  return String(name ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

/**
 * True when a property name / header name must never carry a value into a projection,
 * a child process environment or an evidence file.
 *
 * Deliberately *not* denied: `sessionId`, `session_id`, `contractText`, `dshHome`, and the
 * numeric telemetry names (`maxTokens`, `promptTokens`, …). Session identifiers, paths and
 * token *counts* are required evidence, and their names do not normalize onto a credential.
 */
export function isDeniedKey(name) {
  const normalized = normalizeName(name);
  if (!normalized) return false;
  if (isTelemetryName(normalized)) return false;
  if (DENIED_NAME_EXACT.has(normalized)) return true;
  if (DENIED_NAME_SUFFIXES.some((suffix) => normalized.endsWith(suffix))) return true;
  if (DENIED_NAME_PREFIXES.some((prefix) => normalized.startsWith(prefix))) return true;
  return false;
}

// Environment variables that must never be inherited by a DSH child process, even if a
// caller accidentally adds them to an allowlist. This is the published deny family from
// Release Blocker A plus the monitor's own local access token.
const ENV_DENY_PATTERN = /(^|_)(TOKEN|TOKENS|KEY|KEYS|APIKEY|API_KEY|SECRET|SECRETS|PASSWORD|PASSWD|PWD|PASSPHRASE|COOKIE|COOKIES|AUTHORIZATION|CREDENTIAL|CREDENTIALS|PRIVATE_KEY|SIGNATURE|SAS|DSN|CONNECTION_STRING)(_|$)/i;

const ENV_DENY_EXACT = Object.freeze(new Set([
  "DSH_MONITOR_TOKEN",
  "NODE_OPTIONS",
  "NODE_PATH",
  "PSMODULEPATH",
]));

/** True when an environment variable name is forbidden in a DSH child environment. */
export function isDeniedEnvName(name) {
  const upper = String(name ?? "").toUpperCase();
  if (!upper) return false;
  if (ENV_DENY_EXACT.has(upper)) return true;
  return ENV_DENY_PATTERN.test(upper);
}

// File names that are never copied, read into evidence or reported with content.
const DENIED_FILE_EXACT = Object.freeze(new Set([
  ".env",
  ".netrc",
  "_netrc",
  ".npmrc",
  ".pypirc",
  "credentials",
  "credentials.json",
  "credentials.yaml",
  "credentials.yml",
  ".credentials.yaml",
  ".credentials.yml",
  "id_rsa",
  "id_dsa",
  "id_ecdsa",
  "id_ed25519",
  "secrets.json",
  "secrets.yaml",
  "secrets.yml",
]));

const DENIED_FILE_EXTENSIONS = Object.freeze([
  ".pem",
  ".key",
  ".pfx",
  ".p12",
  ".jks",
  ".keystore",
  ".ppk",
]);

/**
 * True when a file name itself is a credential store or a private key material file.
 * Used as a copy/read deny rule, never as a reason to rewrite a path in evidence:
 * `changed: [".credentials.yaml"]` is useful, non-secret evidence.
 */
export function isDeniedFileName(name) {
  const base = String(name ?? "").split(/[\\/]/).pop()?.toLowerCase() ?? "";
  if (!base) return false;
  if (DENIED_FILE_EXACT.has(base)) return true;
  if (base.startsWith(".env.")) return true;
  if (DENIED_FILE_EXTENSIONS.some((extension) => base.endsWith(extension))) return true;
  return false;
}

// ---------------------------------------------------------------------------
// 2. Text-level redaction
// ---------------------------------------------------------------------------

// Values this process has explicitly refused to forward (for example the credential
// families stripped from the child environment). Registering them closes the last gap in
// the text rules: an arbitrary, unshaped secret pasted into free-form log text is not
// recognisable by pattern, but it *is* recognisable by value. A value the monitor refused
// to hand its child must never reappear in an artefact, log or projection either.
const KNOWN_SECRETS = new Set();
const KNOWN_SECRET_MIN_LENGTH = 8;
const KNOWN_SECRET_LIMIT = 256;

/** Register exact secret values for value-based redaction. Returns how many were added. */
export function registerKnownSecrets(values = []) {
  let added = 0;
  for (const value of values) {
    if (typeof value !== "string") continue;
    const candidate = value.trim();
    if (candidate.length < KNOWN_SECRET_MIN_LENGTH) continue;
    if (KNOWN_SECRETS.size >= KNOWN_SECRET_LIMIT) break;
    if (KNOWN_SECRETS.has(candidate)) continue;
    KNOWN_SECRETS.add(candidate);
    added += 1;
  }
  return added;
}

/** How many exact values are currently registered (never the values themselves). */
export function knownSecretCount() {
  return KNOWN_SECRETS.size;
}

export function resetKnownSecrets() {
  KNOWN_SECRETS.clear();
}

/** Register the values behind every denied environment variable name of `env`. */
export function registerDeniedEnvValues(env = {}) {
  const values = [];
  for (const [key, value] of Object.entries(env ?? {})) {
    if (isDeniedEnvName(key)) values.push(value);
  }
  return registerKnownSecrets(values);
}

function redactKnownValues(text) {
  if (KNOWN_SECRETS.size === 0) return text;
  let output = text;
  for (const secret of KNOWN_SECRETS) {
    if (output.includes(secret)) output = output.split(secret).join(REDACTED);
  }
  return output;
}

// Cheap pre-filter: when none of these substrings occur, no regex work is needed.
// This keeps per-event projection affordable on hot paths (SSE broadcast, run
// persistence) while every real secret-bearing string still goes through the rules.
const TEXT_TRIGGERS = Object.freeze([
  "token", "key", "secret", "password", "passwd", "pwd", "cookie",
  "credential", "authorization", "bearer", "basic ", "private",
  "pem", "sk-", "ghp_", "gho_", "ghs_", "ghr_", "github_pat_", "akia", "aiza", "xox",
]);

function mayContainSecret(text) {
  const lowered = text.toLowerCase();
  return TEXT_TRIGGERS.some((trigger) => lowered.includes(trigger));
}

// A credential-shaped value: no whitespace, printable ASCII, at least
// CREDENTIAL_VALUE_MIN_LENGTH characters. Prose stays intact because a sentence continues
// with spaces, punctuation or CJK text, none of which a credential value contains.
export const CREDENTIAL_VALUE_MIN_LENGTH = 8;
const CREDENTIAL_CHARS = `[A-Za-z0-9._~+/=@:!$%^&*#-]{${CREDENTIAL_VALUE_MIN_LENGTH},}`;
const CREDENTIAL_VALUE = `["']?${CREDENTIAL_CHARS}["']?`;

const PRIVATE_KEY_BLOCK = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----/g;
// Header rules only fire when the line *ends* in something credential-shaped. A sentence
// such as `Authorization: 不得以明文写入` is documentation and must survive untouched.
const AUTHORIZATION_HEADER = new RegExp(`^([ \\t]*(?:proxy-)?authorization[ \\t]*:[ \\t]*)(?:(?:bearer|basic|token|apikey|digest)[ \\t]+)?(${CREDENTIAL_VALUE})[ \\t]*$`, "gim");
const COOKIE_HEADER = new RegExp(`^([ \\t]*(?:set-)?cookie[ \\t]*:[ \\t]*)([A-Za-z0-9_.-]{1,64}=${CREDENTIAL_VALUE}(?:[ \\t]*;[ \\t]*[^\\r\\n]*)?)[ \\t]*$`, "gim");
const BEARER_BASIC = /\b(bearer|basic)[ \t]+[A-Za-z0-9._~+/=-]{8,}/gi;
// Pairs the quote character so JSON/YAML text stays parseable after redaction.
const KV_VALUE = new RegExp(
  `(^|[^A-Za-z0-9_.-])(["']?)([A-Za-z0-9_.-]*(?:api[_-]?key|apikey|token|secret|password|passwd|pwd|cookie|credential|private[_-]?key|passphrase)[A-Za-z0-9_.-]*)\\2([ \\t]*[:=][ \\t]*)(["']?)(${CREDENTIAL_CHARS})\\5`,
  "gi",
);
// `NAME=value` lines (.env / dotenv / exported shells). The name is judged by the same
// deny policy as an environment variable, so `MY_KEY=…`, `APP_TOKEN=…` and
// `SERVICE_PASSWORD=…` are removed while `model = <team-configured-fallback-model>` in a skill document is not,
// and a documentation line such as `token=见上文` survives because its value is prose.
const ENV_ASSIGNMENT = /^([ \t]*)([A-Za-z_][A-Za-z0-9_]*)([ \t]*=[ \t]*)(.*)$/gm;
const CREDENTIAL_ASSIGNMENT_VALUE = new RegExp(`^${CREDENTIAL_VALUE}$`);
const PROVIDER_KEY_SHAPE = /\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[abprs]-[A-Za-z0-9-]{10,})\b/g;

const TEXT_RULES = Object.freeze([
  { category: "private-key", pattern: PRIVATE_KEY_BLOCK, replace: () => REDACTED },
  { category: "authorization-header", pattern: AUTHORIZATION_HEADER, replace: (_match, prefix) => `${prefix}${REDACTED}` },
  { category: "cookie-header", pattern: COOKIE_HEADER, replace: (_match, prefix) => `${prefix}${REDACTED}` },
  { category: "bearer-basic", pattern: BEARER_BASIC, replace: (_match, scheme) => `${scheme} ${REDACTED}` },
  {
    category: "key-value",
    pattern: KV_VALUE,
    replace: (_match, lead, keyQuote, key, separator, valueQuote) => {
      // 数值 telemetry（maxTokens/promptTokens/…）不是凭据，redact 它会破坏模型目录文本。
      if (isTelemetryName(normalizeName(key))) return _match;
      return `${lead}${keyQuote}${key}${keyQuote}${separator}${valueQuote}${REDACTED}${valueQuote}`;
    },
  },
  {
    category: "env-assignment",
    pattern: ENV_ASSIGNMENT,
    replace: (match, indent, name, separator, value) => {
      if (value === "" || value === REDACTED) return match;
      const trimmed = value.trim();
      if (trimmed === "" || trimmed === REDACTED) return match;
      if (!isDeniedEnvName(name) && !isDeniedKey(name)) return match;
      // 只有凭据形状的值才替换：`token=见上文` 这类说明性赋值必须保持可读。
      if (!CREDENTIAL_ASSIGNMENT_VALUE.test(trimmed)) return match;
      return `${indent}${name}${separator}${REDACTED}`;
    },
  },
  { category: "provider-key-shape", pattern: PROVIDER_KEY_SHAPE, replace: () => REDACTED },
]);

/**
 * Rewrite secret-bearing *values* inside free text to `<REDACTED>`.
 *
 * Only value position is rewritten: `API key` or `token` mentioned as words survive, a
 * real `Authorization: Bearer …`, `.env` line, YAML/JSON entry or private key block does
 * not. Idempotent for already redacted text.
 */
export function redactText(value) {
  if (typeof value !== "string" || value === "") return value;
  let text = value;
  if (mayContainSecret(text)) {
    for (const rule of TEXT_RULES) {
      text = text.replace(rule.pattern, rule.replace);
    }
  }
  return redactKnownValues(text);
}

/**
 * Redact text that is about to leave the local machine or be handed to another agent
 * (DSH prompt dispatch). Returns the rewritten text plus a category/count summary so the
 * redaction itself is machine-visible evidence without containing the removed value.
 */
export function redactForDispatch(value) {
  const text = typeof value === "string" ? value : String(value ?? "");
  if (!mayContainSecret(text) && KNOWN_SECRETS.size === 0) return { text, categories: {}, changed: false };
  const categories = {};
  let output = text;
  if (mayContainSecret(text)) {
    for (const rule of TEXT_RULES) {
      let hits = 0;
      output = output.replace(rule.pattern, (...args) => {
        hits += 1;
        return rule.replace(...args);
      });
      if (hits > 0) categories[rule.category] = hits;
    }
  }
  const beforeKnownValues = output;
  output = redactKnownValues(output);
  if (output !== beforeKnownValues) {
    categories["known-secret-value"] = (categories["known-secret-value"] ?? 0) + 1;
  }
  return { text: output, categories, changed: output !== text };
}

// ---------------------------------------------------------------------------
// 3. Structural redaction
// ---------------------------------------------------------------------------

const MAX_REDACTION_DEPTH = 24;

function redactInPlace(value, state, depth) {
  if (depth > MAX_REDACTION_DEPTH) return REDACTED;
  if (typeof value === "string") return redactText(value);
  if (value === null || typeof value !== "object") return value;
  if (state.seen.has(value)) return "[circular]";
  state.seen.add(value);
  if (Array.isArray(value)) {
    const result = value.map((item) => redactInPlace(item, state, depth + 1));
    state.seen.delete(value);
    return result;
  }
  if (value instanceof Date) return value.toISOString();
  if (value instanceof Map) {
    const result = {};
    for (const [key, item] of value) {
      const bareKeyCredential = BARE_KEY_NAMES.has(normalizeName(key)) && isBareKeyCredentialValue(item);
      result[String(key)] = isDeniedKey(key) || bareKeyCredential ? REDACTED : redactInPlace(item, state, depth + 1);
    }
    state.seen.delete(value);
    return result;
  }
  const result = {};
  for (const [key, item] of Object.entries(value)) {
    if (isDeniedKey(key)) {
      result[key] = item === null || item === undefined ? null : REDACTED;
      continue;
    }
    if (BARE_KEY_NAMES.has(normalizeName(key))) {
      // A bare credential string is redacted whole; an array keeps its shape and count so
      // `keys: [publicId, secretId]` stays readable evidence with only the secret masked.
      if (typeof item === "string" && isBareKeyCredentialValue(item)) {
        result[key] = REDACTED;
        continue;
      }
      if (Array.isArray(item) && item.some((entry) => isBareKeyCredentialValue(entry))) {
        result[key] = item.map((entry) => (isBareKeyCredentialValue(entry)
          ? REDACTED
          : redactInPlace(entry, state, depth + 1)));
        continue;
      }
    }
    result[key] = redactInPlace(item, state, depth + 1);
  }
  state.seen.delete(value);
  return result;
}

/**
 * Deep project a value: a secret-bearing property always becomes `<REDACTED>`, and every
 * remaining string is passed through `redactText`. Cycles become `"[circular]"`.
 */
export function redactValue(value) {
  return redactInPlace(value, { seen: new WeakSet() }, 0);
}

/** JSON string for evidence files; nothing secret-bearing survives. */
export function redactJson(value, space) {
  return JSON.stringify(redactValue(value), null, space);
}

/**
 * Line-buffered redacting writer.
 *
 * Raw protocol frames and child stderr are chunked arbitrarily, so redaction has to
 * happen per complete line; a partial trailing line is held back. An unbounded tail (a
 * single enormous frame) is flushed redacted instead of being buffered forever.
 */
export function createRedactingLineWriter(sink, { maxTailChars = 256 * 1024 } = {}) {
  let pending = "";
  const flushCompleteLines = () => {
    let index = pending.indexOf("\n");
    while (index >= 0) {
      sink.write(redactText(pending.slice(0, index + 1)));
      pending = pending.slice(index + 1);
      index = pending.indexOf("\n");
    }
  };
  return {
    write(chunk) {
      if (chunk === undefined || chunk === null) return;
      pending += typeof chunk === "string" ? chunk : chunk.toString("utf8");
      flushCompleteLines();
      if (pending.length > maxTailChars) {
        sink.write(redactText(pending));
        pending = "";
      }
    },
    end() {
      if (pending) {
        sink.write(redactText(pending));
        pending = "";
      }
    },
  };
}

// ---------------------------------------------------------------------------
// 4. Child process environment policy
// ---------------------------------------------------------------------------

/**
 * Minimal non-sensitive environment for a spawned helper process. Everything absent from
 * this list is *not* inherited; credential families are refused even when a caller adds
 * them here (see `isDeniedEnvName`).
 */
export const CHILD_ENV_ALLOWLIST = Object.freeze([
  "PATH",
  "PATHEXT",
  "SYSTEMROOT",
  "SYSTEMDRIVE",
  "WINDIR",
  "COMSPEC",
  "TEMP",
  "TMP",
  "USERDOMAIN",
  "USERNAME",
  "USERPROFILE",
  "HOMEDRIVE",
  "HOMEPATH",
  "LOCALAPPDATA",
  "APPDATA",
  "PROGRAMDATA",
  "PROGRAMFILES",
  "PROGRAMFILES(X86)",
  "NUMBER_OF_PROCESSORS",
  "PROCESSOR_ARCHITECTURE",
  "OS",
  "LANG",
  "LC_ALL",
  "TZ",
]);

/**
 * The only DSH runtime fields deliberately added on top of the allowlist. They were
 * confirmed against the shipped launcher: `DSH_HOME` selects the Team runtime home and
 * `DSH_PERMISSION_MODE` selects the sandbox/approval preset. Neither carries a secret.
 */
export const DSH_RUNTIME_ENV_KEYS = Object.freeze([
  "DSH_HOME",
  "DSH_PERMISSION_MODE",
]);

/**
 * Build the exact environment handed to a spawned process.
 *
 * `source` is normally `process.env`, but only allow-listed, non-denied names survive.
 * `explicit` values are added afterwards and are refused (loudly) when their name is
 * secret-bearing, so a future caller cannot smuggle a token through this door.
 */
export function buildChildEnv({ source = {}, allow = CHILD_ENV_ALLOWLIST, explicit = {} } = {}) {
  const env = {};
  const sourceObject = source ?? {};
  for (const key of allow) {
    const value = sourceObject[key];
    if (value === undefined || value === null) continue;
    if (isDeniedEnvName(key)) continue;
    env[key] = String(value);
  }
  for (const [key, value] of Object.entries(explicit ?? {})) {
    if (value === undefined || value === null) continue;
    if (isDeniedEnvName(key)) {
      throw new Error(`拒绝把 secret-bearing 环境变量 ${key} 递给子进程（security policy ${SECURITY_POLICY_VERSION}）。`);
    }
    env[key] = String(value);
  }
  return env;
}

/** Carry only the confirmed DSH runtime fields from a parent environment. */
export function pickDshRuntimeEnv(source = {}) {
  const picked = {};
  for (const key of DSH_RUNTIME_ENV_KEYS) {
    const value = source?.[key];
    if (value !== undefined && value !== null) picked[key] = String(value);
  }
  return picked;
}

/**
 * Names-only audit of an environment decision. Values are never returned, so this can be
 * written into evidence or logged safely.
 */
export function auditChildEnv(source = {}, childEnv = {}) {
  const forwarded = Object.keys(childEnv).sort();
  const droppedSensitive = Object.keys(source ?? {})
    .filter((key) => !Object.hasOwn(childEnv, key) && isDeniedEnvName(key))
    .sort();
  return {
    policyVersion: SECURITY_POLICY_VERSION,
    forwardCount: forwarded.length,
    forwarded,
    droppedSensitiveCount: droppedSensitive.length,
    droppedSensitive,
  };
}

// ---------------------------------------------------------------------------
// 5. Secret-leak assertions (used by the direct tests)
// ---------------------------------------------------------------------------

/** Return every fake secret value that still occurs in the given artifact. */
export function findSecretLeaks(subject, secrets = []) {
  const texts = [];
  if (typeof subject === "string") texts.push(subject);
  else if (subject !== undefined && subject !== null) texts.push(JSON.stringify(subject));
  const haystack = texts.join("\n");
  return secrets.filter((secret) => {
    if (typeof secret !== "string" || secret.length === 0) return false;
    return haystack.includes(secret);
  });
}

/** Throw when any fake secret value survived into the given artifact. */
export function assertNoSecretLeak(subject, secrets = [], label = "artifact") {
  const leaks = findSecretLeaks(subject, secrets);
  if (leaks.length > 0) {
    throw new Error(`${label} 泄露了 ${leaks.length} 个 secret 值（security policy ${SECURITY_POLICY_VERSION}）。`);
  }
}
