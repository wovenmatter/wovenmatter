import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

// Pi Durable's stock summariser makes its model call with no entry of its
// own: its usage only joins the conversation's sums. Each such call is
// saved here, one row with its time, in the store's own file and outside
// any conversation, so the server counts it when it was made.

export const USAGE_TABLE = 'woven_usage';
const SUMMARIZER = 'You are a context summarization assistant.';
const ATTEMPTS = 3;

/** Whether a `completeSimple` request is the stock summariser's. */
export const isSummary = input => {
  const first = input?.messages?.[0];
  return first?.role === 'system' && typeof first.content === 'string' && first.content.startsWith(SUMMARIZER);
};

/** Saves one summariser call of `session` into the store at `path`; one that used nothing is not saved. */
export function saveSummaryUsage(path, session, reply, now = Date.now()) {
  const usage = reply?.usage ?? {};
  const count = value => (typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0);
  const row = {
    call: randomUUID(), session, at: typeof reply?.timestamp === 'number' ? reply.timestamp : now,
    provider: String(reply?.provider ?? ''), model: String(reply?.model ?? ''),
    input: count(usage.input), output: count(usage.output), cacheRead: count(usage.cacheRead), cacheWrite: count(usage.cacheWrite),
    cost: typeof usage.cost?.total === 'number' && Number.isFinite(usage.cost.total) ? usage.cost.total : 0,
  };
  if (!(row.input || row.output || row.cacheRead || row.cacheWrite || row.cost)) return;
  for (let attempt = 1; ; attempt += 1) {
    let database;
    try {
      database = new DatabaseSync(path, { timeout: 5000 });
      database.exec(`CREATE TABLE IF NOT EXISTS ${USAGE_TABLE} (
        call_id TEXT PRIMARY KEY, session TEXT NOT NULL, created_at INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
        input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cost REAL NOT NULL
      ) STRICT`);
      database.prepare(`INSERT OR IGNORE INTO ${USAGE_TABLE} VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(row.call, row.session, row.at, row.provider, row.model, row.input, row.output, row.cacheRead, row.cacheWrite, row.cost);
      return;
    } catch (error) {
      if (attempt >= ATTEMPTS) throw error;
    } finally {
      database?.close();
    }
  }
}

/** `models` with each stock summariser call's usage saved as it returns. */
export function countingSummaries(models, save) {
  return new Proxy(models, {
    get(target, key) {
      const value = Reflect.get(target, key, target);
      if (key !== 'completeSimple' || typeof value !== 'function') return typeof value === 'function' ? value.bind(target) : value;
      return async (model, input, options) => {
        const reply = await value.call(target, model, input, options);
        if (isSummary(input)) {
          try { save(reply); } catch { /* Its usage stays in the conversation's sums. */ }
        }
        return reply;
      };
    },
  });
}
