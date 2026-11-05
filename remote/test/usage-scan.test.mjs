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
