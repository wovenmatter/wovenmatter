import { appendFile, mkdir } from 'node:fs/promises'
import { join } from 'node:path'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const text = (value, limit) => typeof value === 'string' && value.length > 0 && value.length <= limit
const object = value => value && typeof value === 'object' && !Array.isArray(value)

/**
 * The seam between bot conversations and this machine's library copy.
 *
 * An adapter implements `writeBotEntries(botID, batch)`, where `batch` is the
 * runtime's `{bot: {id, name}, conversations, entries}`. It must upsert
 * entries by `(botID, entry.id)` and conversations by `(botID,
 * conversationId)`, so a resent batch changes nothing. The local library
 * daemon (`wovenmatter-library`) provides the production adapter; until the
 * Node server supervises it, batches go to a durable journal it can import.
 */
export function createBotConversationLibrary(adapter) {
  return {
    async writeBotEntries(botID, batch) {
      if (!uuid(botID)) throw fail(400, 'A bot UUID is required.')
      if (!object(batch) || !object(batch.bot) || String(batch.bot.id).toLowerCase() !== botID.toLowerCase() || !text(batch.bot.name, 256)) throw fail(400, 'The batch must name its bot.')
      const { conversations = [], entries = [] } = batch
      if (!Array.isArray(conversations) || conversations.length > 10000 || conversations.some(item => !object(item) || !text(item.conversationId, 128) || !['main', 'thread'].includes(item.kind))) throw fail(400, 'Invalid bot conversations.')
      if (!Array.isArray(entries) || entries.length > 200) throw fail(400, 'Send at most 200 conversation entries per batch.')
      const known = new Set(conversations.map(item => item.conversationId))
      for (const entry of entries) {
        if (!object(entry) || !text(entry.id, 128) || !known.has(entry.conversationId) || !['user', 'assistant'].includes(entry.role) || typeof entry.text !== 'string') throw fail(400, 'Every entry needs an id, a listed conversation, a role and text.')
      }
      if (Buffer.byteLength(JSON.stringify(batch)) > 8 * 1024 * 1024) throw fail(413, 'The conversation batch is too large.')
      return adapter.writeBotEntries(botID.toLowerCase(), { bot: { id: botID.toLowerCase(), name: batch.bot.name }, conversations, entries })
    },
  }
}

// Tests and hosts without durable storage.
export function createMemoryBotLibraryAdapter() {
  const bots = new Map()
  return {
    bot: botID => bots.get(botID),
    entries: botID => [...(bots.get(botID)?.entries.values() ?? [])],
    async writeBotEntries(botID, batch) {
      const stored = bots.get(botID) ?? { conversations: new Map(), entries: new Map() }; bots.set(botID, stored)
      stored.name = batch.bot.name
      for (const item of batch.conversations) stored.conversations.set(item.conversationId, structuredClone(item))
      for (const entry of batch.entries) stored.entries.set(entry.id, structuredClone(entry))
      return { conversations: batch.conversations.length, entries: batch.entries.length }
    },
  }
}

// One append-only JSON-lines file per bot under the Woven data root. Each line
// is `{ "receivedAt", "bot", "conversations", "entries" }`; importing replays
// lines in order, so a later line's upsert wins.
export function createJournalBotLibraryAdapter(directory) {
  const queues = new Map()
  return {
    directory,
    writeBotEntries(botID, batch) {
      const run = (queues.get(botID) ?? Promise.resolve()).then(async () => {
        await mkdir(directory, { recursive: true, mode: 0o700 })
        await appendFile(join(directory, botID + '.jsonl'), JSON.stringify({ receivedAt: new Date().toISOString(), ...batch }) + '\n', { mode: 0o600 })
        return { conversations: batch.conversations.length, entries: batch.entries.length }
      })
      queues.set(botID, run.catch(() => {}))
      return run
    },
  }
}
