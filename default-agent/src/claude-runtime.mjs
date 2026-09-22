import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { createRequire } from 'node:module';
import { chmod, mkdir, lstat, statfs } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { DefaultAgentError, readJSON, writePrivateJSON } from './config.mjs';

const execute = promisify(execFile);
const require = createRequire(import.meta.url);
export const claudeProviders = ['claude-subscription', 'anthropic'];
export const isClaude = reference => claudeProviders.includes(reference?.split('/')[0]);
export const defaultClaudeModels = [
  { value: 'sonnet', displayName: 'Claude Sonnet', supportedEffortLevels: ['low', 'medium', 'high'] },
  { value: 'opus', displayName: 'Claude Opus', supportedEffortLevels: ['low', 'medium', 'high'] },
  { value: 'haiku', displayName: 'Claude Haiku', supportedEffortLevels: [] },
];

export function claudeExecutable(platform = process.platform, arch = process.arch) {
  return join(dirname(require.resolve(`@anthropic-ai/claude-agent-sdk-${platform}-${arch}/package.json`)), 'claude');
}

// Claude owns the contents of these directories. Never read, export, encrypt,
// refresh, or synchronize its subscription credentials from Woven Matter.
export async function claudeDirectories(directory, { platform = process.platform, memoryRoot = '/dev/shm' } = {}) {
  if (platform === 'linux') {
    if ((await statfs(memoryRoot)).type !== 0x01021994) throw new DefaultAgentError('Claude subscription sign-in requires a memory-backed workspace directory.');
    const suffix = createHash('sha256').update(directory).digest('hex').slice(0, 16);
    const config = join(memoryRoot, `woven-claude-${process.getuid()}-${suffix}`);
    await privateDirectory(config);
    return { config, storage: config };
  }
  if (platform !== 'darwin') throw new DefaultAgentError('The bundled Claude runtime is not supported on this platform.');
  const config = join(directory, 'claude-runtime');
  const storage = join(directory, 'claude-keychain');
  await privateDirectory(config);
  await privateDirectory(storage, 0o500);
  // The pinned runtime keys its native Keychain entry to this path. A read-only
  // storage directory makes its plaintext fallback fail if Keychain is locked.
  // Session files and native settings remain writable in the separate config dir.
  await chmod(storage, 0o500);
  return { config, storage };
}

async function privateDirectory(path, mode = 0o700) {
  await mkdir(path, { recursive: true, mode });
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid()) throw new DefaultAgentError('The Claude runtime directory is not private to this user.');
  await chmod(path, mode);
}

export function claudeEnvironment(paths, apiKey, source = process.env) {
  const env = Object.fromEntries(Object.entries(source).filter(([key]) => !/^(ANTHROPIC_|CLAUDE_|CLAUDECODE$)/.test(key)));
  return { ...env, CLAUDE_CONFIG_DIR: paths.config, CLAUDE_SECURESTORAGE_CONFIG_DIR: paths.storage,
    CLAUDE_AGENT_SDK_CLIENT_APP: 'wovenmatter/0.1.0', ...(apiKey ? { ANTHROPIC_API_KEY: apiKey } : {}) };
}

export class ClaudeRuntime {
  constructor(directory, { executeCommand = execute, query, directories = claudeDirectories } = {}) {
    this.directory = directory; this.executeCommand = executeCommand; this.query = query; this.directories = directories;
    this.models = defaultClaudeModels;
  }
  async environment(key) { return claudeEnvironment(await this.directories(this.directory), key); }
  async loadModels() {
    const saved = await readJSON(join(this.directory, 'claude-models.json'), []);
    if (Array.isArray(saved) && saved.length && saved.every(m => typeof m.value === 'string' && typeof m.displayName === 'string')) this.models = saved;
  }
  async status() {
    let stdout;
    try {
      ({ stdout } = await this.executeCommand(claudeExecutable(), ['auth', 'status', '--json'], {
        env: await this.environment(), timeout: 10000, maxBuffer: 65536, killSignal: 'SIGKILL',
      }));
    } catch (error) {
      if (error.code !== 1 || !error.stdout) return { connected: false, state: 'check_failed', detail: 'Could not check the native Claude sign-in. Refresh connections to retry.' };
      stdout = error.stdout;
    }
    try {
      const value = JSON.parse(stdout);
      const connected = value.loggedIn === true && value.authMethod === 'claude.ai' && value.apiProvider === 'firstParty';
      return { connected, state: connected ? 'credentials_present' : 'sign_in_required',
        account: connected && typeof value.email === 'string' ? value.email : undefined,
        detail: connected ? 'Claude reports a subscription sign-in. Available usage has not been checked.' : 'Sign in using the bundled Claude runtime.' };
    } catch { return { connected: false, state: 'check_failed', detail: 'The native Claude sign-in status could not be read.' }; }
  }
  async sdkQuery(options) {
    const query = this.query ?? (await import('@anthropic-ai/claude-agent-sdk')).query;
    return query(options);
  }
  async discover(key) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    let session;
    try {
      // An empty streaming input initializes the runtime without submitting a
      // model prompt. Model discovery must never consume inference services.
      async function* input() { if (!controller.signal.aborted) await new Promise(resolve => controller.signal.addEventListener('abort', resolve, { once: true })); }
      session = await this.sdkQuery({ prompt: input(), options: {
        cwd: this.directory, pathToClaudeCodeExecutable: claudeExecutable(),
        env: { ...await this.environment(key), CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
          DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1' },
        tools: [], skills: [], settingSources: [], strictMcpConfig: true, mcpServers: {},
        extraArgs: { 'disable-slash-commands': null },
        persistSession: false, abortController: controller } });
      const models = await session.supportedModels();
      if (models.length) {
        this.models = models;
        await writePrivateJSON(join(this.directory, 'claude-models.json'), models);
      }
    } finally { clearTimeout(timer); controller.abort(); session?.close(); }
    return this.models;
  }
  async signOut() {
    await this.executeCommand(claudeExecutable(), ['auth', 'logout'], { env: await this.environment(), timeout: 15000, maxBuffer: 65536 });
  }
}

// This entry point is launched only by the user's Connections button, in their
// terminal. Native auth has inherited stdio and owns its browser/code exchange.
export async function nativeClaudeLogin(directory) {
  const child = spawn(claudeExecutable(), ['auth', 'login'], {
    env: claudeEnvironment(await claudeDirectories(directory)), stdio: 'inherit',
  });
  return new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', code => resolve(code ?? 1));
  });
}
