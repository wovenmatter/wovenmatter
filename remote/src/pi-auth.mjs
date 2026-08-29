import { execFileSync } from 'node:child_process'
import { readFile, realpath } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const [action, providerID] = process.argv.slice(2)
if (!['oauth', 'api-key'].includes(action) || !providerID) {
  fail('usage: pi-auth.mjs oauth|api-key PROVIDER')
}

const home = process.env.HOME
if (!home) fail('HOME is required')

const piCommand = execFileSync('/bin/bash', ['-c', 'command -v pi'], {
  encoding: 'utf8',
  env: process.env,
}).trim()
if (!piCommand) fail('Pi is not installed')

const piRoot = await piPackageRoot(piCommand)
const providerModule = await import(pathToFileURL(resolve(
  piRoot,
  'node_modules/@earendil-works/pi-ai/dist/providers/all.js'
)))
const storageModule = await import(pathToFileURL(resolve(
  piRoot,
  'dist/core/auth-storage.js'
)))
const provider = providerModule.builtinProviders().find((value) => value.id === providerID)
if (!provider) fail(`Pi does not support provider ${providerID}`)

const storage = storageModule.AuthStorage.create(resolve(home, '.pi/agent/auth.json'))
if (action === 'api-key') {
  if (!provider.auth.apiKey) fail(`Pi provider ${providerID} does not accept API keys`)
  const key = (await readSingleInput()).trim()
  if (!key || Buffer.byteLength(key) > 32_768) fail('Invalid API key')
  await storage.modify(providerID, async () => ({ type: 'api_key', key }))
  process.stdout.write(`Pi ${provider.name} API key stored.\n`)
  process.exit(0)
}

if (!provider.auth.oauth) fail(`Pi provider ${providerID} does not support account sign-in`)
const abortController = new AbortController()
const stop = () => abortController.abort()
process.once('SIGTERM', stop)
process.once('SIGINT', stop)
const credential = await provider.auth.oauth.login({
  signal: abortController.signal,
  prompt: async (prompt) => {
    if (prompt.type === 'select') {
      const deviceCode = prompt.options.find((option) => option.id === 'device_code')
      if (!deviceCode) fail('Pi did not offer a headless sign-in method')
      return deviceCode.id
    }
    process.stdout.write(`${prompt.message}\n`)
    return (await readSingleInput()).trim()
  },
  notify: (event) => {
    if (event.type === 'auth_url') {
      process.stdout.write(`Open this URL in your browser:\n${event.url}\n`)
      if (event.instructions) process.stdout.write(`${event.instructions}\n`)
    } else if (event.type === 'device_code') {
      process.stdout.write(`Open this URL in your browser:\n${event.verificationUri}\n`)
      process.stdout.write(`Enter code: ${event.userCode}\n`)
    } else if (event.type === 'info' || event.type === 'progress') {
      process.stdout.write(`${event.message}\n`)
    }
  },
})
await storage.modify(providerID, async () => credential)
process.stdout.write(`Pi ${provider.name} sign-in completed.\n`)

async function readSingleInput() {
  let value = ''
  for await (const chunk of process.stdin) {
    value += chunk.toString('utf8')
    if (Buffer.byteLength(value) > 32_768) fail('Credential input is too large')
    const newline = value.indexOf('\n')
    if (newline >= 0) return value.slice(0, newline)
  }
  return value
}

async function piPackageRoot(command) {
  let directory = dirname(await realpath(command))
  while (true) {
    try {
      const metadata = JSON.parse(await readFile(resolve(directory, 'package.json'), 'utf8'))
      const piBinary = typeof metadata.bin === 'string' ? metadata.bin : metadata.bin?.pi
      if (metadata.name === '@earendil-works/pi-coding-agent'
        && typeof piBinary === 'string') {
        return directory
      }
    } catch (error) {
      if (error.code !== 'ENOENT') {
        fail(`Unable to inspect the Pi installation: ${error.message}`)
      }
    }
    const parent = dirname(directory)
    if (parent === directory) fail('Unable to locate the Pi package root')
    directory = parent
  }
}

function fail(message) {
  process.stderr.write(`${message}\n`)
  process.exit(1)
}
