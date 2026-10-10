// One authorized inference request over private stdin/stdout. There is no agent loop or tool executor here.
import { createInterface } from 'node:readline';
import { join } from 'node:path';
import { homedir } from 'node:os';
import lockfile from 'proper-lockfile';
import { mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { DefaultAgentEngine } from './engine.mjs';
import { createInferenceAdapter } from './inference-adapter.mjs';
import { ClaudeRuntime } from './claude-runtime.mjs';
import { operationErrorMessage } from './config.mjs';

const controller = new AbortController();
process.once('SIGTERM', () => controller.abort());
const send = value => new Promise((resolve, reject) => process.stdout.write(JSON.stringify(value) + '\n', error => error ? reject(error) : resolve()));
const lines = createInterface({ input: process.stdin });
let accepted = false;
lines.on('line', line => {
  if (accepted) return;
  accepted = true;
  void (async () => {
    let release;
    try {
      if (Buffer.byteLength(line) > 10 * 1024 * 1024) throw Error('Oversized inference request.');
      const value = JSON.parse(line), payload = value.payload ?? {};
      const authDirectory = process.env.WOVEN_DEFAULT_AGENT_DIRECTORY ?? join(homedir(), '.wovenmatter', 'default-agent');
      const directory = process.env.WOVEN_INFERENCE_DIRECTORY ?? authDirectory;
      // Independent helper processes must never race the same native provider conversation.
      if (value.action === 'stream') {
        const key = createHash('sha256').update(JSON.stringify([value.principalID, value.request?.scope?.conversationID])).digest('hex');
        const locks = join(directory, 'client-inference', 'locks'); await mkdir(locks, { recursive: true, mode: 0o700 });
        release = await lockfile.lock(join(locks, key), { realpath: false, stale: 60000, update: 10000, retries: 0 });
      }
      const engine = await new DefaultAgentEngine({ cwd: process.cwd(), directory, config: payload.config,
        credentials: payload.credentials, credentialAccounts: payload.credentialAccounts, claude: new ClaudeRuntime(authDirectory) }).initialize();
      const adapter = createInferenceAdapter(engine);
      if (value.action === 'catalog') await send(await adapter.catalog({ provider: value.request?.provider, signal: controller.signal }));
      else if (value.action === 'stream') await adapter.stream(value.request, { principalID: value.principalID, signal: controller.signal, onEvent: send });
      else throw Error('Unknown inference operation.');
      process.exitCode = 0;
    } catch (error) {
      await send({ type: 'host_error', message: operationErrorMessage(error) }).catch(() => {});
      process.exitCode = 1;
    } finally {
      await release?.().catch(() => {});
      lines.close();
      process.exit(process.exitCode ?? 0);
    }
  })();
});
lines.on('close', () => { if (!accepted) process.exit(0); });
