// Migration reader for Pi Durable JSONL format 1. Recovery/reclamation rules
// follow @earendil-works/pi-durable 1.4 (MIT, Copyright (c) 2025 Mario Zechner).
// https://github.com/earendil-works/pi/blob/v1.4.0/packages/durable/src/storage/jsonl/storage.ts
// The SDK validates and recovers the source before this reader is called. No
// Harness is opened here: migration must never schedule models or tools.
import { readFile, readdir, lstat } from 'node:fs/promises';
import { join } from 'node:path';

async function lines(path) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('Legacy Durable storage must contain regular files.');
  const text = new TextDecoder('utf-8', { fatal: true }).decode(await readFile(path));
  return text.split('\n').filter(Boolean).map(line => JSON.parse(line));
}

export async function legacyCommits(directory) {
  const main = await lines(join(directory, 'main.jsonl'));
  const records = new Map(), current = new Set(), retired = new Set(), finalTasks = new Map(), latest = new Map();
  const key = (file, seq, ordinal) => `${file}:${seq}:${ordinal}`;
  for (const file of await readdir(directory)) {
    if (!/^(doc|task)-(0|[1-9]\d*)\.jsonl$/.test(file)) continue;
    for (const record of await lines(join(directory, file))) {
      if (record.format !== 1 || record.type !== 'record') throw new Error('Unsupported legacy Durable sidecar format.');
      records.set(key(file, record.seq, record.ordinal), record);
    }
  }
  for (const marker of main) {
    if (marker.format !== 1 || marker.type !== 'commit' || !Array.isArray(marker.writes)) throw new Error('Unsupported legacy Durable commit format.');
    for (const operation of marker.writes) {
      if (operation.type === 'document.create' && (operation.record.scope.kind !== 'conversation' || operation.record.history === 'latest')) current.add(operation.record.id);
      if (operation.type === 'document.retire') retired.add(operation.id);
      if (operation.type === 'task') finalTasks.set(operation.value.id, false);
      if (operation.type === 'task.sidecar') finalTasks.set(operation.id, true);
    }
  }
  for (const marker of main) for (const operation of marker.writes) {
    if (!['document.create', 'document.change'].includes(operation.type)) continue;
    const id = operation.record?.id ?? operation.id;
    const record = records.get(key(`doc-${id}.jsonl`, marker.seq, operation.ordinal));
    if (current.has(id) && record?.payload.content.kind === 'base') latest.set(id, record);
  }
  return main.map(marker => {
    const writes = [];
    for (const operation of marker.writes) {
      if (['conversation', 'entry', 'submission', 'task', 'document.retire'].includes(operation.type)) {
        writes.push(operation); continue;
      }
      if (operation.type === 'task.sidecar') {
        if (!finalTasks.get(operation.id)) continue; // Terminal tasks have reclaimed sidecars.
        const record = records.get(key(`task-${operation.id}.jsonl`, marker.seq, operation.ordinal));
        if (!record || record.payload.type !== 'task' || record.payload.value.id !== operation.id) throw new Error('Missing confirmed legacy task state.');
        writes.push({type:'task',value:record.payload.value}); continue;
      }
      if (!['document.create','document.change'].includes(operation.type)) throw new Error('Unsupported legacy Durable operation.');
      const id = operation.record?.id ?? operation.id, base = latest.get(id);
      const reclaimed = current.has(id) && (retired.has(id) || (base && (marker.seq < base.seq || (marker.seq === base.seq && operation.ordinal < base.ordinal))));
      const record = records.get(key(`doc-${id}.jsonl`, marker.seq, operation.ordinal));
      if (!record && !reclaimed) throw new Error('Missing confirmed legacy document state.');
      if (operation.type === 'document.create') {
        const content = reclaimed ? {kind:'base',version:1,value:{}} : record.payload.content;
        writes.push({type:'document.create',record:operation.record,content});
      } else if (!reclaimed) writes.push({type:'document.change',id,content:record.payload.content});
    }
    return {seq:marker.seq,writes};
  });
}
