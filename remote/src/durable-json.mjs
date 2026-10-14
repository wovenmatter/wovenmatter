import { randomUUID } from 'node:crypto'
import { mkdirSync, openSync, writeFileSync, fsyncSync, closeSync, renameSync } from 'node:fs'
import { dirname } from 'node:path'

export function durableJSON(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.${randomUUID()}.tmp`
  const file = openSync(temporary, 'wx', 0o600)
  try { writeFileSync(file, JSON.stringify(value)); fsyncSync(file) }
  finally { closeSync(file) }
  renameSync(temporary, path)
  const directory = openSync(dirname(path), 'r')
  try { fsyncSync(directory) } finally { closeSync(directory) }
}
