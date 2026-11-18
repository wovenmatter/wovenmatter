import { randomUUID } from 'node:crypto';
import { searchProviderNames } from './config.mjs';
import { localServers, probeServer, serverURL } from './local-servers.mjs';

// A host's own sign-ins, kept in its device vault (`CredentialVault.openDevice`):
// subscriptions it signed in to itself (`owned`, renewed here), API and web
// search keys (`accounts`, first = primary), and local model servers
// (`servers`, keys in `owned`). Another device changes them only through this
// host's signed routes; nothing here is sent anywhere else.
export const apiKeyProviders = ['openai', 'anthropic', 'xai-api', 'openrouter', 'opencode-go', ...Object.keys(searchProviderNames)];
export const subscriptionProviders = ['openai-codex', 'claude-subscription', 'xai'];
export const maximumKeys = 4;
export const maximumServers = 12;

const fail = (message, statusCode = 400) => Object.assign(new Error(message), { statusCode });

// Display only: never proof of entitlement.
export function accountLabel(credential) {
  if (typeof credential?.displayName === 'string' && credential.displayName) return credential.displayName;
  const parts = typeof credential?.access === 'string' ? credential.access.split('.') : [];
  if (parts.length === 3) {
    try {
      const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
      const value = claims.email ?? claims['https://api.openai.com/profile']?.email ?? claims.name;
      if (typeof value === 'string' && value) return value.slice(0, 256);
    } catch { /* A label is optional. */ }
  }
  return typeof credential?.accountId === 'string' && credential.type !== 'native' ? credential.accountId : 'Subscription';
}

// The accounts a device holds, in the app's `ProviderConnectionAccounts.Account` shape.
export function listSignIns(stored = {}) {
  const accounts = {};
  for (const provider of subscriptionProviders) {
    const owned = stored.owned?.[provider];
    accounts[provider] = owned ? [{ id: 'default', label: accountLabel(owned), isSelected: true }] : [];
  }
  for (const provider of apiKeyProviders) {
    accounts[provider] = (stored.accounts?.[provider] ?? []).map((entry, index) => ({
      id: entry.id, label: entry.label, isSelected: index === 0, ...(entry.createdAt ? { createdAt: entry.createdAt } : {}),
    }));
  }
  return { accounts, servers: (stored.servers ?? []).map(server => ({ ...server })) };
}

// Chat settings sync from other devices; the servers and their enablement are this device's.
export function deviceConfig(config = {}, stored = {}) {
  const servers = (stored.servers ?? []).map(({ id, url, models }) => ({ id, url, models }));
  const providers = (config.providers ?? []).filter(id => !/^local-server-/.test(id));
  return { ...config, customServers: servers, providers: [...providers, ...servers.map(server => server.id)] };
}

function key(value) {
  const trimmed = typeof value === 'string' ? value.trim() : '';
  if (!trimmed || trimmed.length > 8192 || /[\r\n]/.test(trimmed)) throw fail('Enter an API key.');
  return trimmed;
}
function label(value) {
  if (value == null || value === '') return undefined;
  if (typeof value !== 'string' || value.length > 256) throw fail('Use a shorter label.');
  return value.trim() || undefined;
}
function provider(value, allowed) {
  if (typeof value !== 'string' || !allowed.includes(value)) throw fail('Choose a provider connection.');
  return value;
}

// Applies one change and answers with the device's accounts. `probe` checks a
// local model server the way this device's Pi Durable will reach it.
export async function changeSignIns(vault, request, { probe = probeServer, now = () => new Date() } = {}) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw fail('Choose a sign-in change.');
  const { action } = request;
  let probed;
  if (action === 'connectServer') {
    // Only the key typed for this server is ever sent to it; a server being
    // reconnected keeps its address. Both are checked before the probe.
    const typed = key(request.key);
    const replacing = request.server?.id;
    if (replacing !== undefined) {
      const existing = typeof replacing === 'string' ? ((await vault.read()).servers ?? []).find(server => server.id === replacing) : undefined;
      if (!existing) throw fail('This server connection changed or was removed. Try again.', 409);
      let url; try { url = serverURL(request.url); } catch (error) { throw fail(error.message); }
      if (url !== existing.url) throw fail('Add a new connection to use a different server URL.');
    }
    try { probed = await probe(request.url, typed); }
    catch (error) { throw fail(error.message); }
    if (!Array.isArray(probed?.models) || !probed.models.length) throw fail('The server did not return any models.');
  }
  const next = await vault.modify(async stored => {
    const accounts = { ...stored.accounts }, owned = { ...stored.owned };
    let servers = [...(stored.servers ?? [])];
    const entries = id => [...(accounts[id] ?? [])];
    switch (action) {
      case 'saveKey': {
        const id = provider(request.provider, apiKeyProviders), value = key(request.key), name = label(request.label);
        const list = entries(id), existing = list.findIndex(entry => entry.credential?.key === value);
        if (existing >= 0) { if (name) list[existing] = { ...list[existing], label: name }; }
        else {
          if (list.length >= maximumKeys) throw fail('You can connect up to four accounts of each type.');
          list.push({ id: randomUUID(), label: name ?? `API key ${list.length + 1}`, createdAt: now().toISOString(), credential: { type: 'api_key', key: value } });
        }
        accounts[id] = list;
        break;
      }
      case 'select': case 'move': {
        const id = provider(request.provider, apiKeyProviders), list = entries(id);
        const index = list.findIndex(entry => entry.id === request.id);
        if (index < 0) throw fail('This account is no longer connected.', 409);
        if (action === 'select') list.unshift(...list.splice(index, 1));
        else if (Number.isInteger(request.offset) && index > 0) {
          const target = Math.max(1, Math.min(list.length - 1, index + request.offset));
          list.splice(target, 0, ...list.splice(index, 1));
        }
        accounts[id] = list;
        break;
      }
      case 'remove': {
        const id = provider(request.provider, [...apiKeyProviders, ...subscriptionProviders]);
        if (subscriptionProviders.includes(id)) delete owned[id];
        else accounts[id] = entries(id).filter(entry => entry.id !== request.id);
        break;
      }
      case 'connectServer': {
        const replacing = request.server?.id;
        const existing = replacing ? servers.find(server => server.id === replacing) : undefined;
        if (replacing && !existing) throw fail('This server connection changed or was removed. Try again.', 409);
        if (existing && existing.url !== probed.url) throw fail('Add a new connection to use a different server URL.');
        if (!existing && servers.length >= maximumServers) throw fail('You can connect up to 12 local model servers.');
        const server = { id: existing?.id ?? 'local-server-' + randomUUID(), url: probed.url, models: probed.models, verifiedAt: now().toISOString() };
        localServers([server]);
        servers = [...servers.filter(value => value.id !== server.id), server];
        owned[server.id] = { type: 'api_key', key: key(request.key) };
        break;
      }
      case 'removeServer': {
        // Only a listed server and its own key: never another sign-in.
        const id = request.server?.id;
        if (typeof id !== 'string' || !/^local-server-[a-f0-9-]{36}$/.test(id) || !servers.some(server => server.id === id)) throw fail('Choose a server connection.');
        servers = servers.filter(server => server.id !== id);
        delete owned[id];
        break;
      }
      default: throw fail('Choose a sign-in change.');
    }
    return { ...stored, accounts, owned, servers };
  });
  return listSignIns(next);
}
