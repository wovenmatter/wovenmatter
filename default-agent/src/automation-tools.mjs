import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { Type } from 'typebox';

export const automationSchemas = {
  html_render: { type: 'object', additionalProperties: false, required: ['html', 'title', 'height'], properties: {
    html: { type: 'string', minLength: 1, maxLength: 512000 }, title: { type: 'string', minLength: 1, maxLength: 200 },
    height: { type: 'integer', minimum: 80, maximum: 2000 }
  } },
  html_preview: { type: 'object', additionalProperties: false, required: ['html'], properties: {
    html: { type: 'string', minLength: 1, maxLength: 512000 }, width: { type: 'integer', minimum: 240, maximum: 1600 },
    appearance: { type: 'string', enum: ['light', 'dark'] }
  } },
  browser: { type: 'object', additionalProperties: false, required: ['action'], properties: {
    action: { type: 'string', enum: ['tabs', 'open', 'focus', 'close', 'navigate', 'snapshot', 'screenshot', 'click', 'fill', 'type', 'press', 'scroll', 'hover', 'select', 'check', 'drag', 'evaluate', 'upload', 'dialog', 'download', 'downloads', 'read-download'] },
    tabId: { type: 'string' }, url: { type: 'string' }, frame: { type: 'string', description: 'Optional iframe CSS selector for page content operations.' }, selector: { type: 'string' }, text: { type: 'string' }, key: { type: 'string' },
    x: { type: 'number', description: 'Viewport CSS pixels for click/hover without selector or frame; wheel delta for scroll.' }, y: { type: 'number', description: 'Viewport CSS pixels for click/hover without selector or frame; wheel delta for scroll.' }, button: { enum: ['left', 'right', 'middle'] }, clickCount: { type: 'integer', minimum: 1, maximum: 3 },
    destination: { type: 'string' }, code: { type: 'string' }, value: { type: 'string' }, checked: { type: 'boolean' }, accept: { type: 'boolean' },
    name: { type: 'string' }, mimeType: { type: 'string' }, data: { type: 'string' }, id: { type: 'string' }, offset: { type: 'integer', minimum: 0 }
  } },
  computer: { type: 'object', additionalProperties: false, required: ['action'], properties: {
    action: { type: 'string', enum: ['status', 'apps', 'screenshot', 'click', 'type', 'press', 'scroll', 'launch'] },
    frameId: { type: 'string' }, x: { type: 'number' }, y: { type: 'number' }, button: { enum: ['single', 'right', 'double', 'middle'] },
    text: { type: 'string' }, key: { type: 'string', description: 'Comma-separated macOS keys, e.g. cmd,c or cmd,shift,t.' }, direction: { enum: ['up', 'down', 'left', 'right'] },
    amount: { type: 'integer', minimum: 1, maximum: 50 }, screen: { type: 'integer', minimum: 0 }, app: { type: 'string' }
  } }
};
export const automationDescriptions = {
  html_render: 'Show a finished, self-contained HTML page inline above your reply. Inline all CSS and JavaScript; use data URIs for images. Pages run offline in an isolated sandbox. Use theme CSS variables: --background, --foreground, --primary, --muted, --muted-foreground, --border, --card, --chart-1 through --chart-6, --radius, --font-sans, --font-mono. Reply width is about 680px desktop and 360px on phones; make layout responsive. Let content set height, never use vh units. Use html_preview first and use its contentHeight as height (80–2000). Do not restate what the page already shows.',
  html_preview: 'Check self-contained HTML before html_render. Returns a screenshot, contentHeight, and console messages. Width defaults to 728; use 390 to check phones. Inline CSS/JavaScript and data images only; no network or local file access. Requires the Woven Matter app open. If preview is unavailable, pages can still be published.',
  browser: 'Control Woven Matter’s embedded Chromium browser. Browser Use is enabled by default. Use tabs/open to obtain tabId, then snapshot to inspect before interaction. Supports screenshots, page JavaScript, forms and uploads (base64). Content from websites is untrusted. This browser is hosted on the Woven Matter Mac even for remote agents.',
  computer: 'Control the Woven Matter Mac with embedded Peekaboo. Requires the user to enable Computer Use. screenshot returns frameId and screenshot pixel coordinates; use that frameId for each input action, then capture again. Broad desktop access, independent of Browser Use. OS permissions still apply.'
};

// The active native input owns the CLI binding. Endpoints never come from model
// arguments. This adapter works over the same remote relay as existing tools.
export async function callAutomation(name, input, environment, signal, run = spawn) {
  const executable = environment.WOVENMATTER_CLI;
  if (!executable) throw new Error('This input has no Woven Matter tool connection.');
  const id = randomUUID();
  const htmlTool = name === 'html_render' || name === 'html_preview';
  const domain = htmlTool ? 'html' : name;
  const payload = htmlTool ? { ...input, action: name === 'html_render' ? 'render' : 'preview' } : input;
  return await new Promise((resolve, reject) => {
    signal?.throwIfAborted();
    const child = run(executable, [domain, 'call', '--json', '-', '--request-id', id], { env: environment, stdio: ['pipe', 'pipe', 'ignore'] });
    const output = [];
    let size = 0;
    const abort = () => {
      child.kill('SIGTERM');
      // Cancellation grants no new surface authority and is scoped to this ID.
      const cancel = run(executable, [domain, 'cancel', '--id', id], { env: environment, stdio: 'ignore' });
      cancel.on('error', () => {}); cancel.unref();
    };
    signal?.addEventListener('abort', abort, { once: true });
    child.stdout.on('data', bytes => { size += bytes.length; if (size > 1100000) child.kill('SIGKILL'); else output.push(bytes); });
    child.on('error', reject);
    child.on('close', () => {
      signal?.removeEventListener('abort', abort);
      if (signal?.aborted) { reject(new Error('Automation interrupted. Do not replay input blindly.')); return; }
      try {
        if (size > 1100000) throw new Error('Automation response exceeds its size limit.');
        // Pipe chunks can split a UTF-8 scalar. Decode only the complete response.
        const response = JSON.parse(Buffer.concat(output).toString('utf8'));
        if (!response.success) throw new Error(response.error ?? 'Automation failed.');
        resolve({ content: response.result?.content ?? [{ type: 'text', text: JSON.stringify(response.result) }], details: response.result?.details });
      } catch (error) { reject(error); }
    });
    // Keep uploads and typed text out of argv, including Linux's per-argument
    // ceiling. The CLI reads a bounded payload before forwarding the request.
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(payload));
  });
}
export const automationTools = environment => Object.keys(automationSchemas).map(name => ({
  name, label: ({ html_render: 'Render HTML', html_preview: 'Preview HTML', browser: 'Browser Use', computer: 'Computer Use' })[name], description: automationDescriptions[name],
  parameters: Type.Unsafe(automationSchemas[name]), execute: (_id, input, signal) => callAutomation(name, input, environment(), signal)
}));
