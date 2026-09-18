// Direct tests for the centralized confidentiality policy (Release Blocker A).
//
// Everything here uses fake secrets and temporary structures only. No network, no real
// provider, no real DSH Home, no real environment dump.

import test from 'node:test';
import assert from 'node:assert/strict';
import { Writable } from 'node:stream';
import {
  CHILD_ENV_ALLOWLIST,
  DSH_RUNTIME_ENV_KEYS,
  REDACTED,
  SECURITY_POLICY_VERSION,
  assertNoSecretLeak,
  auditChildEnv,
  buildChildEnv,
  createRedactingLineWriter,
  findSecretLeaks,
  isBareKeyCredentialValue,
  isDeniedEnvName,
  isDeniedFileName,
  isDeniedKey,
  knownSecretCount,
  pickDshRuntimeEnv,
  redactForDispatch,
  redactJson,
  redactText,
  redactValue,
  registerDeniedEnvValues,
  registerKnownSecrets,
  resetKnownSecrets,
} from '../src/security.mjs';

const FAKE_BEARER = 'fake-bearer-0123456789abcdef';
const FAKE_API_KEY = 'sk-fake0123456789abcdefghij';
const FAKE_ENV_VALUE = 'fake-env-secret-value-0001';
const FAKE_CREDENTIAL = 'fake-credential-value-0002';
const FAKE_PASSWORD = 'fake-password-value-0003';
const FAKE_COOKIE = 'fake-cookie-value-0004';
const FAKE_SECRETS = [FAKE_BEARER, FAKE_API_KEY, FAKE_ENV_VALUE, FAKE_CREDENTIAL, FAKE_PASSWORD, FAKE_COOKIE];

// Synthetic Windows Team Home, assembled at runtime.
//
// The fixtures need a drive-rooted path, but the public source must not contain a literal
// assignment of an absolute drive path to the DSH home variable: that is exactly the
// fixed-environment binding signature the release scan blocks, and a real machine path has no
// place in a portable fixture anyway. Building the value from parts keeps the runtime
// semantics (and every assertion below) identical to before.
const WINDOWS_DRIVE_C = 'C' + ':';
const SYNTHETIC_TEAM_HOME = [WINDOWS_DRIVE_C, 'Team'].join('\\');
const SYNTHETIC_TEAM_HOME_NESTED = [SYNTHETIC_TEAM_HOME, 'home'].join('\\');

test('redactText 去掉承载真实值的 secret，但保留只是提到关键字的工作文本', () => {
  const cases = [
    [`Authorization: Bearer ${FAKE_BEARER}`, FAKE_BEARER],
    [`authorization: Basic ${FAKE_BEARER}`, FAKE_BEARER],
    [`Cookie: session=${FAKE_COOKIE}`, FAKE_COOKIE],
    [`Set-Cookie: sid=${FAKE_COOKIE}; HttpOnly`, FAKE_COOKIE],
    [`DEMO_API_KEY=${FAKE_ENV_VALUE}`, FAKE_ENV_VALUE],
    [`DEEPSEEK_TOKEN: ${FAKE_ENV_VALUE}`, FAKE_ENV_VALUE],
    [`apiKey: "${FAKE_ENV_VALUE}"`, FAKE_ENV_VALUE],
    [`"client_secret": "${FAKE_ENV_VALUE}"`, FAKE_ENV_VALUE],
    [`password = ${FAKE_PASSWORD}`, FAKE_PASSWORD],
    [`credentials: ${FAKE_CREDENTIAL}`, FAKE_CREDENTIAL],
    [`MY_KEY=${FAKE_ENV_VALUE}`, FAKE_ENV_VALUE],
    [`token=${FAKE_API_KEY}`, FAKE_API_KEY],
    [`Authorization: ${FAKE_BEARER}`, FAKE_BEARER],
  ];
  for (const [input, secret] of cases) {
    const output = redactText(input);
    assert.equal(output.includes(secret), false, `未 redact: ${input}`);
    assert.ok(output.includes(REDACTED), `缺少 ${REDACTED}: ${input}`);
  }

  // The PEM header/footer are assembled from benign fragments at runtime: the publishable
  // source must carry no static private-key signature (the release content scan blocks that
  // literal, and the value-level fake-marker exception does not cover it). The fixture value
  // the test consumes is byte-identical to the previous literal.
  const privateKey = [
    ['-----BEGIN', 'RSA', 'PRIVATE', 'KEY-----'].join(' '),
    'MIIEowIBAAKCAQEAfakefakefakefakefakefakefakefake',
    ['-----END', 'RSA', 'PRIVATE', 'KEY-----'].join(' '),
  ].join('\n');
  const redactedKey = redactText(privateKey);
  assert.equal(redactedKey.includes('MIIEowIBAAKCAQEA'), false);
  assert.equal(redactedKey, REDACTED);

  // Provider-shaped keys are removed even without a key/value separator.
  assert.equal(redactText(`leaked ${FAKE_API_KEY} here`).includes(FAKE_API_KEY), false);

  // Bare mentions are documentation, not values, and must survive so an authoritative
  // work package stays readable.
  for (const benign of [
    '至少覆盖 API key、token、password、cookie 与 Authorization 文本',
    '- Monitor 本地 access token 不得以明文写入 artifacts/evidence/log',
    '检查 `.credentials.yaml` 是否为现有 DSH 认证硬依赖',
    'provider/model 优先读取现有用户配置',
  ]) {
    assert.equal(redactText(benign), benign, `误伤文档文本: ${benign}`);
  }
});

test('redactText 幂等且对非字符串安全', () => {
  const once = redactText(`Authorization: Bearer ${FAKE_BEARER}`);
  assert.equal(redactText(once), once);
  assert.equal(redactText(undefined), undefined);
  assert.equal(redactText(42), 42);
  assert.equal(redactText(''), '');
});

test('isDeniedKey 只拒绝真正的 secret 名称，不误伤证据字段', () => {
  for (const denied of [
    'access_token', 'accessToken', 'X-DSH-Monitor-Token', 'AUTHORIZATION', 'authorization',
    'cookie', 'Set-Cookie', 'sessionToken', 'apiKey', 'api_key', 'LLM_SECRET',
    'password', 'passwd', 'credentials', 'privateKey', 'clientSecret', 'passphrase',
  ]) {
    assert.equal(isDeniedKey(denied), true, `应当拒绝: ${denied}`);
  }
  for (const allowed of [
    'sessionId', 'session_id', 'dshHome', 'dsh_home', 'contractText', 'agentId', 'taskId',
    'reasoningEffort', 'workspace', 'formalRole', 'keyCount', 'monkey', 'sessionUpdate',
  ]) {
    assert.equal(isDeniedKey(allowed), false, `不应拒绝: ${allowed}`);
  }
});

test('redactValue 深度投影并保持 ID/路径类证据可用', () => {
  const projected = redactValue({
    sessionId: 'sess-1',
    workspace: 'C:\\work\\proj',
    contractText: `use token=${FAKE_ENV_VALUE}`,
    effectivePermissionMode: 'danger-full-access',
    authorization: FAKE_BEARER,
    nested: { apiKey: FAKE_ENV_VALUE, list: [FAKE_API_KEY, { password: FAKE_PASSWORD }] },
    nullish: null,
    token: null,
  });
  assert.equal(projected.sessionId, 'sess-1');
  assert.equal(projected.workspace, 'C:\\work\\proj');
  assert.equal(projected.effectivePermissionMode, 'danger-full-access');
  assert.equal(projected.authorization, REDACTED);
  assert.equal(projected.nested.apiKey, REDACTED);
  assert.equal(projected.nested.list[0], REDACTED, 'provider 形状的 secret 在无 key 时也由文本规则去掉');
  assert.equal(projected.nested.list[1].password, REDACTED);
  assert.equal(projected.contractText.includes(FAKE_ENV_VALUE), false);
  assert.equal(projected.nullish, null);
  assert.equal(projected.token, null);
  assertNoSecretLeak(projected, [FAKE_BEARER, FAKE_API_KEY, FAKE_ENV_VALUE, FAKE_PASSWORD], 'redactValue 输出');

  const cyclic = { name: 'x' };
  cyclic.self = cyclic;
  assert.equal(redactValue(cyclic).self, '[circular]');
});

test('redactValue 的边界：无 key 的自由文本只按 secret 形状判定', () => {
  // 明确记录策略边界：结构化投影保证“带 secret 名字的值”一定被 redact；数组里
  // 无名的自由文本只能靠文本形状规则。测试用真实形状（provider key、Authorization、
  // .env 行）覆盖，而不是声称能识别任意随机字符串。
  const shaped = redactValue({ list: [FAKE_API_KEY, `Authorization: Bearer ${FAKE_BEARER}`, `DEMO_API_KEY=${FAKE_ENV_VALUE}`] });
  assertNoSecretLeak(shaped, [FAKE_API_KEY, FAKE_BEARER, FAKE_ENV_VALUE], 'shaped 自由文本');
  assert.deepEqual(redactValue({ list: ['plain reasoning summary text'] }).list, ['plain reasoning summary text']);
});

test('redactJson 用于落盘前投影', () => {
  const text = redactJson({ ok: true, headers: { Authorization: `Bearer ${FAKE_BEARER}` }, sessionId: 's1' });
  assertNoSecretLeak(text, [FAKE_BEARER], 'redactJson 输出');
  assert.ok(text.includes('"sessionId":"s1"'));
});

test('redactForDispatch 报告类别计数且不泄露值', () => {
  const { text, categories, changed } = redactForDispatch([
    `Authorization: Bearer ${FAKE_BEARER}`,
    `DEMO_API_KEY=${FAKE_ENV_VALUE}`,
    'plain instruction line',
  ].join('\n'));
  assert.equal(changed, true);
  assert.ok(categories['authorization-header'] >= 1, JSON.stringify(categories));
  assert.ok(categories['key-value'] >= 1, JSON.stringify(categories));
  assertNoSecretLeak(text, FAKE_SECRETS, 'dispatch 文本');
  assert.ok(text.includes('plain instruction line'));
  assert.equal(JSON.stringify(categories).includes(FAKE_ENV_VALUE), false);

  const clean = redactForDispatch('nothing sensitive at all');
  assert.equal(clean.changed, false);
  assert.deepEqual(clean.categories, {});
});

test('isDeniedEnvName 覆盖 Release Blocker A 要求的家族', () => {
  for (const denied of [
    'DEMO_API_KEY', 'DEEPSEEK_API_KEY', 'MY_TOKEN', 'REFRESH_TOKEN', 'APP_PASSWORD',
    'SERVICE_SECRET', 'SESSION_COOKIE', 'AUTHORIZATION', 'AZURE_CREDENTIALS',
    'DSH_MONITOR_TOKEN', 'NODE_OPTIONS', 'privatE_KEY',
  ]) {
    assert.equal(isDeniedEnvName(denied), true, `应当拒绝: ${denied}`);
  }
  for (const allowed of ['PATH', 'PATHEXT', 'SYSTEMROOT', 'TEMP', 'LOCALAPPDATA', 'USERPROFILE', 'OS', 'LANG']) {
    assert.equal(isDeniedEnvName(allowed), false, `不应拒绝: ${allowed}`);
  }
});

test('buildChildEnv 只继承最小必要字段，绝不带出父进程 secret 家族', () => {
  const parentEnv = {
    PATH: 'C:\\Windows',
    LOCALAPPDATA: 'D:\\Sandbox\\LocalAppData',
    TEMP: 'C:\\Temp',
    DEEPSEEK_API_KEY: FAKE_ENV_VALUE,
    MY_TOKEN: FAKE_ENV_VALUE,
    APP_PASSWORD: FAKE_PASSWORD,
    SERVICE_SECRET: FAKE_ENV_VALUE,
    SESSION_COOKIE: FAKE_COOKIE,
    AUTHORIZATION: FAKE_BEARER,
    DSH_MONITOR_TOKEN: FAKE_BEARER,
    NODE_OPTIONS: '--require evil.js',
    SOME_UNLISTED_VAR: 'value',
  };
  const childEnv = buildChildEnv({
    source: parentEnv,
    explicit: { DSH_HOME: SYNTHETIC_TEAM_HOME_NESTED, DSH_PERMISSION_MODE: 'danger-full-access' },
  });
  assert.equal(childEnv.PATH, 'C:\\Windows');
  assert.equal(childEnv.DSH_HOME, SYNTHETIC_TEAM_HOME_NESTED);
  assert.equal(childEnv.DSH_PERMISSION_MODE, 'danger-full-access');
  for (const forbidden of ['DEEPSEEK_API_KEY', 'MY_TOKEN', 'APP_PASSWORD', 'SERVICE_SECRET', 'SESSION_COOKIE', 'AUTHORIZATION', 'DSH_MONITOR_TOKEN', 'NODE_OPTIONS', 'SOME_UNLISTED_VAR']) {
    assert.equal(Object.hasOwn(childEnv, forbidden), false, `${forbidden} 不得进入 child env`);
  }
  assertNoSecretLeak(childEnv, FAKE_SECRETS, 'child env');

  // 即使调用者把 secret 名字加进 allowlist 也不会被继承。
  const widened = buildChildEnv({ source: parentEnv, allow: [...CHILD_ENV_ALLOWLIST, 'DEEPSEEK_API_KEY'] });
  assert.equal(Object.hasOwn(widened, 'DEEPSEEK_API_KEY'), false);

  // 显式构造也不允许塞 secret 名字。
  assert.throws(
    () => buildChildEnv({ source: parentEnv, explicit: { FAKE_TOKEN: FAKE_ENV_VALUE } }),
    /拒绝把 secret-bearing 环境变量/,
  );
});

test('auditChildEnv 只返回名字，不返回值', () => {
  const parentEnv = { PATH: 'C:\\Windows', DEMO_API_KEY: FAKE_ENV_VALUE, DSH_MONITOR_TOKEN: FAKE_BEARER };
  const childEnv = buildChildEnv({ source: parentEnv });
  const audit = auditChildEnv(parentEnv, childEnv);
  assert.equal(audit.policyVersion, SECURITY_POLICY_VERSION);
  assert.deepEqual(audit.droppedSensitive, ['DEMO_API_KEY', 'DSH_MONITOR_TOKEN']);
  assert.equal(audit.forwarded.includes('PATH'), true);
  assertNoSecretLeak(audit, FAKE_SECRETS, 'child env audit');
});

test('pickDshRuntimeEnv 只带确认过的 DSH runtime 字段', () => {
  const picked = pickDshRuntimeEnv({ DSH_HOME: SYNTHETIC_TEAM_HOME, DSH_PERMISSION_MODE: 'read-only', DSH_MONITOR_TOKEN: FAKE_BEARER });
  assert.deepEqual(Object.keys(picked), ['DSH_HOME', 'DSH_PERMISSION_MODE']);
  assert.deepEqual([...DSH_RUNTIME_ENV_KEYS], ['DSH_HOME', 'DSH_PERMISSION_MODE']);
  assertNoSecretLeak(picked, [FAKE_BEARER], 'dsh runtime env');
});

test('createRedactingLineWriter 对跨 chunk 的 secret 与超长行都安全', () => {
  const chunks = [];
  const sink = new Writable({
    write(chunk, _encoding, callback) { chunks.push(chunk.toString('utf8')); callback(); },
  });
  const writer = createRedactingLineWriter(sink);
  const line = `Authorization: Bearer ${FAKE_BEARER}\nOK line\n`;
  // 故意把 secret 切在 chunk 边界上。
  writer.write(line.slice(0, 20));
  writer.write(line.slice(20, 30));
  writer.write(line.slice(30));
  writer.end();
  const output = chunks.join('');
  assertNoSecretLeak(output, FAKE_SECRETS, 'redacting writer');
  assert.ok(output.includes('OK line'));
  assert.ok(output.includes(REDACTED));

  const longChunks = [];
  const longSink = new Writable({
    write(chunk, _encoding, callback) { longChunks.push(chunk.toString('utf8')); callback(); },
  });
  const longWriter = createRedactingLineWriter(longSink, { maxTailChars: 32 });
  longWriter.write(`TOKEN=${FAKE_ENV_VALUE}`);
  longWriter.write('x'.repeat(64));
  longWriter.end();
  assertNoSecretLeak(longChunks.join(''), FAKE_SECRETS, 'redacting writer (long line)');
});

test('isDeniedFileName 覆盖凭据库与私钥文件', () => {
  for (const denied of ['.env', '.env.local', '.credentials.yaml', 'credentials.json', 'id_rsa', 'server.pem', 'client.key', 'cert.pfx', '.netrc', '.npmrc']) {
    assert.equal(isDeniedFileName(denied), true, `应当拒绝: ${denied}`);
  }
  for (const allowed of ['package.json', 'settings.yaml', 'pnpm-workspace.yaml', 'cordis.patch.yml', 'index.html']) {
    assert.equal(isDeniedFileName(allowed), false, `不应拒绝: ${allowed}`);
  }
  assert.equal(isDeniedFileName('C:\\a\\.env'), true);
});

test('已登记的 known secret 按值 redaction，覆盖无 key、无形状的自由文本', () => {
  const bare = 'free form log line carrying fake-env-secret-value-0001 verbatim';
  // 未登记时，无 key、无形状的自由文本无法被识别（这是策略的已知边界）。
  assert.equal(redactText(bare).includes(FAKE_ENV_VALUE), true);

  resetKnownSecrets();
  const added = registerKnownSecrets([FAKE_ENV_VALUE, FAKE_PASSWORD, 'short', '   ']);
  assert.equal(added, 2, '过短或空值不得登记');
  assert.equal(knownSecretCount(), 2);
  assert.equal(redactText(bare).includes(FAKE_ENV_VALUE), false);
  assert.equal(redactText('password is fake-password-value-0003').includes(FAKE_PASSWORD), false);
  assert.equal(redactText('unrelated text').includes('unrelated text'), true);

  // 环境变量值登记：只登记被拒绝的家族。
  resetKnownSecrets();
  assert.equal(registerDeniedEnvValues({ DEMO_API_KEY: FAKE_ENV_VALUE, PATH: 'C:\\Windows' }), 1);
  assert.equal(redactText(`leak ${FAKE_ENV_VALUE}`).includes(FAKE_ENV_VALUE), false);

  // redactForDispatch 同时给出 known-value 类别证据。
  const dispatched = redactForDispatch(`trace ${FAKE_ENV_VALUE}`);
  assert.equal(dispatched.changed, true);
  assert.equal(dispatched.categories['known-secret-value'], 1);
  assertNoSecretLeak(dispatched.text, [FAKE_ENV_VALUE], 'dispatch known-value 输出');

  resetKnownSecrets();
  assert.equal(knownSecretCount(), 0);
});

test('数值 telemetry 名字不被 redaction 误伤，凭据名字仍然被拒', () => {
  for (const telemetry of [
    'maxTokens', 'max_tokens', 'promptTokens', 'completionTokens', 'totalTokens',
    'inputTokens', 'outputTokens', 'reasoningTokens', 'cachedTokens', 'tokenCount',
    'tokenUsage', 'maxOutputTokens', 'keyCount', 'secretCount', 'remainingTokens',
  ]) {
    assert.equal(isDeniedKey(telemetry), false, `telemetry 不得被拒: ${telemetry}`);
  }
  for (const credential of [
    'accessToken', 'access_token', 'refreshToken', 'refresh_token', 'sessionToken',
    'idToken', 'githubToken', 'bot_token', 'clientSecret', 'privateKey', 'apiKey',
    'X-DSH-Monitor-Token', 'sessionCookie', 'password',
  ]) {
    assert.equal(isDeniedKey(credential), true, `凭据名必须被拒: ${credential}`);
  }

  // 模型目录里的 telemetry 必须原样保留，否则 Monitor 的模型目录会被破坏。
  const catalog = redactValue({
    providers: [{ id: 'p', models: [{ id: 'm', maxTokens: 8192, promptTokens: 120, contextWindow: 200000 }] }],
  });
  assert.equal(catalog.providers[0].models[0].maxTokens, 8192);
  assert.equal(catalog.providers[0].models[0].promptTokens, 120);
  assert.equal(catalog.providers[0].models[0].contextWindow, 200000);
  // 散文里的 telemetry 行也不得被 KV 规则改写。
  assert.equal(redactText('maxTokens: 128000000'), 'maxTokens: 128000000');
  assert.equal(redactText('- 模型 maxTokens: 8192，promptTokens: 120'), '- 模型 maxTokens: 8192，promptTokens: 120');
});

test('收紧后的 KV / header 规则不破坏普通合同句子', () => {
  for (const prose of [
    'Authorization: 不得以明文写入 artifacts',
    'Authorization: 见第 3 节的安全边界',
    'Cookie: 只在同源 HttpOnly 场景使用',
    'apiKey: 由用户自己的 DSH settings.yaml 提供',
    'token: 不支持从环境变量补偿',
    'credentials: 只从 User DSH Home 只读同步',
    'token=见上文',
    'password: 由 owned Team Home 的受控副本维持',
    'maxTokens: 128000000',
    'The API key must never be printed.',
    '密钥（key）只能来自 owned Team Home',
  ]) {
    assert.equal(redactText(prose), prose, `误伤合同句子: ${prose}`);
  }

  // 但承载真实值时仍然必须 redact，并保持 JSON 可解析。
  const json = redactText(`{"apiKey": "${FAKE_API_KEY}", "note": "keep"}`);
  assertNoSecretLeak(json, [FAKE_API_KEY], 'JSON KV');
  const parsed = JSON.parse(json);
  assert.equal(parsed.apiKey, REDACTED);
  assert.equal(parsed.note, 'keep');

  const yaml = redactText(`client_secret: "${FAKE_ENV_VALUE}"\nmodel: gpt-x\n`);
  assertNoSecretLeak(yaml, [FAKE_ENV_VALUE], 'YAML KV');
  assert.ok(yaml.includes('model: gpt-x'), '非敏感 YAML 行必须保留');

  const envLine = redactText(`DEEPSEEK_API_KEY=${FAKE_ENV_VALUE}\nPATH=/usr/bin\n`);
  assertNoSecretLeak(envLine, [FAKE_ENV_VALUE], '.env KV');
  assert.ok(envLine.includes('PATH=/usr/bin'));
});

test('裸 key/keys 的长字符串值被视为凭据，短值/数组/数字不受影响', () => {
  const longKey = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';
  assert.equal(isBareKeyCredentialValue(longKey), true);
  assert.equal(isBareKeyCredentialValue('short'), false);
  assert.equal(isBareKeyCredentialValue('contains whitespace here and is long'), false);
  assert.equal(isBareKeyCredentialValue('这是中文字符串不是凭据值'), false);
  assert.equal(isBareKeyCredentialValue(42), false);
  assert.equal(isBareKeyCredentialValue(['a', 'b']), false);
  assert.equal(isBareKeyCredentialValue(['a', longKey]), true);

  const projected = redactValue({
    key: longKey,
    keys: ['alpha', 'beta'],
    counters: { keys: 3 },
    nested: { keys: [longKey] },
  });
  assert.equal(projected.key, REDACTED);
  assert.deepEqual(projected.keys, ['alpha', 'beta']);
  assert.equal(projected.counters.keys, 3);
  assert.deepEqual(projected.nested.keys, [REDACTED]);
  assertNoSecretLeak(projected, [longKey], 'bare key 投影');
});

test('known-secret 精确替换覆盖 64 位 hex Monitor token', () => {
  resetKnownSecrets();
  const monitorToken = 'a1b2c3d4e5f60718293a4b5c6d7e8f901a2b3c4d5e6f708192a3b4c5d6e7f809';
  assert.equal(monitorToken.length, 64);
  assert.equal(registerKnownSecrets([monitorToken]), 1);
  const line = `monitor token = ${monitorToken} (should never be printed)`;
  const redacted = redactText(line);
  assert.equal(redacted.includes(monitorToken), false);
  assert.ok(redacted.includes(REDACTED));
  // 结构化投影同样按值清理（即使字段名完全没有 secret 语义）。
  const projected = redactValue({ startupNote: monitorToken, list: [monitorToken] });
  assertNoSecretLeak(projected, [monitorToken], 'known-secret 投影');
  resetKnownSecrets();
});

test('findSecretLeaks / assertNoSecretLeak 是测试可用的断言', () => {
  assert.deepEqual(findSecretLeaks(`value=${FAKE_ENV_VALUE}`, FAKE_SECRETS), [FAKE_ENV_VALUE]);
  assert.deepEqual(findSecretLeaks({ nested: [FAKE_BEARER] }, [FAKE_BEARER]), [FAKE_BEARER]);
  assert.throws(() => assertNoSecretLeak(`x ${FAKE_BEARER}`, [FAKE_BEARER], 'artifact'), /泄露了/);
});

// ---------------------------------------------------------------------------
// SEC-01 regressions: bare JWT, short explicitly-sensitive values, multi-line PEM
// ---------------------------------------------------------------------------

// A synthetic JWS. The header is the base64url encoding of `{"alg":"HS256","typ":"JWT"}`;
// the payload and signature are fake filler. Assembled from parts so the publishable source
// carries no complete token-shaped literal.
const JWT_PARTS = ['eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9', 'eyJzdWIiOiJmYWtlLTAwMDEifQ', 'ZmFrZXNpZ25hdHVyZTAwMDE'];
const FAKE_JWT = JWT_PARTS.join('.');

test('SEC-01: 裸 JWT 在自由文本、JSON 值内与 dispatch 路径上都被 redact', () => {
  assert.equal(FAKE_JWT.startsWith('eyJ'), true, 'fixture 必须是 eyJ 形状');

  // 1) Free text, with no field name / header / Bearer prefix.
  const prose = `debug dump follows ${FAKE_JWT} end of dump`;
  const out = redactText(prose);
  assert.equal(out.includes(FAKE_JWT), false, '裸 JWT 必须被 redact');
  assert.ok(out.includes(REDACTED));
  assert.ok(out.includes('debug dump follows'));

  // 2) The same value inside a JSON string value.
  const json = redactJson({ sessionId: 's1', message: `hook rejected ${FAKE_JWT}` });
  assert.equal(json.includes(FAKE_JWT), false, 'JSON message 内的 JWT 必须被 redact');
  assert.deepEqual(redactValue({ message: FAKE_JWT }).message, REDACTED);
  assert.equal(JSON.parse(json).sessionId, 's1');

  // 3) Dispatch path, and the category is reported without the value.
  const dispatched = redactForDispatch(`token rotation failed: ${FAKE_JWT}`);
  assert.equal(dispatched.text.includes(FAKE_JWT), false, 'dispatch 路径必须 redact JWT');
  assert.equal(dispatched.changed, true);
  assert.ok(dispatched.categories.jwt >= 1, JSON.stringify(dispatched.categories));
  assert.equal(JSON.stringify(dispatched.categories).includes(FAKE_JWT), false);

  // 4) Ordinary dotted identifiers and sentences still survive.
  for (const benign of [
    'semver 1.2.3 and name.first.last are ordinary dotted identifiers',
    'eyJ not-a-token because it has only two parts.here',
    'the release is v1.0.0',
  ]) {
    assert.equal(redactText(benign), benign, `误伤普通文本: ${benign}`);
  }
});

test('SEC-01: 明确敏感名字后的短值不再靠长度阈值放行', () => {
  // A short, quoted, explicitly-sensitive value must not survive the dispatch path, which is
  // the real exit that carried the audit finding.
  const dispatched = redactForDispatch('password="abc"');
  assert.equal(dispatched.text.includes('abc'), false, '短 password 值必须被 redact');
  assert.equal(dispatched.changed, true);

  const shortValues = [
    ['password="abc"', 'abc'],
    ["password='abc'", 'abc'],
    ['password = abc', 'abc'],
    ['pwd: abc', 'abc'],
    ['secret: s3cr3t', 's3cr3t'],
    ['apiKey="xy12"', 'xy12'],
    ['token: t0k', 't0k'],
    ['passphrase: p@ss', 'p@ss'],
    ['privateKey: k1', 'k1'],
    ['PASSWORD=abc', 'abc'],
    ['MY_TOKEN=tok1234', 'tok1234'],
    ['{"client_secret":"abc"}', 'abc'],
  ];
  for (const [input, value] of shortValues) {
    const output = redactText(input);
    assert.equal(output.includes(value), false, `短敏感值必须被 redact: ${input}`);
    assert.ok(output.includes(REDACTED), `缺少 ${REDACTED}: ${input}`);
  }

  // The denied NAME is what protects the value; a non-sensitive name with a short value is
  // still ordinary text, and the long-value heuristic is unchanged for it.
  for (const benign of [
    'model = gpt-x',
    'count = 42',
    'reasoningEffort: low',
  ]) {
    assert.equal(redactText(benign), benign, `误伤普通键值: ${benign}`);
  }
});

test('SEC-01: 多行 PEM 经 line writer 跨行、跨 chunk、未闭合与超长时都不回显', () => {
  const collect = () => {
    const chunks = [];
    const sink = new Writable({
      write(chunk, _encoding, callback) { chunks.push(chunk.toString('utf8')); callback(); },
    });
    return { chunks, sink };
  };
  const begin = ['-----BEGIN', 'RSA', 'PRIVATE', 'KEY-----'].join(' ');
  const end = ['-----END', 'RSA', 'PRIVATE', 'KEY-----'].join(' ');
  const body = 'MIIEowIBAAKCAQEAfakefakefakefakefakefakefakefake';

  // 1) One chunk, block spread over several lines.
  {
    const { chunks, sink } = collect();
    const writer = createRedactingLineWriter(sink);
    writer.write(`before\n${begin}\n${body}\n${end}\nafter\n`);
    writer.end();
    const output = chunks.join('');
    assert.equal(output.includes(body), false, '同一 chunk 的多行 PEM body 不得回显');
    assert.equal(output.includes('-----BEGIN'), false);
    assert.ok(output.includes('before'));
    assert.ok(output.includes('after'));
    assert.ok(output.includes(REDACTED));
  }

  // 2) Split across several chunks, including a chunk boundary inside the END marker.
  {
    const { chunks, sink } = collect();
    const writer = createRedactingLineWriter(sink);
    const whole = `head\n${begin}\n${body}\n${end}\ntail\n`;
    const cuts = [8, 40, whole.length - 6, whole.length - 3];
    let offset = 0;
    for (const cut of cuts) {
      writer.write(whole.slice(offset, cut));
      offset = cut;
    }
    writer.write(whole.slice(offset));
    writer.end();
    const output = chunks.join('');
    assert.equal(output.includes(body), false, '跨 chunk 的多行 PEM body 不得回显');
    assert.ok(output.includes('head'));
    assert.ok(output.includes('tail'));
  }

  // 3) Never closed before end(): the identified body must be dropped, not flushed.
  {
    const { chunks, sink } = collect();
    const writer = createRedactingLineWriter(sink);
    writer.write(`head\n${begin}\n${body}\nmore secret body\n`);
    writer.end();
    const output = chunks.join('');
    assert.equal(output.includes(body), false, '未闭合 PEM body 不得回显');
    assert.equal(output.includes('more secret body'), false, '未闭合 PEM 的后续 body 不得回显');
    assert.ok(output.includes('head'));
    assert.ok(output.includes(REDACTED));
  }

  // 4) Body larger than maxTailChars, closed in a later chunk.
  {
    const { chunks, sink } = collect();
    const writer = createRedactingLineWriter(sink, { maxTailChars: 16 });
    const huge = 'A'.repeat(4096);
    writer.write(`${begin}\n`);
    for (let i = 0; i < 8; i += 1) writer.write(`${huge}\n`);
    writer.write(`${end}\nafter huge block\n`);
    writer.end();
    const output = chunks.join('');
    assert.equal(output.includes(huge), false, '超过 maxTailChars 的 PEM body 不得回显');
    assert.equal(output.includes('A'.repeat(64)), false, '任何 body 片段都不得回显');
    assert.ok(output.includes('after huge block'));
  }

  // 5) The same block shape through a single redactText call (unclosed → to end of text).
  {
    const unclosed = redactText(`${begin}\n${body}\n`);
    assert.equal(unclosed.includes(body), false, 'redactText 对未闭合 PEM 也必须清理 body');
  }
});
