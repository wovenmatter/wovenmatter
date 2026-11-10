import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { zstdCompressSync } from 'node:zlib'
import { aggregate, codexParser, createUsageScanner, parseClaudeLine, parseGrokLine, parseOpenCodeRow, toRecord } from '../src/usage-scan.mjs'

const codexLines = (session, secret = 'secret prompt text') => [
  JSON.stringify({ type: 'session_meta', timestamp: '2026-02-04T12:00:00Z', payload: { id: session, cwd: '/home/me/private/project', originator: 'codex_cli' } }),
  JSON.stringify({ type: 'response_item', payload: { content: secret } }),
  JSON.stringify({ type: 'turn_context', payload: { model: 'gpt-5.5', effort: 'high' } }),
  JSON.stringify({ type: 'event_msg', timestamp: '2026-02-04T12:01:00Z', payload: { type: 'token_count', info: { last_token_usage: { input_tokens: 100, cached_input_tokens: 40, output_tokens: 10, reasoning_output_tokens: 3, total_tokens: 110 } } } }),
  // A repeated notification inside one turn only counts once.
  JSON.stringify({ type: 'event_msg', timestamp: '2026-02-04T12:01:01Z', payload: { type: 'token_count', info: { last_token_usage: { input_tokens: 100, cached_input_tokens: 40, output_tokens: 10, reasoning_output_tokens: 3, total_tokens: 110 } } } }),
].join('\n') + '\n'

const claudeLine = (id, session = 'claude-session') => JSON.stringify({ type: 'assistant', timestamp: '2026-10-01T10:00:00Z', sessionId: session, requestId: `request-${id}`, cwd: '/home/me/secret/app',
  message: { id: `message-${id}`, model: 'claude-opus-4-8', content: 'do not send this', usage: { input_tokens: 5, cache_read_input_tokens: 7, cache_creation_input_tokens: 2, output_tokens: 3 } } })

const settle = async scanner => { for (let index = 0; index < 500; index += 1) { const page = await scanner.page(); if (page.state === 'ready') return page; await new Promise(resolve => setTimeout(resolve, 5)) } throw new Error('scan did not finish') }

test('codex parsing matches the desktop rules', () => {
  const parse = codexParser()
  const events = codexLines('session').split('\n').filter(Boolean).map(line => parse(line)).filter(Boolean)
  assert.equal(events.length, 1)
  const [event] = events
  assert.equal(event.input, 60)
  assert.equal(event.cached, 40)
  assert.equal(event.total, 110)
  assert.equal(event.reasoning, 3)
  assert.equal(event.workspace, 'project')
  assert.equal(event.model, 'gpt-5.5')
  assert.equal(event.application, 'codex_cli')
})

test('forked codex sessions skip the copied burst of their parent usage', () => {
  const parse = codexParser()
  parse(JSON.stringify({ type: 'session_meta', timestamp: '2026-02-04T12:00:00.000Z', payload: { id: 'fork', forked_from_id: 'parent' } }))
  parse(JSON.stringify({ type: 'turn_context', payload: { model: 'gpt-5.5' } }))
  const usage = input => JSON.stringify({ type: 'event_msg', timestamp: input.at, payload: { type: 'token_count', info: { last_token_usage: { input_tokens: input.tokens } } } })
  assert.equal(parse(usage({ at: '2026-02-04T12:00:00.500Z', tokens: 9 })), null)
  assert.equal(parse(usage({ at: '2026-02-04T12:00:05.000Z', tokens: 11 })).input, 11)
})

test('claude, grok and opencode lines map to counts', () => {
  const claude = parseClaudeLine(claudeLine('a'))
  assert.equal(claude.total, 17)
  assert.equal(claude.dedupeKey, 'message-a:request-a')
  assert.equal(parseClaudeLine('{"type":"user","message":{"usage":{}}}'), null)
  const [grok] = parseGrokLine(JSON.stringify({ timestamp: '2026-10-01T10:00:00Z', params: { sessionId: 's', update: { prompt_id: 'p', usage: { modelUsage: { 'grok-5': { inputTokens: 10, cachedReadTokens: 4, outputTokens: 2, totalTokens: 12, costUsdTicks: 2_000_000_000 } } } } } }), 1)
  assert.equal(grok.input, 6)
  assert.equal(grok.cost, 2)
  const opencode = parseOpenCodeRow({ session: 's', directory: '/home/me/app', message: JSON.stringify({ providerID: 'opencode-go', modelID: 'kimi', time: { completed: 1_790_000_000_000 } }), part: JSON.stringify({ type: 'step-finish', cost: 0.5, tokens: { input: 1, output: 2, cache: { read: 3 } } }) })
  assert.equal(opencode.provider, 'opencode-go')
  assert.equal(opencode.total, 6)
  assert.equal(opencode.workspace, 'app')
})

test('events in one hour combine without changing totals, and costs stay apart', () => {
  const base = { provider: 'codex', sessionID: 's', model: 'm', billingProvider: 'p', billingRoute: 'r', reasoningLevel: null, harness: 'h', application: 'a', agent: null, workspace: null, dedupeKey: null, input: 1, cached: 2, created: 3, output: 4, reasoning: 0, total: 10, requests: 1, cost: null }
  const combined = aggregate([{ ...base, timestamp: 3_600 }, { ...base, timestamp: 3_700 }, { ...base, timestamp: 7_300 }, { ...base, timestamp: 3_800, cost: 1 }])
  assert.equal(combined.length, 3)
  const hour = combined.find(value => value.timestamp === 3_700)
  assert.equal(hour.total, 20)
  assert.equal(hour.requests, 2)
})

test('a scan reads compressed sessions, dedupes resumed copies, pages, and returns counts only', async () => {
  const home = mkdtempSync(join(tmpdir(), 'usage-scan-'))
  try {
    const codex = join(home, '.codex/sessions/2026/02/04')
    mkdirSync(codex, { recursive: true })
    writeFileSync(join(codex, 'plain.jsonl'), codexLines('plain'))
    writeFileSync(join(codex, 'archived.jsonl.zst'), zstdCompressSync(Buffer.from(codexLines('archived'))))
    // The same session in both forms is only read once.
    writeFileSync(join(codex, 'both.jsonl'), codexLines('both'))
    writeFileSync(join(codex, 'both.jsonl.zst'), zstdCompressSync(Buffer.from(codexLines('both'))))
    const claude = join(home, '.claude/projects/app')
    mkdirSync(claude, { recursive: true })
    writeFileSync(join(claude, 'one.jsonl'), claudeLine('a') + '\n')
    writeFileSync(join(claude, 'resumed.jsonl'), claudeLine('a') + '\n' + claudeLine('b') + '\n')

    const scanner = createUsageScanner({ env: {}, home })
    const first = await scanner.page()
    assert.equal(first.state, 'scanning')
    const page = await settle(scanner)
    assert.deepEqual(page.records.filter(record => record.provider === 'codex').map(record => record.sessionID).sort(), ['archived', 'both', 'plain'])
    const claudeRecords = page.records.filter(record => record.provider === 'claude')
    assert.equal(claudeRecords.length, 1)
    assert.equal(claudeRecords[0].totalTokens, 34)
    assert.equal(claudeRecords[0].requestCount, 2)
    const wire = JSON.stringify(page)
    for (const secret of ['secret prompt text', 'do not send this', '/home/me', home]) assert.ok(!wire.includes(secret), secret)

    const later = (await scanner.page({ since: Date.parse('2026-09-01') / 1_000 })).records
    assert.ok(later.every(record => record.provider === 'claude'))
    const paged = await scanner.page({ offset: 1 })
    assert.equal(paged.nextOffset, page.records.length)
  } finally { rmSync(home, { recursive: true, force: true }) }
})

test('a changed file is read again and an unchanged one is reused', async () => {
  const home = mkdtempSync(join(tmpdir(), 'usage-scan-'))
  try {
    const codex = join(home, '.codex/sessions')
    mkdirSync(codex, { recursive: true })
    const file = join(codex, 'a.jsonl')
    writeFileSync(file, codexLines('a'))
    let clock = 1_000_000
    const scanner = createUsageScanner({ env: {}, home, refreshMilliseconds: 10, now: () => clock })
    await scanner.start()
    assert.equal((await scanner.page()).records[0].totalTokens, 110)
    writeFileSync(file, codexLines('a') + JSON.stringify({ type: 'turn_context', payload: { model: 'gpt-5.5' } }) + '\n' + JSON.stringify({ type: 'event_msg', timestamp: '2026-02-04T12:02:00Z', payload: { type: 'token_count', info: { last_token_usage: { input_tokens: 5, total_tokens: 5 } } } }) + '\n')
    utimesSync(file, new Date(), new Date(Date.now() + 5_000))
    clock += 100
    await scanner.start()
    assert.equal((await scanner.page()).records[0].totalTokens, 115)
  } finally { rmSync(home, { recursive: true, force: true }) }
})

test('a very large OpenCode database reads without overflowing a call', async () => {
  const home = mkdtempSync(join(tmpdir(), 'usage-scan-'))
  try {
    const directory = join(home, '.local/share/opencode')
    mkdirSync(directory, { recursive: true })
    const { DatabaseSync } = await import('node:sqlite')
    const database = new DatabaseSync(join(directory, 'opencode.db'))
    database.exec(`CREATE TABLE session(id TEXT, directory TEXT); CREATE TABLE message(id TEXT, data TEXT); CREATE TABLE part(session_id TEXT, message_id TEXT, data TEXT);
      INSERT INTO session VALUES ('s', '/srv/project');
      INSERT INTO message VALUES ('m', '${JSON.stringify({ providerID: 'opencode', modelID: 'm', time: { completed: 1_790_000_000_000 } })}');
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
      INSERT INTO part SELECT 's', 'm', '${JSON.stringify({ type: 'step-finish', tokens: { input: 1 } })}' FROM n;`)
    database.close()
    const scanner = createUsageScanner({ env: {}, home })
    await scanner.start()
    const { records } = await scanner.page()
    assert.equal(records.length, 1)
    assert.equal(records[0].requestCount, 200_000)
  } finally { rmSync(home, { recursive: true, force: true }) }
})

test('toRecord uses the field names the desktop decodes', () => {
  const record = toRecord({ timestamp: 3_700, provider: 'codex', sessionID: 's', model: 'm', billingProvider: 'p', billingRoute: 'r', reasoningLevel: null, harness: 'h', application: 'a', agent: null, workspace: null, input: 1, cached: 2, created: 3, output: 4, reasoning: 0, total: 10, requests: 1, cost: null })
  for (const key of ['id', 'timestamp', 'provider', 'sessionID', 'accountLabel', 'model', 'billingProvider', 'billingRoute', 'harness', 'application', 'inputTokens', 'cachedInputTokens', 'cacheCreationTokens', 'outputTokens', 'reasoningTokens', 'totalTokens', 'requestCount']) assert.ok(key in record, key)
})

const piReply = (timestamp, input, { provider = 'openai-codex', model = 'gpt-5.5' } = {}) =>
  ({ role: 'assistant', provider, model, timestamp, content: 'private reply', usage: { input, output: 2, cacheRead: 3, cacheWrite: 0, reasoning: 1, totalTokens: input + 5 } })
const piEntry = (id, conversationId, ...messages) => ({ id, conversationId, kind: 'pi.assistant', model: [{ role: 'user', content: 'private question' }, ...messages] })

async function piDurableDatabase(path, { stores = [], bots = [] }) {
  const { DatabaseSync } = await import('node:sqlite')
  const database = new DatabaseSync(path)
  if (stores.length) database.exec('CREATE TABLE wm_pi_runtime_stores (store_id TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE, schema_prefix TEXT NOT NULL UNIQUE, format INTEGER NOT NULL, activated_at TEXT NOT NULL)')
  if (bots.length) database.exec('CREATE TABLE pibot_bots (id TEXT PRIMARY KEY, name TEXT NOT NULL, schema_prefix TEXT NOT NULL UNIQUE)')
  const entries = (prefix, rows) => {
    database.exec(`CREATE TABLE "${prefix}entries" (id INTEGER PRIMARY KEY, conversation_id INTEGER NOT NULL, head INTEGER, commit_seq INTEGER NOT NULL, record TEXT NOT NULL)`)
    for (const entry of rows) database.prepare(`INSERT INTO "${prefix}entries" VALUES (?, ?, NULL, 1, ?)`).run(entry.id, entry.conversationId, JSON.stringify(entry))
  }
  for (const store of stores) {
    database.prepare('INSERT INTO wm_pi_runtime_stores VALUES (?, ?, ?, 1, ?)').run(store.session, store.session, store.prefix, '2026-10-28T00:00:00Z')
    entries(store.prefix, store.entries)
  }
  for (const bot of bots) {
    database.prepare('INSERT INTO pibot_bots VALUES (?, ?, ?)').run(bot.id, bot.name, bot.prefix)
    entries(bot.prefix, bot.entries)
  }
  database.close()
}

test('a host scan counts archived Codex chats once, Pi sessions, Pi Durable in every format, and bots', async () => {
  const home = mkdtempSync(join(tmpdir(), 'usage-scan-pi-'))
  try {
    const sessions = join(home, '.codex/sessions/2026/02/04'), archived = join(home, '.codex/archived_sessions')
    mkdirSync(sessions, { recursive: true }); mkdirSync(archived, { recursive: true })
    // The same rollout in both places (a copy left behind) counts once; an archived-only chat counts.
    writeFileSync(join(sessions, 'rollout-a.jsonl'), codexLines('a'))
    writeFileSync(join(archived, 'rollout-a.jsonl'), codexLines('a'))
    writeFileSync(join(archived, 'rollout-b.jsonl'), codexLines('b'))

    const pi = join(home, '.pi/agent/sessions/--home-me--')
    mkdirSync(pi, { recursive: true })
    writeFileSync(join(pi, 'session.jsonl'), [
      JSON.stringify({ type: 'session', id: 'pi-cli', cwd: '/home/me/project', timestamp: '2026-10-01T10:00:00Z' }),
      JSON.stringify({ type: 'model_change', provider: 'anthropic', modelId: 'claude-opus-4-8' }),
      JSON.stringify({ type: 'message', timestamp: '2026-10-01T10:01:00Z', message: { role: 'assistant', id: 'r1', content: 'private', usage: { input: 10, output: 4, cacheRead: 6, totalTokens: 20 } } }),
    ].join('\n') + '\n')

    const workspace = join(home, '.woven-matter'), agent = join(workspace, '.wovenmatter/default-agent')
    const migrated = 1_790_000_000_000
    // A session that moved into SQLite keeps its commit log as a backup: one reply, counted once.
    mkdirSync(join(agent, 'durable/session-1/native'), { recursive: true })
    writeFileSync(join(agent, 'durable/session-1/native/main.jsonl'), JSON.stringify({ format: 1, seq: 1, type: 'commit', writes: [
      { type: 'entry', value: piEntry(2, 1, piReply(migrated, 100)) }, { type: 'task', value: { id: 3 } }] }) + '\n')
    // A session only in its commit log.
    mkdirSync(join(agent, 'durable/session-2/native'), { recursive: true })
    writeFileSync(join(agent, 'durable/session-2/native/main.jsonl'), JSON.stringify({ format: 1, seq: 1, type: 'commit', writes: [
      { type: 'entry', value: piEntry(2, 1, piReply(migrated + 60_000, 40)) }] }) + '\n')
    // A session from before Pi Durable, in Pi's session format.
    mkdirSync(join(agent, 'sessions'), { recursive: true })
    writeFileSync(join(agent, 'sessions/old.jsonl'), [
      JSON.stringify({ type: 'session', id: 'session-old', cwd: '/home/me' }),
      JSON.stringify({ type: 'message', timestamp: '2026-09-22T10:00:00Z', message: { role: 'assistant', provider: 'xai', model: 'grok-5', usage: { input: 7, output: 1, totalTokens: 8 } } }),
    ].join('\n') + '\n')
    await piDurableDatabase(join(workspace, '.wovenmatter/workspace.sqlite'), { stores: [
      { session: 'session-1', prefix: 'wm_pi_' + 'a'.repeat(32) + '_', entries: [piEntry(2, 1, piReply(migrated, 100))] },
    ] })
    const botsDatabase = join(home, 'bots.sqlite')
    await piDurableDatabase(botsDatabase, { bots: [
      { id: 'bot-1', name: 'Scout', prefix: 'pibot_' + 'b'.repeat(32) + '_', entries: [
        piEntry(1, 1, piReply(migrated + 120_000, 30, { provider: 'openrouter', model: 'kimi-k2' })),
        piEntry(2, 7, piReply(migrated + 180_000, 20, { provider: 'openrouter', model: 'kimi-k2' })),
      ] },
      // A table name that isn't the runtime's own shape is never read.
      { id: 'bot-2', name: 'Odd', prefix: 'pibot_x_', entries: [piEntry(1, 1, piReply(migrated, 999))] },
    ] })

    const scanner = createUsageScanner({ env: {}, home, workspaceRoot: workspace, botsDatabase })
    const page = await settle(scanner)
    const total = records => records.reduce((sum, record) => sum + record.totalTokens, 0)
    const codex = page.records.filter(record => record.harness === 'Codex')
    assert.equal(total(codex), 220)
    const piCLI = page.records.filter(record => record.harness === 'Pi')
    assert.equal(total(piCLI), 20)
    assert.equal(piCLI[0].provider, 'claude')
    assert.equal(piCLI[0].workspace, 'project')
    const durable = page.records.filter(record => record.harness === 'Pi Durable')
    assert.equal(total(durable.filter(record => record.sessionID === 'session-1')), 105)
    assert.equal(total(durable.filter(record => record.sessionID === 'session-2')), 45)
    assert.equal(total(durable.filter(record => record.sessionID === 'session-old')), 8)
    const bots = durable.filter(record => record.agent === 'Scout')
    assert.deepEqual(bots.map(record => record.sessionID).sort(), ['bot:bot-1:1', 'bot:bot-1:7'])
    assert.equal(total(bots), 60)
    assert.ok(durable.every(record => record.application === 'Woven Matter'))
    assert.equal(page.records.filter(record => record.totalTokens >= 999).length, 0)
    assert.ok(!JSON.stringify(page.records).includes('private'))
  } finally { rmSync(home, { recursive: true, force: true }) }
})
