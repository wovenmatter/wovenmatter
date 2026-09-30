import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { sdkStatus, checkSDKUpdates, updateSDK, SDKMaintenanceError } from './sdk-management.mjs';
const directory = process.env.WOVEN_DEFAULT_AGENT_DIRECTORY ?? join(homedir(), '.wovenmatter', 'default-agent');
const controller = new AbortController();
process.once('SIGTERM', () => controller.abort());
const lines = createInterface({ input: process.stdin });
let handled = false, bytes = 0;
process.stdin.on('data', data => { bytes += data.length; if (bytes > 65536) { controller.abort(); process.exitCode = 1; lines.close(); } });
lines.on('line', async line => {
  if (handled) return; handled = true;
  try {
    const request = JSON.parse(line);
    const options = { directory, signal: controller.signal, id: request.id, version: request.version };
    const result = request.action === 'status' ? await sdkStatus(options) : request.action === 'check' ? await checkSDKUpdates(options) : request.action === 'update' ? await updateSDK(options) : null;
    if (!result) throw new SDKMaintenanceError('Choose an SDK maintenance action.');
    process.stdout.write(JSON.stringify({ result }) + '\n');
  } catch (error) {
    process.exitCode = 1;
    process.stdout.write(JSON.stringify({ error: error instanceof SDKMaintenanceError ? error.message : 'SDK maintenance could not complete. Try again.' }) + '\n');
  } finally { lines.close(); }
});
