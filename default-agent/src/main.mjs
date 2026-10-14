// Resolve once, before any SDK imports. Running sessions keep their immutable runtime.
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { resolveSDKRuntime } from './sdk-management.mjs';
const directory = process.env.WOVEN_DEFAULT_AGENT_DIRECTORY ?? join(homedir(), '.wovenmatter', 'default-agent');
process.env.WOVENMATTER_INSTRUCTIONS_FILE = fileURLToPath(new URL('../../harnesses/woven-instructions.txt', import.meta.url));
const runtime = await resolveSDKRuntime({ directory });
await import(pathToFileURL(join(runtime.root, 'src/main-runtime.mjs')).href);
