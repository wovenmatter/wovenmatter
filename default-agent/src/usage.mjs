import { randomUUID } from 'node:crypto';

// Pi Durable's stock summariser makes its model call with no entry of its
// own: its usage only joins the conversation's sums. Each such call is
// saved here, one row with its time, in the store's own file and outside
// any conversation, so the server counts it when it was made. It is
// written on Pi Durable's own connection, queued behind whatever that
// connection is doing, so the agent never waits for it.

export const USAGE_TABLE = 'woven_usage';
const SUMMARIZER = 'You are a context summarization assistant.';

/** Whether a `completeSimple` request is the stock summariser's. */
export const isSummary = input => {
  const first = input?.messages?.[0];
  return first?.role === 'system' && typeof first.content === 'string' && first.content.startsWith(SUMMARIZER);
};

const BUSY = 5;
const ATTEMPTS = 4;

/** Writes a line about the summariser's usage where the agent's own messages go. */
const report = line => process.stderr.write(`pi-durable usage: ${line}\n`);

/**
 * Makes the table the summariser's calls are saved in, on `database`. Returns whether it is there; a session whose
 * table could not be made starts anyway, without saving them.
 */
export async function createUsageTable(database, log = report) {
  try {
    await database.exec(`CREATE TABLE IF NOT EXISTS ${USAGE_TABLE} (
      call_id TEXT PRIMARY KEY, session TEXT NOT NULL, created_at INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
      input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cost REAL NOT NULL
    ) STRICT`);
    return true;
  } catch (error) {
    log(`summary calls are not saved for this session: ${error?.message ?? error}`);
    return false;
  }
}

/**
 * Saves one summariser call of `session` on `database`; one that used nothing is not saved. A store busy elsewhere
 * is tried again a few times, under the same call identifier so no retry saves it twice; a save that still fails is
 * reported.
 */
export async function saveSummaryUsage(database, session, reply, { now = Date.now(), log = report, wait = 50 } = {}) {
  const usage = reply?.usage ?? {};
  const count = value => (typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0);
  const cost = typeof usage.cost?.total === 'number' && Number.isFinite(usage.cost.total) ? usage.cost.total : 0;
  const amounts = [count(usage.input), count(usage.output), count(usage.cacheRead), count(usage.cacheWrite), cost];
  if (!amounts.some(Boolean)) return;
  const row = [randomUUID(), session, typeof reply?.timestamp === 'number' ? reply.timestamp : now,
    String(reply?.provider ?? ''), String(reply?.model ?? ''), ...amounts];
  for (let attempt = 1; ; attempt += 1) {
    try {
      await database.run(`INSERT OR IGNORE INTO ${USAGE_TABLE} VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, ...row);
      return;
    } catch (error) {
      if ((error?.errcode & 0xff) === BUSY && attempt < ATTEMPTS) {
        await new Promise(resolve => setTimeout(resolve, wait * attempt));
        continue;
      }
      log(`a summary call's usage was not saved: ${error?.message ?? error}`);
      return;
    }
  }
}

/**
 * `models` with each stock summariser call's usage saved once it has returned; a call that failed or was stopped
 * saves nothing. The save is queued, not waited for.
 */
export function countingSummaries(models, save) {
  return new Proxy(models, {
    get(target, key) {
      const value = Reflect.get(target, key, target);
      if (key !== 'completeSimple' || typeof value !== 'function') return typeof value === 'function' ? value.bind(target) : value;
      return async (model, input, options) => {
        const reply = await value.call(target, model, input, options);
        const finished = reply && reply.stopReason !== 'aborted' && reply.stopReason !== 'error' && !options?.signal?.aborted;
        if (finished && isSummary(input)) {
          try {
            void Promise.resolve(save(reply)).catch(() => {});
          } catch { /* Its usage stays in the conversation's sums. */ }
        }
        return reply;
      };
    },
  });
}
