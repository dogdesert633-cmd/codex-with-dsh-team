import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  acpModelValue,
  applyAcpModelSelection,
  readDshModelCatalog,
  resolveAcpModelValue,
  validateModelSelection,
} from "../src/model-settings.mjs";
import { shouldAcceptModelProjection } from "../public/model-revision.js";

const SETTINGS = `
llm-pi-ai:
  providers:
    inherited:
      apiKeyEnv: INHERITED_TOKEN
      headers:
        Authorization: never-expose-this
      models: []
    configured:
      displayName: Configured Provider
      api: openai-completions
      baseURL: http://private.internal/v1
      apiKeyEnv: CONFIGURED_TOKEN
      models:
        - id: model-a
          name: Model A
          contextWindow: 128000
          input: [text, image]
agent-default-model:
  provider: configured
  model: model-a
`;

test("DSH model catalog is allow-listed, marks inherited catalogs and never exposes secret-bearing settings", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "dsh-model-catalog-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, "settings.yaml"), SETTINGS, "utf8");
  const catalog = await readDshModelCatalog(root);

  assert.deepEqual(catalog.defaultModel, { provider: "configured", model: "model-a" });
  assert.equal(catalog.providers[0].catalogInherited, true);
  assert.deepEqual(catalog.providers[1].models[0], {
    id: "model-a",
    name: "Model A",
    contextWindow: 128000,
    maxTokens: null,
    input: ["text", "image"],
  });
  const serialized = JSON.stringify(catalog);
  assert.equal(serialized.includes("secret-value"), false);
  assert.equal(serialized.includes("never-expose-this"), false);
  assert.equal(serialized.includes("private.internal"), false);
  assert.equal(serialized.includes("CONFIGURED_TOKEN"), false);
});

test("selection validation accepts only exact configured provider/model pairs", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "dsh-model-validate-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, "settings.yaml"), SETTINGS, "utf8");
  const catalog = await readDshModelCatalog(root, {});
  assert.deepEqual(validateModelSelection(catalog, { provider: "configured", model: "model-a" }), {
    provider: "configured",
    model: "model-a",
  });
  assert.throws(() => validateModelSelection(catalog, { provider: "configured", model: "missing" }), /未配置模型/);
  assert.throws(() => validateModelSelection(catalog, { provider: "configured", model: "bad\nvalue" }), /控制字符/);
});

test("an empty configured list resolves from the exact bundled provider catalog", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "dsh-model-inherited-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, "settings.yaml"), `
llm-pi-ai:
  providers:
    opencode-go:
      models: []
agent-default-model:
  provider: opencode-go
  model: minimax-m3
`, "utf8");
  const catalog = await readDshModelCatalog(root);
  assert.equal(catalog.providers[0].catalogInherited, true);
  assert.ok(catalog.providers[0].models.length > 0);
  assert.ok(catalog.providers[0].models.some((model) => model.id === "minimax-m3"));
});

test("the built-in deepseek-official provider is synthesized without llm-pi-ai.providers", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "dsh-model-official-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, "settings.yaml"), `
agent-default-model:
  provider: deepseek-official
  model: deepseek-v4-flash
`, "utf8");
  const catalog = await readDshModelCatalog(root);

  const official = catalog.providers.find((provider) => provider.id === "deepseek-official");
  assert.ok(official, "内置官方 provider 必须出现在目录里");
  assert.equal(official.name, "DeepSeek");
  assert.deepEqual(catalog.defaultModel, { provider: "deepseek-official", model: "deepseek-v4-flash" });
  assert.ok(official.models.some((model) => model.id === "deepseek-v4-flash"));
  assert.deepEqual(
    validateModelSelection(catalog, { provider: "deepseek-official", model: "deepseek-v4-flash" }),
    { provider: "deepseek-official", model: "deepseek-v4-flash" },
  );
  for (const secretBearing of ["apiKeyEnv", "baseURL", "headers"]) {
    assert.equal(Object.hasOwn(official, secretBearing), false, `${secretBearing} 不得进入目录`);
  }
});

test("the default official catalog mirrors the installed adapter's bundled models", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "dsh-model-official-defaults-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, "settings.yaml"), `
llm-pi-ai:
  providers:
    custom:
      models:
        - id: custom-model
agent-default-model:
  provider: custom
  model: custom-model
`, "utf8");
  const { resolveAdapterOptions } = await import("@deepseek-ai/dsh-llm-deepseek");
  const adapterModels = resolveAdapterOptions({}).models;
  const catalog = await readDshModelCatalog(root);

  const official = catalog.providers.find((provider) => provider.id === "deepseek-official");
  assert.ok(official, "内置官方 provider 必须出现在目录里");
  assert.equal(official.catalogInherited, true);
  for (const adapterModel of adapterModels) {
    assert.ok(official.models.some((model) => model.id === adapterModel.id), `缺少官方模型 ${adapterModel.id}`);
  }
  assert.ok(official.models.some((model) => model.id === "deepseek-v4-flash"));
  assert.equal(catalog.providers[0].id, "custom", "自定义 provider 仍然排在前面且不受影响");
});

test("llm-deepseek.models replaces the bundled official catalog and an unknown official default is still exposed", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "dsh-model-official-explicit-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, "settings.yaml"), `
llm-deepseek:
  apiKeyEnv: OFFICIAL_TOKEN
  baseURL: http://official.internal/v1
  headers:
    Authorization: official-never-expose
  defaultContextWindow: 131072
  models:
    - id: custom-official-model
      name: Custom Official
      inputModalities: [text, image]
agent-default-model:
  provider: deepseek-official
  model: future-official-model
`, "utf8");
  const catalog = await readDshModelCatalog(root);

  const official = catalog.providers.find((provider) => provider.id === "deepseek-official");
  assert.ok(official, "内置官方 provider 必须出现在目录里");
  assert.equal(official.catalogInherited, false);
  assert.deepEqual(official.models.map((model) => model.id), ["custom-official-model", "future-official-model"]);
  assert.deepEqual(official.models[0], {
    id: "custom-official-model",
    name: "Custom Official",
    contextWindow: 131072,
    maxTokens: null,
    input: ["text", "image"],
  });
  assert.deepEqual(official.models[1], {
    id: "future-official-model",
    name: "future-official-model",
    contextWindow: 131072,
    maxTokens: null,
    input: ["text"],
  });
  assert.deepEqual(
    validateModelSelection(catalog, { provider: "deepseek-official", model: "future-official-model" }),
    { provider: "deepseek-official", model: "future-official-model" },
  );
  const serialized = JSON.stringify(catalog);
  for (const marker of ["OFFICIAL_TOKEN", "official.internal", "official-never-expose"]) {
    assert.equal(serialized.includes(marker), false, `目录泄露了 ${marker}`);
  }
});

test("ACP model value must be taken from the session-advertised option", () => {
  const selection = { provider: "configured", model: "model-a" };
  const opaque = acpModelValue(selection);
  const options = [{
    id: "model",
    type: "select",
    currentValue: "old",
    options: [{ group: "configured", options: [{ value: opaque, name: "Model A" }] }],
  }];
  assert.equal(resolveAcpModelValue(options, selection), opaque);
  assert.throws(
    () => resolveAcpModelValue(options, { provider: "configured", model: "model-b" }),
    /不包含/,
  );
});

test("ACP apply sends the advertised value and rejects an unconfirmed response", async () => {
  const selection = { provider: "configured", model: "model-a" };
  const opaque = acpModelValue(selection);
  const configOptions = [{
    id: "model",
    options: [{ group: "configured", options: [{ value: opaque, name: "Model A" }] }],
  }];
  const calls = [];
  const applied = await applyAcpModelSelection({
    request: async (method, payload) => {
      calls.push({ method, payload });
      return { configOptions: [{ id: "model", currentValue: opaque }] };
    },
    method: "session/set_config_option",
    sessionId: "session-1",
    configOptions,
    selection,
  });
  assert.equal(applied.value, opaque);
  assert.deepEqual(calls, [{
    method: "session/set_config_option",
    payload: { sessionId: "session-1", configId: "model", value: opaque },
  }]);

  await assert.rejects(
    applyAcpModelSelection({
      request: async () => ({ configOptions: [{ id: "model", currentValue: "different" }] }),
      method: "session/set_config_option",
      sessionId: "session-2",
      configOptions,
      selection,
    }),
    /未确认/,
  );
});

test("the UI accepts equal/newer model projections and rejects stale HTTP responses", () => {
  assert.equal(shouldAcceptModelProjection({ revision: 2 }, { revision: 1 }), false);
  assert.equal(shouldAcceptModelProjection({ revision: 2 }, { revision: 2 }), true);
  assert.equal(shouldAcceptModelProjection({ revision: 2 }, { revision: 3 }), true);
  assert.equal(shouldAcceptModelProjection(null, { revision: 0 }), true);
});
