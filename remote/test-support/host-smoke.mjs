// Provider-free checks against a disposable, deployed native workspace. Run on
// the Mac through its loopback SSH tunnel; no dependency or browser is launched
// on the Mac. Never put the administrative token in command-line arguments.
//
// WOVENMATTER_TEST_URL=http://127.0.0.1:PORT WOVENMATTER_API_TOKEN=... \
// WOVENMATTER_BROWSER_TEST_ORIGIN=http://127.0.0.1:REMOTE_PORT \
// node remote/test-support/host-smoke.mjs --state /private/tmp/host-state.json
// Repeat with --verify-state after replacing the SSH tunnel or restarting the
// service. The receipt contains public IDs only; it never stores credentials.
// Root access can be checked separately via:
// current/bin/wm-exec exec sudo -n /bin/sh -c 'id -u'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { chmod, readFile, writeFile } from 'node:fs/promises'
import { isAbsolute } from 'node:path'

const arguments_ = process.argv.slice(2)
const option = name => {
  const index = arguments_.indexOf(name)
  if (index < 0) return undefined
  assert.ok(arguments_[index + 1] && !arguments_[index + 1].startsWith('--'), `${name} needs a value`)
  return arguments_[index + 1]
}
const secrets = new Set()
const redact = value => {
  let text = String(value)
  for (const secret of secrets) if (secret) text = text.replaceAll(secret, '[redacted]')
  return text
}

function client(origin, token) {
  const url = new URL(origin)
  assert.equal(url.protocol, 'http:', 'Validation must use a loopback SSH tunnel')
  assert.ok(['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname), 'Validation must use a loopback SSH tunnel')
  assert.ok(!url.username && !url.password && !url.search && !url.hash)
  secrets.add(token)
  return async (path, { method = 'GET', body, bearer = token, status = 200, signal, raw = false } = {}) => {
    const response = await fetch(new URL(path, url), {
      method, redirect: 'error',
      headers: { ...(bearer ? { authorization: 'Bearer ' + bearer } : {}), 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(45000)]) : AbortSignal.timeout(45000),
    })
    assert.equal(response.status, status, `${method} ${path} returned HTTP ${response.status}, expected ${status}`)
    assert.equal(response.headers.get('cache-control'), 'no-store', `${path} must not be cached`)
    if (raw) return response
    const result = await response.json()
    if (result.token) secrets.add(result.token)
    return result
  }
}

const parseText = result => JSON.parse(result.content.find(block => block.type === 'text').text)
const check = (condition, message) => assert.ok(condition, message)

async function deployedSmoke() {
  const token = process.env.WOVENMATTER_API_TOKEN
  check(typeof token === 'string' && token.length >= 32, 'Set WOVENMATTER_API_TOKEN in the environment')
  const request = client(process.env.WOVENMATTER_TEST_URL ?? 'http://127.0.0.1:7337', token)
  const statePath = option('--state')
  const verify = arguments_.includes('--verify-state')
  check(!verify || statePath, '--verify-state requires --state')
  const state = verify ? JSON.parse(await readFile(statePath, 'utf8')) : {
    schemaVersion: 1, runID: randomUUID(), callerID: randomUUID(), marker: randomUUID(),
  }
  check(state.schemaVersion === 1 && /^[0-9a-f-]{36}$/.test(state.runID), 'Invalid validation receipt')
  const report = { ok: false, mode: verify ? 'verify-persistence' : 'initial', checks: [] }
  const completed = name => report.checks.push(name)

  const health = await request('/v1/health')
  assert.equal(health.status, 'ready')
  assert.equal(health.runtimeKind, 'host')
  check(['fullRoot', 'user'].includes(health.accessMode), 'Unknown workspace access mode')
  check(/^[a-f0-9]{64}$/.test(health.serviceFingerprint), 'Missing deployment fingerprint')
  for (const key of ['workspaceRoot', 'databasesDirectory', 'attachmentsDirectory', 'dataRoot']) {
    check(typeof health[key] === 'string' && isAbsolute(health[key]) && !health[key].includes('\0'), `Invalid ${key}`)
  }
  if (verify) {
    for (const key of ['workspaceRoot', 'databasesDirectory', 'attachmentsDirectory', 'dataRoot']) assert.equal(health[key], state.health[key], `${key} changed during reconnect/restart`)
  } else state.health = health
  report.accessMode = health.accessMode
  report.fingerprint = health.serviceFingerprint
  completed('authenticated-host-health-and-absolute-paths')
  await request('/v1/health', { bearer: 'deliberately-invalid-native-host-validation', status: 401 })
  const inspection = await request('/v1/runtime/inspection')
  check(inspection.items.some(item => item.kind === 'service' && Number.isInteger(item.processID)), 'Missing service process inspection')
  check(!JSON.stringify(inspection).includes(token), 'Inspection exposed the administrative credential')
  completed('authentication-and-service-inspection')

  const sandbox = await request('/v1/browser/selftest')
  assert.equal(sandbox.ok, true, `Native browser sandbox failed: ${sandbox.reason ?? 'unknown'}`)
  check(sandbox.evidence?.rendererPIDs?.length > 0, 'Sandbox check did not identify actual renderer processes')
  assert.deepEqual(sandbox.evidence.namespaces, ['user', 'pid'])
  assert.equal(sandbox.evidence.seccomp, 'filter')
  assert.equal(sandbox.evidence.noNewPrivileges, true)
  report.sandbox = sandbox.evidence
  completed('native-renderer-sandbox-proof')

  const harnesses = (await request('/v1/harnesses')).harnesses
  check(harnesses.some(harness => harness.id === 'default_agent'), 'Pi Durable is missing')
  for (const harness of harnesses) check(['system', 'managed', 'missing'].includes(harness.source), `Missing installation source for ${harness.id}`)
  report.harnesses = harnesses.map(({ id, state, source }) => ({ id, state, source }))
  await request('/v1/default-agent/status') // Status must not start a provider run.
  const inventory = await request('/v1/runtime-maintenance')
  const rows = Array.isArray(inventory) ? inventory : inventory.harnesses ?? inventory.runtimes ?? []
  for (const row of rows) for (const component of row.components ?? []) check(['system', 'managed', 'missing'].includes(component.source), `Missing component source for ${row.id}`)
  completed('existing-harness-inventory-and-pi-status')

  const existing = await request('/v1/execution', { status: state.enrollment ? 200 : undefined, raw: true }).catch(error => {
    if (error.code === 'ERR_ASSERTION' && /returned HTTP 409/.test(error.message)) return null
    throw error
  })
  let identity = existing ? await existing.json() : null
  if (!identity) {
    check(process.env.WOVENMATTER_ALLOW_ENROLLMENT === '1', 'Disposable workspace is unenrolled; set WOVENMATTER_ALLOW_ENROLLMENT=1 to bind it for validation')
    identity = { id: randomUUID(), libraryID: randomUUID(), ownerDeviceID: randomUUID() }
  }
  if (verify) {
    assert.equal(identity.id, state.enrollment.id, 'Execution workspace identity did not survive restart')
    assert.equal(identity.libraryID, state.enrollment.libraryID, 'Library identity did not survive restart')
  }
  const deviceID = randomUUID()
  const enrolled = await request('/v1/execution/devices', { method: 'POST', status: 201, body: {
    workspaceID: identity.id, libraryID: identity.libraryID, ownerDeviceID: identity.ownerDeviceID,
    deviceID, name: 'Disposable native-host validation', scopes: ['execution'],
  } })
  state.enrollment = { id: enrolled.workspace.id, libraryID: enrolled.workspace.libraryID }
  try {
    const descriptor = await request('/v1/execution', { bearer: enrolled.token })
    assert.equal(descriptor.id, enrolled.workspace.id)
    for (const path of ['/v1/browser/selftest', '/v1/browser/tabs', '/v1/default-agent/status', '/v1/runtime/inspection']) await request(path, { bearer: enrolled.token, status: 403 })
    await request('/v1/execution/events?after=0', { bearer: enrolled.token })
    await request('/v1/inference/catalog', { bearer: enrolled.token, status: 401 })
  } finally {
    await request('/v1/execution/devices/' + deviceID, { method: 'DELETE' })
  }
  await request('/v1/execution', { bearer: enrolled.token, status: 401 })
  completed('scoped-device-enrollment-authority-and-revocation')

  if (!verify) {
    state.projectName = 'native-host-validation-' + state.runID.slice(0, 8)
    state.projectPath = (await request('/v1/projects', { method: 'POST', status: 201, body: { name: state.projectName } })).path
    state.databaseID = (await request('/v1/databases', { method: 'POST', body: { name: state.projectName } })).id
    await request('/v1/databases/execute', { method: 'POST', body: {
      databaseID: state.databaseID,
      sql: `CREATE TABLE host_validation(value TEXT NOT NULL); INSERT INTO host_validation VALUES('${state.marker}');`,
    } })
  }
  const reused = await request('/v1/projects', { method: 'POST', status: 201, body: { name: state.projectName, reuseExisting: true } })
  assert.equal(reused.path, state.projectPath)
  assert.equal(state.projectPath, health.workspaceRoot + '/' + state.projectName)
  const database = await request('/v1/databases/query', { method: 'POST', body: { databaseID: state.databaseID, sql: 'SELECT value FROM host_validation' } })
  assert.deepEqual(database.query.rows, [[state.marker]])
  const snapshot = await request('/v1/databases/snapshot', { method: 'POST', body: { databaseID: state.databaseID } })
  assert.equal(Buffer.from(snapshot.sqliteBase64, 'base64').subarray(0, 16).toString(), 'SQLite format 3\0')
  completed('managed-folders-and-sqlite-persistence')

  state.profiles ??= ['host-test-' + state.runID.slice(0, 8) + '-a', 'host-test-' + state.runID.slice(0, 8) + '-b']
  const browserOrigin = new URL(process.env.WOVENMATTER_BROWSER_TEST_ORIGIN ?? 'http://127.0.0.1:7337')
  assert.equal(browserOrigin.protocol, 'http:')
  check(browserOrigin.hostname === '127.0.0.1' && !browserOrigin.username && !browserOrigin.password, 'Browser fixture origin must be host loopback')
  const call = async input => {
    const envelope = await request('/v1/browser/mcp', { method: 'POST', body: { callerID: state.callerID, input: { ...input, requestID: input.requestID ?? randomUUID() } } })
    assert.equal(envelope.success, true, `Browser ${input.action} failed: ${envelope.code ?? 'unknown'} ${envelope.error ?? ''}`)
    return envelope.result
  }
  const tabs = []
  try {
    for (const profile of state.profiles) {
      const connected = await request('/v1/browser/connect?profile=' + profile, { method: 'POST', body: {} })
      check(/^ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\//.test(connected.endpoint), 'CDP escaped host loopback')
      const opened = parseText(await call({ action: 'open', profile, url: new URL('/v1/health', browserOrigin).href }))
      check(typeof opened.tabId === 'string', 'Browser did not create a tab')
      tabs.push({ profile, tabId: opened.tabId })
    }
    const [a, b] = tabs
    const readStorage = tab => call({ ...tab, action: 'evaluate', code: `({value:localStorage.getItem('woven-host-validation'),cookie:document.cookie})` }).then(parseText)
    if (verify) {
      assert.equal((await readStorage(a)).value, state.marker, 'Profile A persistent storage was lost')
      assert.equal((await readStorage(b)).value, state.marker + '-b', 'Profile B persistent storage was lost')
    } else {
      assert.equal((await readStorage(a)).value, null)
      assert.equal((await readStorage(b)).value, null)
      await call({ ...a, action: 'evaluate', code: `localStorage.setItem('woven-host-validation',${JSON.stringify(state.marker)});document.cookie='woven_host_validation=a; SameSite=Strict; Path=/';true` })
      assert.equal((await readStorage(a)).value, state.marker)
      assert.equal((await readStorage(b)).value, null, 'Browser profiles share local storage')
      assert.ok(!(await readStorage(b)).cookie.includes('woven_host_validation=a'), 'Browser profiles share cookies')
      await call({ ...b, action: 'evaluate', code: `localStorage.setItem('woven-host-validation',${JSON.stringify(state.marker + '-b')});true` })
    }
    assert.equal((await readStorage(a)).value, state.marker)
    assert.equal((await readStorage(b)).value, state.marker + '-b')
    const fixtureHTML = `<label>Name <input aria-label="Name"></label><button onclick="document.querySelector('output').textContent=document.querySelector('input').value">Apply</button><output></output>`
    await call({ ...a, action: 'evaluate', code: `document.body.innerHTML=${JSON.stringify(fixtureHTML)};true` })
    await call({ ...a, action: 'fill', selector: 'input', text: 'Native host collaboration' })
    await call({ ...a, action: 'click', selector: 'button' })
    assert.equal(parseText(await call({ ...a, action: 'evaluate', code: `document.querySelector('output').textContent` })), 'Native host collaboration')
    const screenshot = await call({ ...a, action: 'screenshot' })
    const image = screenshot.content.find(block => block.type === 'image')
    check(image?.mimeType === 'image/jpeg' && Buffer.from(image.data, 'base64').readUInt16BE() === 0xffd8, 'Browser screenshot is not JPEG')
    const viewerTabs = await request('/v1/browser/tabs?profile=' + a.profile)
    assert.equal(viewerTabs.profile, a.profile)
    check(viewerTabs.profiles.includes(a.profile) && viewerTabs.profiles.includes(b.profile), 'Viewer cannot discover both profiles')
    check(viewerTabs.tabs.some(tab => tab.id === a.tabId), 'Viewer and MCP have different tab identities')
    const wrongProfile = await request('/v1/browser/frame?profile=' + b.profile, { method: 'POST', status: 410, body: { tabID: a.tabId } })
    check(wrongProfile.error, 'Cross-profile tab lookup did not fail')
    const frame = await request('/v1/browser/frame?profile=' + a.profile, { method: 'POST', body: { tabID: a.tabId } })
    assert.equal(frame.tabID, a.tabId)
    assert.equal(Buffer.from(frame.imageBase64, 'base64').readUInt16BE(), 0xffd8)
    const stream = await request('/v1/browser/stream?profile=' + a.profile + '&tabID=' + a.tabId, { raw: true })
    const reader = stream.body.getReader()
    try {
      let line = ''
      while (!line.includes('\n')) {
        const chunk = await reader.read()
        check(!chunk.done, 'Live frame stream closed before a frame')
        line += Buffer.from(chunk.value).toString()
      }
      assert.equal(JSON.parse(line.split('\n')[0]).tabID, a.tabId)
    } finally { await reader.cancel() }
    completed('two-native-browser-profiles-cookie-and-storage-isolation')
    completed('mcp-and-viewer-shared-tabs-input-screenshot-and-live-stream')
  } finally {
    for (const tab of tabs) await call({ ...tab, action: 'close' }).catch(() => {})
  }
  if (statePath) {
    const bytes = JSON.stringify(state, null, 2) + '\n'
    for (const secret of secrets) check(!bytes.includes(secret), 'Validation receipt would contain a credential')
    await writeFile(statePath, bytes, { mode: 0o600 })
    await chmod(statePath, 0o600)
  }
  report.ok = true
  return report
}

try {
  process.stdout.write(JSON.stringify(await deployedSmoke()) + '\n')
} catch (error) {
  process.stderr.write(JSON.stringify({ ok: false, error: redact(error?.message ?? error) }) + '\n')
  process.exitCode = 1
}
