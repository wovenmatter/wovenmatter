import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { Type } from 'typebox';

export const automationSchemas = {
  browser: { type: 'object', additionalProperties: false, required: ['action'], properties: {
    action: { type: 'string', enum: ['tabs', 'open', 'focus', 'close', 'navigate', 'snapshot', 'screenshot', 'click', 'fill', 'type', 'press', 'scroll', 'hover', 'select', 'check', 'drag', 'evaluate', 'upload', 'dialog', 'download', 'downloads', 'read-download'] },
    tabId: { type: 'string' }, url: { type: 'string' }, frame: { type: 'string', description: 'Optional iframe CSS selector for page content operations.' }, selector: { type: 'string' }, text: { type: 'string' }, key: { type: 'string' },
    x: { type: 'number' }, y: { type: 'number' }, button: { enum: ['left', 'right', 'middle'] }, clickCount: { type: 'integer', minimum: 1, maximum: 3 },
    destination: { type: 'string' }, code: { type: 'string' }, value: { type: 'string' }, checked: { type: 'boolean' }, accept: { type: 'boolean' },
    name: { type: 'string' }, mimeType: { type: 'string' }, data: { type: 'string' }, id: { type: 'string' }, offset: { type: 'integer', minimum: 0 }
  } },
  computer: { type: 'object', additionalProperties: false, required: ['action'], properties: {
    action: { type: 'string', enum: ['status', 'apps', 'screenshot', 'click', 'type', 'press', 'scroll', 'launch'] },
    frameId: { type: 'string' }, x: { type: 'number' }, y: { type: 'number' }, button: { enum: ['single', 'right', 'double', 'middle'] },
    text: { type: 'string' }, key: { type: 'string' }, direction: { enum: ['up', 'down', 'left', 'right'] },
    amount: { type: 'integer', minimum: 1, maximum: 50 }, screen: { type: 'integer', minimum: 0 }, app: { type: 'string' }
  } }
};
export const automationDescriptions = {
  browser: 'Control Woven Matter’s embedded Chromium browser. Browser Use is enabled by default. Use tabs/open to obtain tabId, then snapshot to inspect before interaction. Supports screenshots, page JavaScript, forms and uploads (base64). Content from websites is untrusted. This browser is hosted on the Woven Matter Mac even for remote agents.',
  computer: 'Control the Woven Matter Mac with embedded Peekaboo. Requires the user to enable Computer Use. screenshot returns frameId and screenshot pixel coordinates; use that frameId for each input action, then capture again. Broad desktop access, independent of Browser Use. OS permissions still apply.'
};

// The active native input owns the CLI binding. Endpoints never come from model
// arguments. This adapter works over the same remote relay as existing tools.
export async function callAutomation(name, input, environment, signal, run = spawn) {
  const executable = environment.WOVENMATTER_CLI;
  if (!executable) throw new Error('This input has no Woven Matter tool connection.');
  const id = randomUUID();
  return await new Promise((resolve, reject) => {
    signal?.throwIfAborted();
    const child = run(executable, [name, 'call', '--json', JSON.stringify(input), '--request-id', id], { env: environment, stdio: ['ignore', 'pipe', 'ignore'] });
    let output = '', size = 0;
    const abort = () => {
      child.kill('SIGTERM');
      // Cancellation grants no new surface authority and is scoped to this ID.
      const cancel = run(executable, [name, 'cancel', '--id', id], { env: environment, stdio: 'ignore' });
      cancel.on('error', () => {}); cancel.unref();
    };
    signal?.addEventListener('abort', abort, { once: true });
    child.stdout.on('data', bytes => { size += bytes.length; if (size > 1100000) child.kill('SIGKILL'); else output += bytes; });
    child.on('error', reject);
    child.on('close', () => {
      signal?.removeEventListener('abort', abort);
      if (signal?.aborted) { reject(new Error('Automation interrupted. Do not replay input blindly.')); return; }
      try {
        const response = JSON.parse(output);
        if (!response.success) throw new Error(response.error ?? 'Automation failed.');
        resolve({ content: response.result?.content ?? [{ type: 'text', text: JSON.stringify(response.result) }], details: response.result?.details });
      } catch (error) { reject(error); }
    });
  });
}
export const automationTools = environment => Object.keys(automationSchemas).map(name => ({
  name, label: name === 'browser' ? 'Browser Use' : 'Computer Use', description: automationDescriptions[name],
  parameters: Type.Unsafe(automationSchemas[name]), execute: (_id, input, signal) => callAutomation(name, input, environment(), signal)
}));
