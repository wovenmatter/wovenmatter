import { existsSync } from 'node:fs'

// The app/repository keeps remote/src beside harnesses; the deployed service
// flattens remote/src to src. Resolve resources in either shipped layout.
const root = new URL(existsSync(new URL('../harnesses/catalog.json', import.meta.url))
  ? '../harnesses/' : '../../harnesses/', import.meta.url)

export const harnessResource = path => new URL(path, root)
