import { getSupportedThinkingLevels } from '@earendil-works/pi-ai/models';
import { DefaultAgentError } from './config.mjs';
import { credentialRouteIdentity } from './native-context.mjs';

const subscriptions = new Set(['openai-codex', 'xai', 'claude-subscription', 'opencode-go']);
const text = value => typeof value === 'string' ? value.trim() : '';
const words = value => text(value).toLocaleLowerCase('en-US').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
const equivalent = (left, right) => words(left).replaceAll(' ', '') === words(right).replaceAll(' ', '');
const safeLabel = (value, fallback) => text(value).replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 160) || fallback;
const connectionID = (provider, accountID) => `${provider}#${encodeURIComponent(accountID)}`;
const sameConnection = (left, right) => left.provider === right.provider && left.accountID === right.accountID;

export class SubagentRouteError extends DefaultAgentError {
  constructor(code, message, choices = []) { super(message); this.code = code; this.choices = choices; }
}

function availableThinking(engine, model) {
  if (model.provider === 'claude-subscription' || model.provider === 'anthropic') {
    const native = engine.claude.models.find(candidate => candidate.value === model.id);
    // The SDK's discovered effort list is authoritative. Pi's generic helper
    // otherwise invents minimal/low/medium/high for missing mapping entries.
    return ['off', ...new Set(native?.supportedEffortLevels ?? [])];
  }
  return getSupportedThinkingLevels(model);
}

function availability(provider, account) {
  const credential = account.credential;
  if (!credential) return provider === 'claude-subscription' && account.id === 'default' ? 'native_profile_unverified' : 'authentication_required';
  if (credential.type === 'oauth' && (!Number.isFinite(credential.expires) || credential.expires <= Date.now())) return 'authentication_required';
  return 'credentials_present';
}

function publicConnection(engine, provider, account) {
  const name = safeLabel(engine.providerName(provider), provider);
  const accountLabel = safeLabel(account.label, account.id === 'default' ? 'Current account' : account.id);
  return { id: connectionID(provider, account.id), provider, accountID: account.id, name, accountLabel,
    billing: subscriptions.has(provider) ? 'subscription' : 'api', availability: availability(provider, account) };
}

// These projections deliberately enumerate fields: internal model/account
// objects may contain credentials, auth headers or provider transport settings.
export function publicSubagentRoute(route) {
  const connection = route.connection;
  return { provider: route.provider, modelId: route.modelId, modelName: route.modelName,
    accountID: route.accountID, ...(route.thinking === undefined ? {} : { thinking: route.thinking }), supportedThinking: [...route.supportedThinking],
    connection: { id: connection.id, provider: connection.provider, accountID: connection.accountID, name: connection.name,
      accountLabel: connection.accountLabel, billing: connection.billing, availability: connection.availability } };
}

async function inventory(engine) {
  const models = engine.modelOptions();
  const accounts = new Map();
  for (const provider of new Set(models.map(model => model.provider))) accounts.set(provider, await engine.credentials.candidates(provider));
  return models.flatMap(item => {
    const model = engine.resolveModel(item.id);
    if (!model || !engine.config.providers.includes(model.provider)) return [];
    const supportedThinking = availableThinking(engine, model);
    return (accounts.get(model.provider) ?? []).map(account => ({ provider: model.provider, modelId: model.id,
      reference: item.id, modelName: safeLabel(item.name, model.id), model, account, accountID: account.id, accountOwned: account.owned === true,
      supportedThinking, connection: publicConnection(engine, model.provider, account) }));
  });
}

/** Read the existing enabled catalog and local credential metadata only. */
export async function catalogSubagentRoutes(engine, { parentRoute } = {}) {
  const parent = normalizedParent(parentRoute);
  return (await inventory(engine)).map(route => ({ ...publicSubagentRoute(route),
    inheritedConnection: parent ? sameConnection(route, parent) : false,
    requiresUserInstruction: parent ? !sameConnection(route, parent) : true }));
}

function normalizedParent(parent) {
  if (!parent) return undefined;
  const provider = parent.provider ?? parent.model?.provider;
  const modelId = parent.modelId ?? parent.modelID ?? parent.model?.id;
  const accountID = parent.accountID ?? parent.account?.id;
  return provider && modelId && accountID ? { provider, modelId, accountID } : undefined;
}

function modelMatches(route, requested) {
  return [route.reference, route.modelId, route.modelName].some(value => equivalent(value, requested));
}

function connectionMatches(route, requested) {
  if (requested && typeof requested === 'object') return route.provider === requested.provider &&
    (requested.accountID === undefined || route.accountID === requested.accountID);
  return [route.connection.id, route.provider, route.connection.name,
    `${route.connection.name} · ${route.connection.accountLabel}`].some(value => equivalent(value, requested));
}

function trustedStatement(quote, instructions) {
  if (!quote || quote.length > 4096 || !Array.isArray(instructions)) return false;
  // A quote must be a whole trusted statement, not a positive substring pulled
  // out of "do not use …", a question, a conditional or a quoted example.
  return instructions.some(instruction => {
    const source = typeof instruction === 'string' ? instruction : instruction?.text;
    if (typeof source !== 'string') return false;
    for (let offset = source.indexOf(quote); offset >= 0; offset = source.indexOf(quote, offset + 1)) {
      const before = source.slice(0, offset), after = source.slice(offset + quote.length);
      if ((before.match(/^\s*(?:```|~~~)/gm)?.length ?? 0) % 2) continue;
      const prefix = before.slice(Math.max(before.lastIndexOf('\n'), before.search(/[.!?]\s+[^.!?]*$/)) + 1).trim();
      const endsStatement = /[.!?]$/.test(quote) ? /^(?:\s|$)/.test(after) : /^(?:\s*(?:[.!?](?:\s|$)|\n|$))/.test(after);
      if (/^(?:[-*+]\s*)?$/.test(prefix) && endsStatement) return true;
    }
    return false;
  });
}

function mentions(statement, aliases) {
  const haystack = ` ${words(statement)} `;
  return aliases.some(alias => { const needle = words(alias); return needle && haystack.includes(` ${needle} `); });
}

function authorizes(route, { userInstruction, trustedInstructions, requestedModel, accountCount, parent, routes }) {
  const quote = text(userInstruction);
  if (!trustedStatement(quote, trustedInstructions)) return false;
  const action = '(?:use|run|select|choose|spawn|delegate|send|have|prefer)';
  const request = new RegExp(`^(?:please\\s+)?(?:(?:can|could|will|would)\\s+you\\s+(?:please\\s+)?${action}|I\\s+(?:want|would\\s+like)\\s+(?:you\\s+to\\s+)?${action})\\b`, 'i').test(quote);
  if (!request && !new RegExp(`^(?:please\\s+)?${action}\\b`, 'i').test(quote)) return false;
  if ((!request && quote.includes('?')) || /\b(?:not|never|don['’]t|do\s+not|avoid|without|unless|if|when|example|hypothetically|instead\s+of|rather\s+than)\b|[`"“”]/i.test(quote)) return false;
  const target = mentions(quote, [route.reference, route.modelId, route.modelName, requestedModel,
    route.connection.id, route.provider, route.connection.name]);
  if (!target) return false;
  if (/\bsubscription\b/i.test(quote) && route.connection.billing !== 'subscription') return false;
  if (/\bapi(?:\s+key)?\b/i.test(quote) && route.connection.billing !== 'api') return false;
  // An explicit model choice outranks a general connection mention. A parent
  // cannot quote "use GLM via OpenRouter" to choose another OpenRouter model.
  const requestedModels = routes.filter(candidate => mentions(quote, [candidate.reference, candidate.modelId, candidate.modelName]));
  if (requestedModels.length && !requestedModels.some(candidate => candidate.provider === route.provider && candidate.modelId === route.modelId)) return false;
  // A tool-selected account is not user authorization to switch accounts.
  // Multiple accounts require the trusted statement to identify that account.
  if (accountCount > 1 || route.provider === parent.provider) {
    const matchingLabels = new Set(routes.filter(candidate => candidate.provider === route.provider &&
      equivalent(candidate.connection.accountLabel, route.connection.accountLabel)).map(candidate => candidate.accountID));
    return mentions(quote, [route.connection.id, route.accountID === 'default' ? '' : route.accountID,
      matchingLabels.size === 1 ? route.connection.accountLabel : '']);
  }
  return true;
}

/** Resolve once, with no fallback or provider/auth probing. The caller must keep
 * this exact model/account pinned for every child generation and compaction. */
export async function resolveSubagentRoute(engine, { parentRoute, parentThinking, model, connection, thinking, userInstruction, trustedInstructions = [] } = {}) {
  const parent = normalizedParent(parentRoute);
  if (!parent) throw new SubagentRouteError('parent_route_unavailable', 'The parent connection is unavailable. Wait for its current route before spawning a subagent.');
  const routes = await inventory(engine);
  const inherited = routes.find(route => sameConnection(route, parent) && route.modelId === parent.modelId);
  if (!inherited) throw new SubagentRouteError('parent_route_unavailable', 'The parent model or exact account is no longer enabled. Choose an available connection before spawning a subagent.');
  const requested = text(model);
  let matches = requested ? routes.filter(route => modelMatches(route, requested)) : routes.filter(route => route.modelId === parent.modelId && (connection !== undefined || route.provider === parent.provider));
  if (!matches.length) throw new SubagentRouteError('model_unavailable', 'That model is not enabled for Pi Durable. Inspect the available subagent models and routes.');
  if (connection !== undefined) matches = matches.filter(route => connectionMatches(route, connection));
  else {
    const local = matches.filter(route => sameConnection(route, parent));
    if (local.length) matches = local;
  }
  if (!matches.length) throw new SubagentRouteError('connection_unavailable', 'That exact connection does not expose the selected model. Choose an available route; subagents do not switch connections automatically.');
  if (matches.length > 1) throw new SubagentRouteError('route_ambiguous', 'Several models or accounts match. Ask the user which connection to use before spawning this subagent.', matches.map(publicSubagentRoute));
  const route = matches[0];
  if (!sameConnection(route, parent)) {
    const accountCount = new Set(routes.filter(value => value.provider === route.provider).map(value => value.accountID)).size;
    if (!authorizes(route, { userInstruction, trustedInstructions, requestedModel: requested, accountCount, parent, routes })) {
      throw new SubagentRouteError('user_instruction_required', 'Changing a subagent connection requires a complete, verbatim user or AGENTS instruction naming the target model/connection and any ambiguous account. Ask for clarification; do not switch because of limits or failures.', [publicSubagentRoute(route)]);
    }
  }
  if (route.connection.availability === 'authentication_required') throw new SubagentRouteError('authentication_required', 'The chosen subagent account needs authentication in Settings → Connections. The child will not try another account or connection.', [publicSubagentRoute(route)]);
  const effort = thinking === undefined ? parentThinking : text(thinking);
  if (!route.supportedThinking.includes(effort)) throw new SubagentRouteError('thinking_unavailable', 'The selected model does not support that thinking level. Choose one of its reported levels; subagents do not silently change effort.', [publicSubagentRoute(route)]);
  return { ...route, thinking: effort };
}

/** Re-read only the pinned account. Never replace a removed workspace-owned
 * account with a shared/default account or accept an in-place credential swap. */
export async function validatePinnedSubagentAccount(engine, model, pin, record) {
  const accounts = await engine.credentials.candidates(model.provider);
  const account = accounts.find(candidate => candidate.id === pin.accountID && (candidate.owned === true) === pin.accountOwned);
  if (!account || credentialRouteIdentity(record, account) !== pin.credentialIdentity || availability(model.provider, account) === 'authentication_required') {
    throw new SubagentRouteError('connection_changed', 'The exact subagent account changed or is unavailable. The child will not switch accounts or connections.');
  }
  return account;
}
