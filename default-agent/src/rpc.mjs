import { createInterface } from 'node:readline';

// An error whose message is meant for the person, with an optional JSON-RPC code.
export class AgentError extends Error {
  constructor(message, code = -32000) { super(message); this.code = code; }
}

// Newline-delimited JSON-RPC 2.0 over a pair of streams, in both directions:
// the client's requests and notifications go to `handle`, and `request` asks
// the client something and waits for its reply.
export function connect({ input = process.stdin, output = process.stdout, handle }) {
  const pending = new Map();
  let nextID = 0;
  const write = message => new Promise(resolve => output.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n', resolve));
  const lines = createInterface({ input, crlfDelay: Infinity });
  const closed = new Promise(resolve => lines.once('close', resolve));
  lines.on('line', line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.method === undefined) {
      const waiter = pending.get(message.id);
      if (!waiter) return;
      pending.delete(message.id);
      if (message.error) waiter.reject(new AgentError(message.error.message ?? 'The client refused the request.', message.error.code));
      else waiter.resolve(message.result);
      return;
    }
    Promise.resolve().then(() => handle(message.method, message.params ?? {})).then(result => {
      if (message.id !== undefined) return write({ id: message.id, result: result ?? {} });
    }, error => {
      if (message.id === undefined) return;
      const known = error instanceof AgentError;
      return write({ id: message.id, error: { code: known ? error.code : -32000, message: known ? error.message : humanMessage(error) } });
    });
  });
  closed.then(() => { for (const waiter of pending.values()) waiter.reject(new AgentError('The client disconnected.')); pending.clear(); });
  return {
    closed,
    notify: (method, params) => write({ method, params }),
    request(method, params, { timeoutMs = 30000 } = {}) {
      const id = `agent-${++nextID}`;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new AgentError(`The client did not answer ${method}.`)); }, timeoutMs);
        pending.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
        void write({ id, method, params });
      });
    },
  };
}

// SDK and provider errors can carry long response bodies. Keep the first line, bounded.
export function humanMessage(error) {
  const text = String(error?.message ?? error ?? '').split('\n').find(line => line.trim()) ?? '';
  return text.trim().slice(0, 500) || 'Pi Durable could not complete this request.';
}
