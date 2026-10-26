import { mkdtemp, readFile, readlink, realpath, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { launchBrowser, browserExecutablePath } from './workspace-browser.mjs'

const execute = promisify(execFile)
const failed = (reason, missingLibraries = [], diagnostic) => ({
  ok: false, reason, missingLibraries,
  ...(diagnostic ? { diagnostic } : {}),
  hint: reason === 'missing_libraries'
    ? 'Run Prepare host to install the browser libraries, then run the browser check again.'
    : reason === 'sandbox_blocked'
      ? 'Run Prepare host again to check the Chromium AppArmor allowance and user namespaces. Do not disable the browser sandbox.'
      : 'Chromium sandbox isolation could not be verified. Browser execution must remain unavailable until this check passes.',
})

export function missingLibrariesFromLdd(output) {
  const names = [...String(output).matchAll(/^\s*(\S+)\s+=>\s+not found\s*$/gm)].map(match => match[1])
  for (const match of String(output).matchAll(/error while loading shared libraries:\s*([^:\s]+):/g)) names.push(match[1])
  return [...new Set(names)].sort()
}

function fields(status) {
  return Object.fromEntries(status.split('\n').map(line => {
    const index = line.indexOf(':')
    return index > 0 ? [line.slice(0, index), line.slice(index + 1).trim()] : ['', '']
  }))
}
const integerPID = value => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : null

// CDP supplies the exact process IDs owned by this newly launched browser. Both
// namespaces AND Chromium's renderer filter must be present: a systemd user's
// inherited no-new-privileges flag or Docker's outer seccomp filter is not proof.
export async function verifySandboxProcesses(processInfo, { procRoot = '/proc' } = {}) {
  const browserPID = integerPID(processInfo.find(value => value.type === 'browser')?.id)
  const rendererPIDs = processInfo.filter(value => value.type === 'renderer').map(value => integerPID(value.id))
  if (!browserPID || !rendererPIDs.length || rendererPIDs.some(pid => !pid)) return failed('sandbox_inactive', [], { check: 'process_inventory' })
  const processFile = (pid, file) => join(procRoot, String(pid), file)
  let check = 'browser_namespaces'
  try {
    const baseline = {
      user: await readlink(processFile(browserPID, 'ns/user')),
      pid: await readlink(processFile(browserPID, 'ns/pid')),
    }
    for (const pid of [browserPID, ...rendererPIDs]) {
      check = 'process_status'
      const status = fields(await readFile(processFile(pid, 'status'), 'utf8'))
      check = 'process_flags'
      const command = await readFile(processFile(pid, 'cmdline'), 'utf8')
      if (!status.Uid || status.Uid.split(/\s+/).some(value => Number(value) === 0)
          || /(?:^|[\0\s])--(?:no-sandbox|disable-setuid-sandbox|disable-namespace-sandbox)(?:[\0\s]|$)/.test(command)) return failed('sandbox_inactive', [], { check: 'process_identity_or_flags', pid })
      if (pid === browserPID) continue
      if (status.Seccomp !== '2' || status.NoNewPrivs !== '1') return failed('sandbox_inactive', [], { check: 'renderer_filter', pid })
      // Chromium's headless shell rewrites argv into a space-delimited process
      // title. Linux cmdline may therefore contain spaces rather than one NUL
      // per argument; CDP's process type and the ancestor chain corroborate it.
      if (!/(?:^|[\0\s])--type=renderer(?:[\0\s]|$)/.test(command)) return failed('sandbox_inactive', [], { check: 'renderer_identity', pid })
      check = 'renderer_namespaces'
      if (await readlink(processFile(pid, 'ns/user')) === baseline.user
          || await readlink(processFile(pid, 'ns/pid')) === baseline.pid) return failed('sandbox_inactive', [], { check, pid })
      check = 'renderer_ancestry'
      let ancestor = integerPID(status.PPid), reachedBrowser = false
      for (let depth = 0; ancestor && depth < 64; depth++) {
        if (ancestor === browserPID) { reachedBrowser = true; break }
        ancestor = integerPID(fields(await readFile(processFile(ancestor, 'status'), 'utf8')).PPid)
      }
      if (!reachedBrowser) return failed('sandbox_inactive', [], { check, pid })
    }
    return { ok: true, reason: null, missingLibraries: [], hint: null,
      evidence: { browserPID, rendererPIDs, namespaces: ['user', 'pid'], seccomp: 'filter', noNewPrivileges: true } }
  } catch (error) { return failed('sandbox_inactive', [], { check, code: /^[A-Z0-9_]{1,32}$/.test(error.code) ? error.code : 'unavailable' }) }
}

export async function browserSelfTest({ launch = launchBrowser, procRoot = '/proc', platform = process.platform } = {}) {
  if (platform !== 'linux') return failed('sandbox_inactive')
  const directory = await mkdtemp(join(tmpdir(), 'wovenmatter-browser-selftest-'))
  let session, cdp
  try {
    session = await launch(directory, { runtimeKind: 'host' })
    const page = await session.context.newPage()
    await page.goto('data:text/html,<title>Woven Matter sandbox check</title><p>Browser sandbox check</p>', { waitUntil: 'load', timeout: 15000 })
    cdp = await session.context.browser().newBrowserCDPSession()
    const { processInfo } = await cdp.send('SystemInfo.getProcessInfo')
    return await verifySandboxProcesses(processInfo, { procRoot })
  } catch (error) {
    let libraries = missingLibrariesFromLdd(error?.message)
    if (launch === launchBrowser || session?.executablePath) {
      try {
        const path = session?.executablePath ?? await browserExecutablePath()
        let output
        try { output = (await execute('ldd', [path], { timeout: 10000 })).stdout }
        catch (lddError) { output = lddError.stdout ?? '' }
        libraries = [...new Set([...libraries, ...missingLibrariesFromLdd(output)])].sort()
      } catch {}
    }
    return failed(libraries.length ? 'missing_libraries' : 'sandbox_blocked', libraries)
  } finally {
    await cdp?.detach().catch(() => {})
    await session?.context.close().catch(() => {})
    await rm(directory, { recursive: true, force: true })
  }
}

// Installed releases are invoked through current/src, while Node resolves this
// module's URL to releases/<fingerprint>/src. Canonicalize both paths so a CLI
// invocation never silently exits without running the sandbox check.
const invokedPath = process.argv[1] ? await realpath(resolve(process.argv[1])).catch(() => null) : null
if (invokedPath === await realpath(fileURLToPath(import.meta.url))) {
  const result = await browserSelfTest()
  process.stdout.write(JSON.stringify(result) + '\n')
  process.exitCode = result.ok ? 0 : 1
}
