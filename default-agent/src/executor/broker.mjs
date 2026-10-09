import { latestSupportedPackage, releaseVersion } from '../package-versions.mjs';
// Trusted, background-service-only IPC. No manager credentials or resume tokens
// cross the session CLI. Executor is used unchanged through its public local API.
import { AjvJsonSchemaValidator } from '@modelcontextprotocol/sdk/validation/ajv';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFile, mkdir, chmod } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { writePrivateJSON } from '../config.mjs';

export const supportsExecutorVersion = version => releaseVersion(version) && version.startsWith('2.');
export const latestExecutorVersion = fetchImplementation => latestSupportedPackage('executor', { major: 2, prerelease: true, fetchImplementation });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const uuid = value => typeof value === 'string' && /^[0-9a-f-]{36}$/i.test(value) && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
export function validateConfiguration(config) {
  if (!uuid(config?.id) || !['local', 'remote'].includes(config.location)) throw new Error('Invalid Executor connection.');
  if (config.location === 'remote') {
    const url = new URL(config.origin);
    if (url.protocol !== 'https:' || url.port !== '8443' || url.username || url.password || url.pathname !== '/' || url.search || url.hash || !url.hostname.endsWith('.ts.net')) throw new Error('Use this host’s private Tailscale HTTPS origin.');
    if (!/^[A-Za-z0-9_][A-Za-z0-9._:-]{0,252}$/.test(config.host) || config.host.includes('..') || (config.user && !/^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$/.test(config.user))) throw new Error('Invalid SSH host or user.');
  }
  return config;
}
export class ExecutorBroker {
  constructor(directory, { fetcher = fetch, connect, spawnProcess = spawn } = {}) {
    this.directory = directory; this.fetch = fetcher; this.connectOverride = connect; this.spawnProcess = spawnProcess;
    this.jobs = new Map(); this.clients = new Map(); this.connectingClients = new Map(); this.clientGeneration = 0;
    this.state = { servers: {}, scopes: {}, jobs: {} }; this.child = null; this.saveTail = Promise.resolve();
  }
  async load() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    await chmod(this.directory, 0o700);
    try { this.state = JSON.parse(await readFile(join(this.directory, 'manager.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw new Error('Executor manager storage could not be read. Existing keys were retained.'); }
    if (!this.state || !this.state.servers || !this.state.scopes || !this.state.jobs ||
        Object.values(this.state.servers).some(server => !['local', 'remote'].includes(server.location) || !/^[0-9a-f]{64}$/.test(server.apiKey ?? '') || !/^[0-9a-f]{64}$/.test(server.encryptionKey ?? '') || !Number.isInteger(server.port) || server.port < 1 || server.port > 65535)) {
      throw new Error('Executor manager storage is incompatible. Existing credentials were retained; no runtime was started.');
    }
    // Persisted receipts prevent accidental replay after losing an in-memory program.
    for (const [id, receipt] of Object.entries(this.state.jobs)) {
      this.jobs.set(id, { ...receipt, status: receipt.status === 'completed' || receipt.status === 'cancelled' ? receipt.status : 'interrupted', error: ['completed', 'cancelled', 'interrupted'].includes(receipt.status) ? receipt.error : 'The background service restarted. Check external effects before starting a new program.' });
    }
    return this;
  }
  async save() {
    // Only terminal public results survive restart; no in-memory continuation is replayed.
    const operation = this.saveTail.then(() => writePrivateJSON(join(this.directory, 'manager.json'), this.state));
    this.saveTail = operation.catch(() => {});
    await operation;
  }
  async request(path, { method = 'GET', value, headers = {}, admin = true } = {}, context = this) {
    const response = await this.fetch(`${context.origin}${path}`, { method,
      headers: { ...(admin ? { authorization: `Bearer ${context.server.apiKey}` } : {}), ...(value === undefined ? {} : { 'content-type': 'application/json' }), ...headers },
      body: value === undefined ? undefined : JSON.stringify(value), signal: AbortSignal.timeout(30000), redirect: 'error' });
    if (!response.ok) throw new Error(`Executor rejected ${method} ${path.split('?')[0]} (HTTP ${response.status}).`);
    return { body: await response.json(), headers: response.headers };
  }
  async configure(config, install = false) {
    if (this.installing) throw new Error("Executor setup is already running.");
    this.installing = install;
    try {
      return await this.configureRuntime(config, install);
    } finally { this.installing = false; }
  }
  async configureRuntime(config, install = false) {
    validateConfiguration(config);
    if (install && [...this.jobs.values()].some(job => job.busy || !["completed", "cancelled", "interrupted"].includes(job.status))) {
      throw new Error("Stop active Executor work before installing an update.");
    }
    if (this.config && this.config.id !== config.id) {
      for (const job of this.jobs.values()) if (!['completed', 'cancelled', 'interrupted'].includes(job.status)) await this.cancel(job);
      await this.shutdownClients();
      if (config.location !== 'local') { this.child?.kill('SIGTERM'); this.child = null; }
    }
    if (this.config?.id !== config.id) this.runtimeVersion = null;
    this.config = config;
    let server = this.state.servers[config.id];
    if (server && server.location !== config.location) throw new Error('Create a new connection before changing runtime location.');
    if (server && config.location === 'remote' && server.origin !== config.origin) throw new Error('This connection belongs to another Linux host. Create a new connection.');
    if (!server) {
      server = this.state.servers[config.id] = Object.values(this.state.servers).find(value => value.location === config.location && (config.location === 'local' || value.origin === config.origin)) ?? { origin: config.origin, location: config.location, apiKey: randomBytes(32).toString('hex'), encryptionKey: randomBytes(32).toString('hex'), port: 4312 };
      await this.save(); // Never launch/deploy with secrets that were not durably saved.
    }
    this.server = server;
    this.origin = config.location === 'local' ? `http://127.0.0.1:${server.port}` : new URL(config.origin).origin;
    if (config.location === 'local') await this.startLocal(install);
    else if (install) {
      await this.deployRemote();
      const until = Date.now() + 90000;
      while (true) {
        try { await this.request('/v1/apps'); break; }
        catch { if (Date.now() >= until) throw new Error('Executor was deployed but did not become ready. Check the private HTTPS route and retry setup.'); }
        await pause(500);
      }
    }
    await this.request('/v1/apps'); // Readiness and key ownership, never fall back to unscoped MCP.
    return { ready: true, version: this.runtimeVersion ?? null, origin: this.origin };
  }
  async run(executable, args, input, environment = process.env) {
    await new Promise((resolve, reject) => {
      const child = spawn(executable, args, { env: environment, stdio: ['pipe', 'ignore', 'ignore'] });
      const timer = setTimeout(() => { child.kill('SIGTERM'); reject(new Error('Executor setup timed out. Retry setup; existing data is retained.')); }, 600000);
      child.once('error', () => { clearTimeout(timer); reject(new Error('Executor setup could not start.')); });
      child.once('exit', code => { clearTimeout(timer); code === 0 ? resolve() : reject(new Error('Executor setup failed. Check Docker, SSH and private HTTPS availability.')); });
      child.stdin.on('error', () => {}); child.stdin.end(input);
    });
  }
  async startLocal(install) {
    if (this.child?.exitCode === null && this.child.signalCode === null && !install) return;
    const previousGeneration = this.server?.runtimeGeneration;
    let generation = previousGeneration;
    let root = generation && uuid(generation) ? join(this.directory, 'runtime/generations', generation) : join(this.directory, 'runtime');
    if (install) {
      const version = await latestExecutorVersion(this.fetch);
      generation = randomUUID(); root = join(this.directory, 'runtime/generations', generation);
      await mkdir(root, { recursive: true, mode: 0o700 });
      const npm = resolve(dirname(fileURLToPath(import.meta.url)), '../../lib/npm/bin/npm-cli.js');
      await this.run(process.execPath, [npm, 'install', '--prefix', root, '--ignore-scripts', '--no-audit', '--no-fund', '--save-exact', `executor@${version}`], undefined,
        { ...process.env, PATH: `${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin` });
      const staged = JSON.parse(await readFile(join(root, 'node_modules/executor/package.json'), 'utf8'));
      if (staged.version !== version) throw new Error('Executor installation did not match the selected release. Existing runtime was retained.');
    }
    const packageJSON = JSON.parse(await readFile(join(root, 'node_modules/executor/package.json'), 'utf8').catch(() => { throw new Error('Install Executor in Settings → Connections first.'); }));
    if (!supportsExecutorVersion(packageJSON.version)) throw new Error('This Executor runtime version is unsupported. Reinstall it in Connections.');
    const hadRunningRuntime = this.child?.exitCode === null && this.child.signalCode === null;
    if (hadRunningRuntime) {
      await this.shutdownClients();
      await this.retireLocalChild();
    }
    try {
      this.runtimeVersion = packageJSON.version;
      this.child = this.spawnProcess(process.execPath, [join(root, 'node_modules/executor/bin.mjs'), 'serve'], { stdio: 'ignore', env: {
        ...process.env, PATH: `${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, EXECUTOR_DATA_DIR: join(this.directory, 'data'),
        EXECUTOR_PORT: String(this.server.port), EXECUTOR_API_KEY: this.server.apiKey, EXECUTOR_ENCRYPTION_KEY: this.server.encryptionKey, EXECUTOR_NO_UPDATE_CHECK: '1',
      } });
      this.child.on('error', () => {});
      const until = Date.now() + 90000;
      while (true) {
        try { await this.request('/v1/apps'); break; } catch { }
        if (Date.now() >= until || this.child.exitCode !== null || this.child.signalCode !== null) throw new Error('Executor did not become ready. Check port 4312 and retry setup.');
        await pause(400);
      }
      if (install) { this.server.runtimeGeneration = generation; await this.save(); }
    } catch (error) {
      await this.retireLocalChild();
      this.server.runtimeGeneration = previousGeneration;
      this.runtimeVersion = null;
      if (install && hadRunningRuntime) {
        try { await this.startLocal(false); }
        catch { throw new Error('Executor update and rollback could not become ready. Existing data and runtime generations were retained.'); }
      }
      throw error;
    }
  }
  async retireLocalChild() {
    const child = this.child;
    if (child?.exitCode === null && child.signalCode === null) {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('Executor did not stop. Existing runtime was retained.')), 10000);
        child.once('exit', () => { clearTimeout(timer); resolve(); });
        child.kill('SIGTERM');
      });
    }
    this.child = null;
  }
  async deployRemote() {
    const script = await readFile(resolve(dirname(fileURLToPath(import.meta.url)), '../../../remote/executor-deploy.sh'), 'utf8');
    // Payload goes over SSH stdin, not shell arguments, logs, or agent-visible metadata.
    const version = await latestExecutorVersion(this.fetch);
    const dockerfile = (await readFile(resolve(dirname(fileURLToPath(import.meta.url)), '../../../remote/Executor.Dockerfile'), 'utf8'))
      .replace('ARG EXECUTOR_VERSION', `ARG EXECUTOR_VERSION=${version}`);
    const payload = JSON.stringify({ origin: this.origin, apiKey: this.server.apiKey, encryptionKey: this.server.encryptionKey, version, dockerfile });
    const command = `set -eu\numask 077\nwm_payload=$(mktemp)\ntrap 'rm -f "$wm_payload"' EXIT\ncat > "$wm_payload" <<'WOVEN_EXECUTOR_SETUP_JSON'\n${payload}\nWOVEN_EXECUTOR_SETUP_JSON\n${script}\n`;
    await this.run('/usr/bin/ssh', ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'RequestTTY=no', this.config.user ? `${this.config.user}@${this.config.host}` : this.config.host, 'bash -s'], command);
    this.runtimeVersion = version;
  }
  async pair(context = this) {
    return (await this.request('/auth/pair', { method: 'POST' }, context)).body.url;
  }
  async operatorCookie(context = this) {
    const token = new URLSearchParams(new URL(await this.pair(context)).hash.slice(1)).get('pair');
    if (!token) throw new Error('Executor pairing response was incompatible.');
    const exchanged = await this.request('/auth/exchange', { method: 'POST', admin: false, value: { token }, headers: { origin: context.origin } }, context);
    const cookie = exchanged.headers.get('set-cookie')?.split(';')[0];
    if (!cookie) throw new Error('Executor control session was unavailable.');
    return cookie;
  }
  async inventory() {
    const { body } = await this.request('/dashboard/api/overview');
    const result = [];
    for (const app of body.apps) {
      // The bundled management app holds the server's administrator key. Giving
      // it to a scoped agent would let the agent edit its own scope.
      if (app.owner === 'executor-local') continue;
      let profiles = body.profiles.filter(profile => profile.app === app.id && profile.enabled !== false);
      // Explicit account-free profiles work around beta.7's undefined optional
      // fields in structured input results. Account-bearing apps need user setup.
      if (!profiles.length && !Object.keys(app.requirements?.accounts ?? {}).length) {
        try {
          const created = await this.request(`/dashboard/api/apps/${encodeURIComponent(app.id)}/profiles`, { method: 'POST', value: { name: 'Woven Matter', accounts: {}, idempotencyKey: this.config.id } });
          profiles = [created.body];
        } catch { /* Show setup in the dashboard; never guess an account. */ }
      }
      for (const profile of profiles) result.push({ id: `${app.id}:${profile.id}`, app: app.id, name: app.name ?? app.slug, profile: profile.id, profileName: profile.name ?? "Default" });
    }
    return result;
  }
  async authorize(connection, context = { origin: this.origin, server: this.server }) {
    const resource = `${context.origin}/mcp?connection=${connection}`;
    const redirect = 'http://127.0.0.1:9/woven-executor-callback';
    const { body: registration } = await this.request('/api/auth/oauth2/register', { admin: false, method: 'POST', value: {
      client_name: 'Woven Matter conversation', redirect_uris: [redirect], token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'],
    } }, context);
    const cookie = await this.operatorCookie(context);
    const verifier = randomBytes(32).toString('base64url');
    const query = new URLSearchParams({ response_type: 'code', client_id: registration.client_id, redirect_uri: redirect, code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256', scope: 'mcp offline_access', resource, state: randomUUID() });
    const { body: opened } = await this.request(`/api/auth/oauth2/authorize?${query}`, { admin: false, headers: { cookie, origin: context.origin, accept: 'application/json' } }, context);
    const next = new URL(opened.url, context.origin);
    if (next.origin !== context.origin) throw new Error('Unexpected Executor control redirect.');
    const { body: consent } = await this.request('/api/auth/oauth2/consent', { admin: false, method: 'POST', headers: { cookie, origin: context.origin }, value: { accept: true, oauth_query: next.search.slice(1) } }, context);
    const returned = new URL(consent.url);
    if (returned.origin + returned.pathname !== redirect || returned.searchParams.get('state') !== query.get('state')) throw new Error('Unexpected Executor grant response.');
    const token = await this.token(new URLSearchParams({ grant_type: 'authorization_code', client_id: registration.client_id, code: returned.searchParams.get('code'), code_verifier: verifier, redirect_uri: redirect, resource }), context.origin);
    return { resource, clientId: registration.client_id, ...token };
  }
  async token(body, origin = this.origin) {
    const response = await this.fetch(`${origin}/api/auth/oauth2/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body, redirect: 'error', signal: AbortSignal.timeout(30000) });
    if (!response.ok) throw new Error('Executor scoped grant expired. Reconnect this conversation.');
    const token = await response.json();
    return { token: token.access_token, refresh: token.refresh_token, expires: Date.now() + (token.expires_in ?? 3600) * 1000 };
  }
  async scope(session, profiles, enabled) {
    if (!session || session.length > 256 || !Array.isArray(profiles) || profiles.length > 200) throw new Error('Invalid conversation scope.');
    const key = `${this.config.id}:${session}`;
    let scope = this.state.scopes[key];
    const grouped = new Map();
    for (const profile of enabled ? profiles : []) {
      const app = grouped.get(profile.app) ?? { app: profile.app, runsAs: [], tools: { kind: 'all' } };
      if (!app.runsAs.some(value => value.id === profile.profile)) app.runsAs.push({ kind: 'profile', id: profile.profile });
      grouped.set(profile.app, app);
    }
    const apps = [...grouped.values()];
    const encoded = JSON.stringify(apps);
    if (!scope) {
      scope = this.state.scopes[key] = { id: randomUUID(), apps: null };
      await this.save(); // Stable ID also recovers a lost create response.
    }
    { // Reassert the owned scope before every program; never trust a cached grant to broaden it.
      try { await this.request(`/dashboard/api/mcp/connections/${scope.id}`, { method: 'PUT', value: { name: 'Woven Matter conversation', apps } }); }
      catch (error) {
        if (scope.apps !== null) throw error;
        await this.request('/dashboard/api/mcp/connections', { method: 'POST', value: { id: scope.id, name: 'Woven Matter conversation', apps } });
      }
      scope.apps = encoded; await this.save();
    }
    if (!enabled) await this.cancelSession(session);
    return scope;
  }
  async client(scope) {
    // Several programs in one conversation can need the same single-use refresh
    // token. Share grant creation/refresh and transport connection as one flight.
    let pending = this.connectingClients.get(scope.id);
    if (!pending) {
      pending = this.connectClient(scope, this.clientGeneration, { origin: this.origin, server: this.server });
      this.connectingClients.set(scope.id, pending);
    }
    try { return await pending; }
    finally { if (this.connectingClients.get(scope.id) === pending) this.connectingClients.delete(scope.id); }
  }
  async connectClient(scope, generation, context) {
    const check = () => { if (generation !== this.clientGeneration) throw new Error('Executor connection changed before dispatch.'); };
    if (!scope.grant) {
      const grant = await this.authorize(scope.id, context);
      check(); scope.grant = grant; await this.save(); check();
    }
    if (scope.grant.expires < Date.now() + 60000) {
      const grant = await this.token(new URLSearchParams({ grant_type: 'refresh_token', client_id: scope.grant.clientId, refresh_token: scope.grant.refresh, resource: scope.grant.resource }), context.origin);
      check(); scope.grant = { ...scope.grant, ...grant }; await this.save(); check();
      const previous = this.clients.get(scope.id); this.clients.delete(scope.id);
      await previous?.close(); check();
    }
    if (!this.clients.has(scope.id)) {
      let client;
      if (this.connectOverride) client = await this.connectOverride(scope);
      else {
        client = new Client({ name: 'wovenmatter', version: '1' }, { capabilities: {} });
        try { await client.connect(new StreamableHTTPClientTransport(new URL(scope.grant.resource), { requestInit: { headers: { authorization: `Bearer ${scope.grant.token}` } } })); }
        catch (error) { await client.close().catch(() => {}); throw error; }
      }
      if (generation !== this.clientGeneration) { await client.close().catch(() => {}); check(); }
      this.clients.set(scope.id, client);
    }
    check();
    return this.clients.get(scope.id);
  }
  publicJob(job) {
    const result = { id: job.id, status: job.status, ...(job.result ? { result: job.result } : {}), ...(job.error ? { error: job.error } : {}) };
    if (Buffer.byteLength(JSON.stringify(result)) > 900000) return { id: job.id, status: job.status, error: 'Executor output exceeds the response limit. Return a smaller result; this program will not replay.' };
    return result;
  }
  async receipt(job) {
    this.state.jobs[job.id] = { id: job.id, session: job.session, connection: job.connection, digest: job.digest, status: job.status, result: job.result, error: job.error };
    // Keep retry tombstones, but retire older potentially large output bodies.
    const terminal = Object.values(this.state.jobs).filter(value => ['completed', 'cancelled', 'interrupted'].includes(value.status));
    for (const old of terminal.slice(0, -200)) {
      if (old.result) {
        delete old.result; old.error = 'Stored output retired. This request will not replay; use a new read to inspect current state.';
        const memory = this.jobs.get(old.id); if (memory) { delete memory.result; memory.error = old.error; }
      }
    }
    await this.save();
  }
  async start({ id, session, code, action = 'execute', scope }) {
    if (this.installing) throw new Error('Executor setup is still running.');
    if (!uuid(id) || typeof code !== 'string' || Buffer.byteLength(code) > 65536) throw new Error('Execute requires a UUID and at most 64 KiB of JavaScript.');
    const digest = createHash('sha256').update(action + '\n' + code).digest('hex');
    const previous = this.jobs.get(id);
    if (previous) {
      if (previous.session !== session || previous.connection !== this.config.id || previous.digest !== digest) throw new Error('This request ID belongs to a different program.');
      return this.publicJob(previous);
    }
    const active = [...this.jobs.values()].filter(value => !['completed', 'cancelled', 'interrupted'].includes(value.status));
    if (active.length >= 16 || active.filter(value => value.session === session).length >= 4) throw new Error('Executor has too many active programs. Finish or cancel existing jobs first.');
    const job = { id, session, connection: this.config.id, digest, status: 'awaiting-approval', scope, action, code, controller: new AbortController() };
    this.jobs.set(id, job);
    try { await this.receipt(job); } catch (error) { this.jobs.delete(id); throw error; }
    return this.publicJob(job);
  }
  validateResponse(job, response) {
    if (response.action !== 'accept' || job.pending?.status !== 'input-required') return { valid: true };
    try {
      return { valid: new AjvJsonSchemaValidator().getValidator(job.pending.elicitation.requestedSchema)(response.content ?? {}).valid };
    } catch { return { valid: false }; }
  }
  async advance(job, response) {
    if (this.installing) throw new Error("Executor setup is still running.");
    if (!this.validateResponse(job, response).valid) throw new Error('Executor input does not match its requested form.');
    if (job.status === 'cancelled' || job.status === 'completed' || job.status === 'interrupted') return;
    if (job.busy) throw new Error('This program already has a pending operation.');
    job.busy = true;
    if (job.status === 'awaiting-approval' && response.action !== 'accept') { job.status = 'cancelled'; job.busy = false; await this.receipt(job); return; }
    job.status = 'running'; await this.receipt(job);
    // Dispatch exactly once. A failed/uncertain transport never replays Execute.
    (async () => {
      try {
        const client = await this.client(job.scope);
        if (job.status === 'cancelled' || job.controller.signal.aborted) return;
        const args = job.pending ? { requestId: job.pending.requestId, response } : job.action === 'skills' ? {} : { code: job.code };
        const name = job.pending ? 'resume' : job.action === 'skills' ? 'skills' : 'execute';
        const result = await client.callTool({ name, arguments: args }, undefined, { signal: job.controller.signal, timeout: 900000, maxTotalTimeout: 900000 });
        if (job.status === 'cancelled') return;
        const structured = result.structuredContent;
        if (['approval-required', 'input-required'].includes(structured?.status)) { job.pending = structured; job.status = structured.status; }
        else { job.pending = null; job.result = structured ?? result; job.status = 'completed'; }
      } catch { if (job.status !== 'cancelled') { job.status = 'interrupted'; job.error = 'Executor did not return a confirmed result. Check external effects before starting a new program.'; } }
      finally { job.busy = false; await this.receipt(job); }
    })().catch(() => {});
  }
  owned(id, session) {
    const job = this.jobs.get(id);
    if (!job || job.session !== session || job.connection !== this.config.id) throw new Error('This job is unavailable in this conversation.');
    return job;
  }
  async cancel(job) {
    if (['completed', 'cancelled', 'interrupted'].includes(job.status)) return;
    const pending = job.pending;
    job.controller?.abort(); job.status = 'cancelled'; job.pending = null; await this.receipt(job);
    if (pending) {
      const client = this.clients.get(job.scope?.id);
      // Cancellation is best effort; never let an offline server block local
      // revocation or the UI. Pending approvals cannot run without acceptance.
      client?.callTool({ name: 'resume', arguments: { requestId: pending.requestId, response: { action: 'cancel' } } }, undefined, { timeout: 3000, signal: AbortSignal.timeout(3000) }).catch(() => {});
    }
  }
  async cancelSession(session) {
    for (const job of this.jobs.values()) if (job.session === session && !['completed', 'cancelled', 'interrupted'].includes(job.status)) await this.cancel(job);
  }
  async shutdownClients() {
    this.clientGeneration++;
    this.connectingClients.clear();
    const clients = [...this.clients.values()]; this.clients.clear();
    for (const client of clients) await client.close().catch(() => {});
  }
  async stop() { await this.shutdownClients(); this.child?.kill('SIGTERM'); }
  async handle(message) {
    switch (message.operation) {
      case 'configure': return this.configure(message.config, message.install);
      case 'inventory': return this.inventory();
      case 'dashboard': return { url: await this.pair() };
      case 'scope': await this.scope(message.session, message.profiles, message.enabled); return {};
      case 'start': return this.start({ ...message, scope: await this.scope(message.session, message.profiles, true) });
      case 'status': return this.publicJob(this.owned(message.id, message.session));
      case 'interaction': return this.owned(message.id, message.session).pending ?? { status: this.owned(message.id, message.session).status };
      case 'validateResponse': return this.validateResponse(this.owned(message.id, message.session), message.response);
      case 'respond': await this.advance(this.owned(message.id, message.session), message.response); return {};
      case 'cancel': await this.cancel(this.owned(message.id, message.session)); return {};
      case 'cancelSession': await this.cancelSession(message.session); return {};
      case 'stop': await this.stop(); return {};
      default: throw new Error('Unknown Executor manager operation.');
    }
  }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const broker = await new ExecutorBroker(process.argv[2]).load();
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  let chain = Promise.resolve();
  input.on('line', line => {
    chain = chain.then(async () => {
      let response;
      try { if (Buffer.byteLength(line) > 1048576) throw new Error('Executor manager request is too large.'); response = { result: await broker.handle(JSON.parse(line)) }; }
      catch (error) { response = { error: error.message?.startsWith('Executor') || error.message?.startsWith('Invalid') || error.message?.startsWith('Install') || error.message?.startsWith('Use ') || error.message?.startsWith('This ') ? error.message : 'Executor could not complete this operation. Existing data and scopes were retained.' }; }
      const output = JSON.stringify(response);
      process.stdout.write((Buffer.byteLength(output) > 1048575 ? JSON.stringify({ error: 'Executor returned too much data. Request a smaller result or form.' }) : output) + '\n');
    });
  });
  input.on('close', () => broker.stop().finally(() => process.exit(0)));
  process.on('SIGTERM', () => broker.stop().finally(() => process.exit(0)));
}
