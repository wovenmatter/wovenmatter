// Runs before the suite on any Node. The runtime loads its TypeScript sources
// directly and its container tests rely on Node 26; on an older Node they hang
// until their timeouts instead of failing with a reason.
import { readFileSync } from 'node:fs'

const range = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).engines.node
const minimum = Number(/^>=(\d+)/.exec(range)?.[1])
const major = Number(process.versions.node.split('.')[0])
if (!(major >= minimum)) {
  console.error(`The bots tests need Node ${range}; this is Node ${process.versions.node} (${process.execPath}).`)
  console.error("Put Node 26 first on PATH, or run scripts/test-changes.sh, which uses the repository's pinned Node.")
  process.exit(1)
}
