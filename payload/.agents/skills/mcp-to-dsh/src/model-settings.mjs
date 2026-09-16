import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { parse } from "yaml";
import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all";

export const MODEL_SETTINGS_SCHEMA_VERSION = 1;

/** DSH 内置官方 provider 路由；它由 llm-deepseek 插件注册，不出现在 llm-pi-ai.providers 中。 */
export const OFFICIAL_PROVIDER_ID = "deepseek-official";
const OFFICIAL_PROVIDER_NAME = "DeepSeek";
const OFFICIAL_ADAPTER_MODULE = "@deepseek-ai/dsh-llm-deepseek";

const stringOrNull = (value) => typeof value === "string" && value.trim() ? value.trim() : null;
const recordOrEmpty = (value) => value && typeof value === "object" && !Array.isArray(value) ? value : {};
const finiteOrNull = (value) => Number.isFinite(value) ? value : null;

let officialAdapterDefaultsPromise;

/**
 * 读取当前安装的 DSH 官方 DeepSeek 适配器自带的建议性模型目录。
 * 只取模型条目与展示用的默认窗口等字段：解析结果里的 baseURL、apiKeyEnv 引用与
 * 请求头永远不会进入返回给 UI 的目录，也不会被本模块写回任何地方。
 * 适配器不可用时退化为空目录，由 agent-default-model 兜底，绝不因此让整个目录接口失败。
 */
function loadOfficialAdapterDefaults() {
  officialAdapterDefaultsPromise ??= import(OFFICIAL_ADAPTER_MODULE)
    .then((module) => {
      const resolved = module.resolveAdapterOptions({});
      return {
        models: Array.isArray(resolved?.models) ? resolved.models : [],
        contextWindow: finiteOrNull(resolved?.defaultContextWindow),
        maxTokens: finiteOrNull(resolved?.maxTokens),
      };
    })
    .catch(() => ({ models: [], contextWindow: null, maxTokens: null }));
  return officialAdapterDefaultsPromise;
}

function identifier(value, label) {
  const normalized = stringOrNull(value);
  if (!normalized || normalized.length > 256 || /[\u0000-\u001f\u007f]/.test(normalized)) {
    throw new Error(`${label} 必须是 1-256 位且不含控制字符的字符串。`);
  }
  return normalized;
}

function publicModel(value) {
  if (!value || typeof value !== "object") return null;
  const id = stringOrNull(value.id);
  if (!id) return null;
  return {
    id,
    name: stringOrNull(value.name) ?? id,
    contextWindow: Number.isFinite(value.contextWindow) ? value.contextWindow : null,
    maxTokens: Number.isFinite(value.maxTokens) ? value.maxTokens : null,
    input: Array.isArray(value.input) ? value.input.filter((item) => typeof item === "string") : ["text"],
  };
}

/**
 * 组装内置官方 provider 条目。llm-deepseek.models 显式配置时整体替换适配器自带目录；
 * 否则使用当前安装版本的自带建议目录。agent-default-model 指向官方模型但目录里没有它时，
 * 该默认模型会被原样补进目录，因为 DSH 会把官方模型 id 直接透传给协议。
 * 这里只读取 models / defaultContextWindow / maxTokens；section 中的 apiKeyEnv、baseURL、
 * headers 等敏感设置从不读取，也从不进入返回值。
 */
async function readOfficialProvider(settings, normalizedDefault) {
  const section = recordOrEmpty(settings["llm-deepseek"]);
  const configuredModels = Array.isArray(section.models) ? section.models : [];
  const explicitCatalog = configuredModels.length > 0;
  const bundled = explicitCatalog ? null : await loadOfficialAdapterDefaults();
  const fallbackContextWindow = finiteOrNull(section.defaultContextWindow) ?? bundled?.contextWindow ?? null;
  const fallbackMaxTokens = finiteOrNull(section.maxTokens) ?? bundled?.maxTokens ?? null;
  const sourceModels = explicitCatalog ? configuredModels : (bundled?.models ?? []);
  const models = sourceModels.map((model) => {
    const record = recordOrEmpty(model);
    return {
      ...record,
      contextWindow: finiteOrNull(record.contextWindow) ?? fallbackContextWindow,
      maxTokens: finiteOrNull(record.maxTokens) ?? fallbackMaxTokens,
      input: record.inputModalities ?? record.input,
    };
  });
  if (normalizedDefault?.provider === OFFICIAL_PROVIDER_ID
      && !models.some((model) => stringOrNull(model.id) === normalizedDefault.model)) {
    models.push({
      id: normalizedDefault.model,
      name: normalizedDefault.model,
      contextWindow: fallbackContextWindow,
      maxTokens: fallbackMaxTokens,
      input: ["text"],
    });
  }
  return {
    id: OFFICIAL_PROVIDER_ID,
    name: OFFICIAL_PROVIDER_NAME,
    api: null,
    catalogInherited: !explicitCatalog,
    models: models.map(publicModel).filter(Boolean),
  };
}

/**
 * Read only the model/provider fields that are safe to expose to an authenticated local UI.
 * Credential values are never read. Custom `llm-pi-ai.providers` entries keep their existing
 * behavior; the built-in `deepseek-official` route is always represented even though it is
 * absent from `llm-pi-ai.providers`.
 */
export async function readDshModelCatalog(dshHome) {
  if (!dshHome) throw new Error("Monitor 未配置 DSH_HOME，无法读取模型目录。");
  const sourcePath = join(dshHome, "settings.yaml");
  const settings = recordOrEmpty(parse(await readFile(sourcePath, "utf8")));
  const configuredProviders = settings["llm-pi-ai"]?.providers;
  if (configuredProviders !== undefined && configuredProviders !== null
      && (typeof configuredProviders !== "object" || Array.isArray(configuredProviders))) {
    throw new Error("DSH settings.yaml 的 llm-pi-ai.providers 必须是 provider 映射。");
  }
  const providerMap = recordOrEmpty(configuredProviders);

  const configuredDefault = recordOrEmpty(settings["agent-default-model"]);
  const defaultModel = Object.keys(configuredDefault).length > 0
    ? {
        provider: stringOrNull(configuredDefault.provider),
        model: stringOrNull(configuredDefault.model),
      }
    : null;
  const normalizedDefault = defaultModel?.provider && defaultModel?.model ? defaultModel : null;

  const providers = Object.entries(providerMap).map(([providerId, value]) => {
    const provider = value && typeof value === "object" ? value : {};
    const configuredModels = Array.isArray(provider.models) ? provider.models : [];
    let builtinModels = [];
    try {
      builtinModels = getBuiltinModels(providerId);
    } catch {
      builtinModels = [];
    }
    const builtinById = new Map(builtinModels.map((model) => [model.id, model]));
    const sourceModels = configuredModels.length > 0
      ? configuredModels.map((model) => ({ ...(builtinById.get(model?.id) ?? {}), ...model }))
      : builtinModels.map((model) => ({ ...model, ...(provider.modelOverrides?.[model.id] ?? {}) }));
    const resolvedModels = sourceModels.map((model) => ({
      ...model,
      contextWindow: model.contextWindow ?? provider.defaultContextWindow,
      maxTokens: model.maxTokens ?? provider.defaultMaxTokens,
      input: model.input ?? provider.defaultInput,
    }));
    return {
      id: providerId,
      name: stringOrNull(provider.displayName) ?? providerId,
      api: stringOrNull(provider.api),
      catalogInherited: configuredModels.length === 0,
      models: resolvedModels.map(publicModel).filter(Boolean),
    };
  });

  if (!Object.hasOwn(providerMap, OFFICIAL_PROVIDER_ID)) {
    providers.push(await readOfficialProvider(settings, normalizedDefault));
  }

  return {
    sourcePath,
    providers,
    defaultModel: normalizedDefault,
  };
}

export function normalizeModelSelection(value, { allowNull = true } = {}) {
  if (value === null && allowNull) return null;
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("selection 必须是 { provider, model }，或 null（跟随 DSH 默认）。");
  }
  const provider = identifier(value.provider, "selection.provider");
  const model = identifier(value.model, "selection.model");
  return { provider, model };
}

export function validateModelSelection(catalog, selection) {
  const normalized = normalizeModelSelection(selection, { allowNull: false });
  const provider = catalog.providers.find((item) => item.id === normalized.provider);
  if (!provider) throw new Error(`DSH settings.yaml 中不存在模型供应商 ${normalized.provider}。`);
  if (!provider.models.some((item) => item.id === normalized.model)) {
    throw new Error(`供应商 ${normalized.provider} 未配置模型 ${normalized.model}。`);
  }
  return normalized;
}

export function acpModelValue(selection) {
  const normalized = normalizeModelSelection(selection, { allowNull: false });
  return JSON.stringify([normalized.provider, normalized.model]);
}

export function resolveAcpModelValue(configOptions, selection) {
  const normalized = normalizeModelSelection(selection, { allowNull: false });
  const modelOption = (Array.isArray(configOptions) ? configOptions : [])
    .find((option) => option?.id === "model");
  if (!modelOption) throw new Error("DSH session 未提供 model config option。");
  const candidates = [];
  for (const entry of Array.isArray(modelOption.options) ? modelOption.options : []) {
    if (Array.isArray(entry?.options)) candidates.push(...entry.options);
    else candidates.push(entry);
  }
  const match = candidates.find((candidate) => {
    if (typeof candidate?.value !== "string") return false;
    try {
      const pair = JSON.parse(candidate.value);
      return Array.isArray(pair)
        && pair[0] === normalized.provider
        && pair[1] === normalized.model;
    } catch {
      return false;
    }
  });
  if (!match) {
    throw new Error(`DSH session 的 model config option 不包含 ${normalized.provider} / ${normalized.model}。`);
  }
  return match.value;
}

export async function applyAcpModelSelection({ request, method, sessionId, configOptions, selection }) {
  const value = resolveAcpModelValue(configOptions, selection);
  const response = await request(method, { sessionId, configId: "model", value });
  const effective = response?.configOptions?.find((option) => option?.id === "model")?.currentValue;
  if (effective !== value) {
    throw new Error(`DSH 未确认请求的模型配置（requested=${value}, effective=${effective ?? "missing"}）。`);
  }
  return { value, response };
}

export function readStoredModelPreference(value) {
  if (!value || typeof value !== "object" || value.schemaVersion !== MODEL_SETTINGS_SCHEMA_VERSION) {
    throw new Error("模型偏好文件 schemaVersion 无效。");
  }
  return {
    schemaVersion: MODEL_SETTINGS_SCHEMA_VERSION,
    selection: normalizeModelSelection(value.selection),
    revision: Number.isSafeInteger(value.revision) && value.revision >= 0 ? value.revision : 0,
    updatedAt: stringOrNull(value.updatedAt),
  };
}
