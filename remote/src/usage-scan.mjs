// Reads this host's own harness history and reports token counts per hour for the
// Usage page. Only counts and labels leave here: no prompts, responses or file paths.
// The parsing mirrors the desktop's LocalUsageTranscriptParser.
import { createHash } from 'node:crypto'
import { createReadStream, promises as fs } from 'node:fs'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
import { createInterface } from 'node:readline'
import { setImmediate as nextTurn } from 'node:timers/promises'
import { createZstdDecompress } from 'node:zlib'

const PAGE_SIZE = 2_000
const COMPRESSED = '.jsonl.zst'

const object = text => { try { const value = JSON.parse(text); return value && typeof value === 'object' ? value : null } catch { return null } }
const text = value => typeof value === 'string' && value.trim() ? value.trim() : null
const count = value => { const number = Math.trunc(Number(value)); return Number.isFinite(number) && number > 0 ? number : 0 }
const positiveNumber = value => { const number = Number(value); return value != null && Number.isFinite(number) && number >= 0 ? number : null }
const lastPath = value => { const path = text(value); return path ? basename(path) || path : null }
function seconds(value) {
  if (value == null) return null
  const number = Number(value)
  if (Number.isFinite(number)) return number > 10_000_000_000 ? number / 1_000 : number
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? null : parsed / 1_000
}
const sorted = value => Array.isArray(value) ? value.map(sorted)
  : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])])) : value

function event(fields, tokens) {
  const total = tokens.total || tokens.input + tokens.cached + tokens.created + tokens.output
  if (total <= 0) return null
  return { requests: 1, cost: null, dedupeKey: null, reasoningLevel: null, agent: null, workspace: null, ...fields, ...tokens, total }
}

export function parseClaudeLine(line) {
  if (!line.includes('"usage"')) return null
  const root = object(line)
  const usage = root?.message?.usage
  const timestamp = seconds(root?.timestamp), model = text(root?.message?.model)
  if (root?.type !== 'assistant' || !usage || timestamp == null || !model) return null
  const messageID = text(root.message.id), requestID = text(root.requestId ?? root.request_id)
  return event({
    timestamp, provider: 'claude', sessionID: text(root.sessionId ?? root.session_id) ?? '', model,
    billingProvider: 'Anthropic', billingRoute: 'Claude account', reasoningLevel: text(root.effort),
    harness: 'Claude Code', application: text(root.entrypoint) ?? 'Claude Code', agent: text(root.userType),
    workspace: lastPath(root.cwd), cost: positiveNumber(root.costUSD ?? root.cost_usd),
    dedupeKey: messageID || requestID ? `${messageID ?? ''}:${requestID ?? ''}` : null,
  }, { input: count(usage.input_tokens), cached: count(usage.cache_read_input_tokens), created: count(usage.cache_creation_input_tokens), output: count(usage.output_tokens), reasoning: 0, total: 0 })
}

export function codexParser() {
  const state = { model: '', reasoningLevel: null, sessionID: '', application: 'Codex CLI', workspace: null, signature: null, sawMetadata: false, suppressing: false, anchor: null }
  return line => {
    if (!line.includes('"token_count"') && !line.includes('"turn_context"') && !line.includes('"session_meta"')) return null
    const root = object(line), payload = root?.payload
    if (!payload || typeof payload !== 'object') return null
    if (root.type === 'session_meta') {
      if (state.sawMetadata) return null
      state.sawMetadata = true
      state.sessionID = text(payload.id ?? payload.session_id) ?? state.sessionID
      state.workspace = lastPath(payload.cwd)
      state.application = text(payload.originator) ?? text(payload.source) ?? 'Codex CLI'
      const forked = text(payload.forked_from_id) || text(payload.source?.subagent?.thread_spawn?.parent_thread_id)
      const anchor = seconds(root.timestamp ?? payload.timestamp)
      if (forked && anchor != null) { state.suppressing = true; state.anchor = anchor }
      return null
    }
    if (root.type === 'turn_context') {
      state.model = text(payload.model) ?? state.model
      state.reasoningLevel = text(payload.effort ?? payload.reasoning_effort) ?? state.reasoningLevel
      // Two distinct turns can legitimately consume identical counts.
      state.signature = null
      return null
    }
    const usage = payload.type === 'token_count' ? payload.info?.last_token_usage ?? payload.info?.lastTokenUsage : null
    const timestamp = seconds(root.timestamp)
    if (!usage || timestamp == null || !state.model) return null
    const signature = JSON.stringify(sorted(usage))
    if (signature === state.signature) return null
    state.signature = signature
    if (state.suppressing) {
      // A forked session starts with a burst of its parent's usage. Skip those copies.
      if (timestamp - state.anchor < 1) { state.anchor = timestamp; return null }
      state.suppressing = false
    }
    const reported = count(usage.input_tokens), cached = count(usage.cached_input_tokens), created = count(usage.cache_write_input_tokens), output = count(usage.output_tokens)
    return event({
      timestamp, provider: 'codex', sessionID: state.sessionID, model: state.model, billingProvider: 'OpenAI',
      billingRoute: 'Codex subscription', reasoningLevel: state.reasoningLevel, harness: 'Codex',
      application: state.application, workspace: state.workspace,
    }, { input: Math.max(0, reported - cached - created), cached, created, output, reasoning: Math.min(output, count(usage.reasoning_output_tokens)), total: count(usage.total_tokens) })
  }
}

export function parseGrokLine(line, number, summary = {}) {
  if (!line.includes('"usage"')) return []
  const root = object(line), params = root?.params, usage = params?.update?.usage
  const timestamp = seconds(root?.timestamp)
  if (!usage || timestamp == null) return []
  const sessionID = text(params.sessionId ?? params.session_id) ?? text(summary.info?.id) ?? ''
  const promptID = text(params.update.prompt_id ?? params.update.promptId) ?? `line-${number}`
  const models = usage.modelUsage ?? usage.model_usage
  const entries = models && Object.keys(models).length ? Object.entries(models) : [[text(summary.current_model_id) ?? 'Unknown Grok model', usage]]
  return entries.flatMap(([model, totals]) => {
    if (!totals || typeof totals !== 'object') return []
    const reported = count(totals.inputTokens ?? totals.input_tokens), cached = count(totals.cachedReadTokens ?? totals.cached_read_tokens)
    const created = count(totals.cacheCreationTokens ?? totals.cache_creation_tokens), output = count(totals.outputTokens ?? totals.output_tokens)
    const ticks = positiveNumber(totals.costUsdTicks ?? totals.cost_usd_ticks)
    const value = event({
      timestamp, provider: 'grok', sessionID, model, billingProvider: 'xAI', billingRoute: 'Grok account',
      reasoningLevel: text(summary.reasoning_effort), harness: 'Grok Build', application: 'Grok CLI',
      agent: text(summary.agent_name), workspace: lastPath(summary.info?.cwd), cost: ticks == null ? null : ticks / 1_000_000_000,
      dedupeKey: `${sessionID}:${promptID}:${model}:${timestamp}`,
    }, { input: Math.max(0, reported - cached - created), cached, created, output, reasoning: Math.min(output, count(totals.reasoningTokens ?? totals.reasoning_tokens)), total: count(totals.totalTokens ?? totals.total_tokens) })
    return value ? [value] : []
  })
}

function billingRoute(raw) {
  const provider = String(raw ?? '').toLowerCase()
  if (provider.includes('openai-codex') || provider === 'codex') return ['codex', 'OpenAI', 'Codex subscription']
  if (provider.includes('openrouter')) return ['openrouter', 'OpenRouter', 'OpenRouter API']
  if (provider === 'openai' || provider.includes('openai-api')) return ['codex', 'OpenAI', 'OpenAI API']
  if (provider.includes('anthropic') || provider.includes('claude')) return ['claude', 'Anthropic', 'Claude account']
  if (provider.includes('xai') || provider.includes('x-ai') || provider.includes('grok')) return ['grok', 'xAI', 'Grok account']
  if (provider.includes('cursor')) return ['cursor', 'Cursor', 'Cursor subscription']
  if (provider.includes('opencode')) return ['opencode-go', 'OpenCode Go', 'OpenCode Go subscription']
  const label = text(raw) ?? 'Unknown'
  return ['unknown', label, label]
}

export function parseOpenCodeRow(row) {
  const message = object(row.message), part = object(row.part)
  if (part?.type !== 'step-finish' || !part.tokens) return null
  const timestamp = seconds(message?.time?.completed ?? message?.time?.created)
  if (timestamp == null) return null
  const [provider, billingProvider, route] = billingRoute(message.providerID ?? message.provider_id)
  return event({
    timestamp, provider, sessionID: row.session, model: text(message.modelID ?? message.model_id) ?? 'Unknown model',
    billingProvider, billingRoute: route, reasoningLevel: text(message.variant), harness: 'OpenCode', application: 'OpenCode',
    agent: text(message.agent ?? message.mode), workspace: lastPath(row.directory), cost: positiveNumber(part.cost),
  }, { input: count(part.tokens.input), cached: count(part.tokens.cache?.read), created: count(part.tokens.cache?.write), output: count(part.tokens.output), reasoning: count(part.tokens.reasoning), total: count(part.tokens.total) })
}

/// One Pi session line (the Pi CLI, and the default agent before Pi Durable). The
/// identity matches the desktop's `parseHarness`.
export function piSessionParser(harness = 'Pi') {
  const state = { sessionID: '', model: '', provider: '', reasoningLevel: null, workspace: null }
  return (line, number) => {
    if (!line.includes('"usage"') && !line.includes('"model_change"') && !line.includes('"thinking_level_change"') && !line.includes('"session"')) return null
    const root = object(line)
    if (!root || typeof root.type !== 'string') return null
    if (root.type === 'session') {
      state.sessionID = text(root.id ?? root.session_id) ?? state.sessionID
      state.workspace = lastPath(root.cwd) ?? state.workspace
      return null
    }
    if (root.type === 'model_change') {
      state.model = text(root.modelId ?? root.model_id ?? root.model) ?? state.model
      state.provider = text(root.provider ?? root.providerId ?? root.provider_id) ?? state.provider
      return null
    }
    if (root.type === 'thinking_level_change') {
      state.reasoningLevel = text(root.thinkingLevel ?? root.thinking_level) ?? state.reasoningLevel
      return null
    }
    const message = root.type === 'message' ? root.message : null
    const usage = message?.role === 'assistant' ? message.usage : null
    const timestamp = seconds(root.timestamp ?? message?.timestamp)
    if (!usage || typeof usage !== 'object' || timestamp == null) return null
    const model = text(message.model ?? message.modelId ?? message.model_id) ?? state.model
    if (!model) return null
    const providerID = text(message.provider ?? message.providerId ?? message.provider_id) ?? state.provider
    const [provider, billingProvider, route] = billingRoute(providerID)
    const sessionID = text(state.sessionID) ?? text(root.sessionId ?? root.session_id) ?? 'Unknown'
    const responseID = text(message.responseId ?? message.response_id) ?? text(message.id ?? root.id)
    const cost = positiveNumber(usage.cost?.total ?? (typeof usage.cost === 'object' ? null : usage.cost) ?? usage.cost_usd)
    return event({
      timestamp, provider, sessionID, model, billingProvider, billingRoute: route,
      reasoningLevel: text(message.thinkingLevel ?? message.thinking_level) ?? state.reasoningLevel,
      harness, application: harness, workspace: state.workspace, cost,
      dedupeKey: responseID ? `${providerID}:${responseID}` : `${sessionID}:${number}:${timestamp}`,
    }, { input: count(usage.input ?? usage.input_tokens), cached: count(usage.cacheRead ?? usage.cache_read ?? usage.cached_input_tokens),
      created: count(usage.cacheWrite ?? usage.cache_write ?? usage.cache_creation_input_tokens), output: count(usage.output ?? usage.output_tokens),
      reasoning: count(usage.reasoning ?? usage.reasoning_tokens), total: count(usage.totalTokens ?? usage.total_tokens) })
  }
}

const PI_DURABLE = 'Pi Durable'

/// A Pi Durable reply's identity is its session, time, model and token total, the
/// same on the desktop, so a migrated store and its retained backup count once.
function piDurableEvent(message, session) {
  if (message?.role !== 'assistant' || !message.usage || typeof message.usage !== 'object') return null
  const milliseconds = Number(message.timestamp)
  if (!Number.isFinite(milliseconds)) return null
  const usage = message.usage, model = text(message.model) ?? 'Unknown model'
  const output = count(usage.output)
  const tokens = { input: count(usage.input), cached: count(usage.cacheRead), created: count(usage.cacheWrite), output,
    reasoning: Math.min(output, count(usage.reasoning)), total: count(usage.totalTokens) }
  const sum = tokens.input + tokens.cached + tokens.created + tokens.output
  const [provider, billingProvider, route] = billingRoute(message.provider ?? 'Unknown')
  return event({
    timestamp: milliseconds / 1_000, provider, sessionID: session.id, model, billingProvider, billingRoute: route,
    harness: PI_DURABLE, application: 'Woven Matter', agent: session.agent ?? null,
    dedupeKey: `pi-durable:${session.id}:${Math.trunc(milliseconds)}:${model}:${tokens.total || sum}`,
  }, tokens)
}

/// Replies in one session's entries (`{id, conversationId, model: [...]}`).
export function piDurableEvents(records, session) {
  const latest = new Map()
  for (const record of records) {
    const entry = typeof record === 'string' ? object(record) : record
    if (!entry || !Array.isArray(entry.model)) continue
    entry.model.forEach((message, index) => {
      const value = piDurableEvent(message, session)
      if (value) latest.set(`${entry.conversationId}:${entry.id}:${index}`, value)
    })
  }
  return [...latest.values()]
}

/// Entries in a pre-SQLite Pi Durable commit log (`durable/<session>/native/main.jsonl`).
export function legacyPiDurableEntries(lineText) {
  if (!lineText.includes('"usage"')) return []
  const commit = object(lineText)
  return Array.isArray(commit?.writes) ? commit.writes.filter(write => write?.type === 'entry' && write.value).map(write => write.value) : []
}

const SAFE_PREFIX = /^(wm_pi|pibot)_[0-9a-f]{32}_$/

/// Pi Durable stores in one SQLite database: the default agent's (`wm_pi_runtime_stores`)
/// and the bots runtime's (`pibot_bots`), each bot conversation its own session.
async function readPiDurableDatabase(path) {
  let database
  try {
    const { DatabaseSync } = await import('node:sqlite')
    database = new DatabaseSync(path, { readOnly: true })
    const has = name => !!database.prepare(`SELECT 1 FROM sqlite_master WHERE type='table' AND name=?`).get(name)
    const stores = []
    if (has('wm_pi_runtime_stores')) for (const row of database.prepare('SELECT session_id, schema_prefix FROM wm_pi_runtime_stores').all()) stores.push({ prefix: row.schema_prefix, session: { id: row.session_id }, bot: false })
    if (has('pibot_bots')) for (const row of database.prepare('SELECT id, name, schema_prefix FROM pibot_bots').all()) stores.push({ prefix: row.schema_prefix, session: { id: `bot:${row.id}`, agent: row.name ?? null }, bot: true })
    const events = []
    for (const store of stores) {
      if (!SAFE_PREFIX.test(store.prefix) || !has(store.prefix + 'entries')) continue
      const byConversation = new Map()
      for (const row of database.prepare(`SELECT conversation_id AS conversation, record FROM "${store.prefix}entries" WHERE instr(record, '"usage"') > 0 ORDER BY id`).iterate()) {
        const key = String(row.conversation)
        if (!byConversation.has(key)) byConversation.set(key, [])
        byConversation.get(key).push(row.record)
      }
      for (const [conversation, records] of byConversation) {
        const session = store.bot ? { id: `${store.session.id}:${conversation}`, agent: store.session.agent } : store.session
        for (const value of piDurableEvents(records, session)) events.push(value)
        await nextTurn()
      }
    }
    return events
  } catch { return [] } finally { try { database?.close() } catch {} }
}

/// Combines events in one hour that the Usage page cannot tell apart.
export function aggregate(events) {
  const groups = new Map()
  for (const value of events) {
    const hour = Math.floor(value.timestamp / 3_600)
    const key = JSON.stringify([hour, value.provider, value.sessionID, value.model, value.billingProvider, value.billingRoute, value.reasoningLevel, value.harness, value.application, value.agent, value.workspace, value.cost != null, value.dedupeKey])
    const group = groups.get(key)
    if (!group) { groups.set(key, { ...value }); continue }
    group.timestamp = Math.max(group.timestamp, value.timestamp)
    for (const field of ['input', 'cached', 'created', 'output', 'reasoning', 'total', 'requests']) group[field] += value[field]
    if (value.cost != null) group.cost = (group.cost ?? 0) + value.cost
  }
  return [...groups.values()]
}

export function toRecord(value) {
  const id = createHash('sha256').update(JSON.stringify([Math.floor(value.timestamp / 3_600), value.provider, value.sessionID, value.model, value.billingRoute, value.reasoningLevel, value.harness, value.application, value.agent, value.workspace, value.cost != null])).digest('hex').slice(0, 32)
  return {
    id, timestamp: value.timestamp, provider: value.provider, sessionID: value.sessionID, accountLabel: 'Unknown', model: value.model,
    billingProvider: value.billingProvider, billingRoute: value.billingRoute, reasoningLevel: value.reasoningLevel, harness: value.harness,
    application: value.application, agent: value.agent, workspace: value.workspace, inputTokens: value.input, cachedInputTokens: value.cached,
    cacheCreationTokens: value.created, outputTokens: value.output, reasoningTokens: value.reasoning, totalTokens: value.total,
    requestCount: value.requests, costUSD: value.cost, dedupeKey: null,
  }
}

async function* lines(path) {
  const stream = createReadStream(path)
  stream.on('error', () => {})
  const input = path.endsWith(COMPRESSED) ? stream.pipe(createZstdDecompress()) : stream
  yield* createInterface({ input, crlfDelay: Infinity })
}

async function walk(root, accept, found = []) {
  let entries
  try { entries = await fs.readdir(root, { withFileTypes: true }) } catch { return found }
  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue
    const path = join(root, entry.name)
    if (entry.isDirectory()) await walk(path, accept, found)
    else if (entry.isFile() && accept(path)) found.push(path)
  }
  return found
}

const isTranscript = path => path.endsWith('.jsonl') || path.endsWith(COMPRESSED)
/// When a session exists both plain and compressed, read it once.
const withoutCopies = paths => { const all = new Set(paths); return paths.filter(path => !path.endsWith(COMPRESSED) || !all.has(path.slice(0, -4))) }

async function readOpenCode(path) {
  let database
  try {
    const { DatabaseSync } = await import('node:sqlite')
    database = new DatabaseSync(path, { readOnly: true })
    const rows = database.prepare(`SELECT p.session_id AS session, m.data AS message, p.data AS part, s.directory AS directory
      FROM part p JOIN message m ON m.id=p.message_id LEFT JOIN session s ON s.id=p.session_id
      WHERE json_valid(p.data) AND json_valid(m.data) AND json_extract(p.data,'$.type')='step-finish'`).iterate()
    const events = []
    let read = 0
    for (const row of rows) {
      const parsed = parseOpenCodeRow(row)
      if (parsed) events.push(parsed)
      // This service also runs live work, so a large database can't hold it up.
      if (++read % 500 === 0) await nextTurn()
    }
    return events
  } catch { return [] } finally { try { database?.close() } catch {} }
}

export function createUsageScanner({ env = process.env, home = homedir(), refreshMilliseconds = 15 * 60_000, now = () => Date.now(),
  workspaceRoot = env.WOVENMATTER_WORKSPACE || join(home, '.woven-matter'), botsDatabase = null } = {}) {
  const agentDirectories = [...new Set([join(workspaceRoot, '.wovenmatter/default-agent'), join(home, '.wovenmatter/default-agent')])]
  const roots = {
    codex: join(env.CODEX_HOME || join(home, '.codex'), 'sessions'),
    codexArchived: join(env.CODEX_HOME || join(home, '.codex'), 'archived_sessions'),
    pi: join(home, '.pi/agent/sessions'),
    // The default agent's database (WOVEN_DEFAULT_AGENT_DATABASE for this server's
    // managed agent), its own directory's database, and the bots runtime's.
    piDurable: [...new Set([join(workspaceRoot, '.wovenmatter/workspace.sqlite'), ...agentDirectories.map(directory => join(directory, 'workspace.sqlite')),
      ...(botsDatabase ? [botsDatabase] : [])])],
    claude: join(env.CLAUDE_CONFIG_DIR || join(home, '.claude'), 'projects'),
    grok: join(env.GROK_HOME || join(home, '.grok'), 'sessions'),
    opencode: join(home, '.local/share/opencode/opencode.db'),
  }
  const cache = new Map()
  let snapshot = null, scannedAt = 0, running = null

  // Finished sessions don't change, so each file is only read again if it did.
  async function cached(path, read) {
    const info = await fs.stat(path).catch(() => null)
    if (!info) return []
    const stamp = `${info.mtimeMs}:${info.size}`
    const held = cache.get(path)
    if (held?.stamp === stamp) return held.events
    const events = await read(path).catch(() => [])
    cache.set(path, { stamp, events })
    return events
  }

  // A database changes in its WAL first, so its stamp includes the WAL.
  async function cachedDatabase(path, read) {
    const main = await fs.stat(path).catch(() => null)
    if (!main) return []
    const wal = await fs.stat(path + '-wal').catch(() => null)
    const stamp = `${main.mtimeMs}:${main.size}:${wal?.mtimeMs ?? 0}:${wal?.size ?? 0}`
    const held = cache.get(path)
    if (held?.stamp === stamp) return held.events
    const events = await read(path).catch(() => [])
    cache.set(path, { stamp, events })
    return events
  }

  async function readFile(path, parse) {
    const events = []
    let number = 0
    for await (const line of lines(path)) {
      number += 1
      const parsed = parse(line, number)
      if (Array.isArray(parsed)) events.push(...parsed)
      else if (parsed) events.push(parsed)
    }
    return events
  }

  async function scan() {
    const events = []
    // One source can hold more rows than a call can take as arguments.
    const add = found => { for (const value of found) events.push(value) }
    // An archived Codex chat moves to archived_sessions under the same file name.
    const rollouts = new Map()
    for (const path of withoutCopies([...await walk(roots.codex, isTranscript), ...await walk(roots.codexArchived, isTranscript)])) {
      const name = basename(path).replace(/\.zst$/, '')
      if (!rollouts.has(name)) rollouts.set(name, path)
    }
    for (const path of rollouts.values()) {
      // Codex writes an event per turn, so hold each file's hourly totals.
      add(await cached(path, async file => { const parse = codexParser(); return aggregate(await readFile(file, line => parse(line))) }))
    }
    for (const path of withoutCopies(await walk(roots.claude, isTranscript))) add(await cached(path, file => readFile(file, parseClaudeLine)))
    for (const path of await walk(roots.grok, file => basename(file) === 'updates.jsonl')) {
      add(await cached(path, async file => {
        const summary = object(await fs.readFile(join(file, '../summary.json'), 'utf8').catch(() => '')) ?? {}
        return readFile(file, (line, number) => parseGrokLine(line, number, summary))
      }))
    }
    add(await cached(roots.opencode, readOpenCode))
    for (const path of await walk(roots.pi, file => file.endsWith('.jsonl'))) add(await cached(path, file => readFile(file, piSessionParser('Pi'))))
    for (const directory of agentDirectories) {
      for (const path of await walk(join(directory, 'sessions'), file => file.endsWith('.jsonl'))) {
        add(await cached(path, async file => (await readFile(file, piSessionParser('Pi'))).map(value => {
          const milliseconds = Math.round(value.timestamp * 1_000)
          return { ...value, harness: PI_DURABLE, application: 'Woven Matter', dedupeKey: `pi-durable:${value.sessionID}:${milliseconds}:${value.model}:${value.total}` }
        })))
      }
      for (const path of await walk(join(directory, 'durable'), file => basename(file) === 'main.jsonl' && basename(join(file, '..')) === 'native')) {
        const session = { id: basename(join(path, '../..')) }
        add(await cached(path, async file => piDurableEvents(await readFile(file, legacyPiDurableEntries), session)))
      }
    }
    for (const path of roots.piDurable) add(await cachedDatabase(path, readPiDurableDatabase))
    // A resumed transcript repeats earlier messages, which must only count once.
    const seen = new Set()
    const unique = events.filter(value => {
      if (!value.dedupeKey) return true
      const key = `${value.provider}:${value.dedupeKey}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    }).map(value => ({ ...value, dedupeKey: null }))
    snapshot = aggregate(unique).map(toRecord).sort((a, b) => a.timestamp - b.timestamp)
    scannedAt = now()
  }

  function start() {
    // A failed scan keeps what was last read. With nothing read yet it stays "scanning",
    // because an empty report would look like a host with no usage.
    running ??= scan().catch(() => { scannedAt = now() }).finally(() => { running = null })
    return running
  }

  return {
    start,
    async page({ since = 0, offset = 0 } = {}) {
      const generatedAt = now() / 1_000
      if (snapshot === null) {
        // The first read can outlast a request, so report progress and let the client ask again.
        start()
        return { state: 'scanning', generatedAt, records: [], hasMore: false, nextOffset: 0 }
      }
      if (now() - scannedAt >= refreshMilliseconds) start()
      const records = snapshot.filter(record => record.timestamp >= since)
      const start_ = Math.max(0, offset), page = records.slice(start_, start_ + PAGE_SIZE)
      return { state: 'ready', generatedAt, records: page, hasMore: start_ + page.length < records.length, nextOffset: start_ + page.length }
    },
  }
}
