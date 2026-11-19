// Pi Durable for Woven Matter. `node src/main.mjs` serves one session's ACP
// agent on stdio; `node src/main.mjs --control` answers one settings request.
import { dataDirectory } from './data.mjs';
import { useInstalledSDK } from './sdk.mjs';

// Before anything loads the SDK, so an update installed with `update-sdk` is used.
useInstalledSDK(dataDirectory());
if (process.argv.includes('--control')) await (await import('./control.mjs')).runControl();
else await (await import('./agent.mjs')).runAgent();
