// OSC 7501 vocabulary carried by our structured transport. Never write escape
// sequences into ACP's JSON stream. Identity is bound by the trusted engine.
export function statusMessage(value, limit = 2048) {
  if (typeof value !== 'string') return undefined;
  const clean = value.replace(/[\x00-\x1f\x7f-\x9f]/g, ' ').trim();
  let text = '', bytes = 0;
  for (const scalar of clean) {
    const length = Buffer.byteLength(scalar);
    if (bytes + length > limit) break;
    text += scalar; bytes += length;
  }
  return text || undefined;
}

export function reportProgramStatus(record, { state, id, kind, title, msg, progress } = {}, runID = record.runID) {
  if (!record.emit || !runID) return;
  if (!['idle', 'working', 'blocked', 'done', 'error', 'clear'].includes(state)) throw new Error('Invalid program status');
  const status = { state, app: 'pi-durable', ...(id ? { id } : {}),
    ...(state === 'blocked' && kind ? { kind } : {}),
    ...(['working', 'blocked'].includes(state) && Number.isInteger(progress) && progress >= 0 && progress <= 100 ? { progress } : {}),
    ...(title ? { title: statusMessage(title, 192) } : {}), ...(msg ? { msg: statusMessage(msg) } : {}) };
  if (runID === record.runID) {
    if (record.programStatusesRunID !== runID) { record.programStatuses = new Map(); record.programStatusesRunID = runID; }
    const key = id ?? '';
    // Coalesce unchanged output at the producer. Received reports still update
    // the consumer's LRU order. Blocks may be repeated to repair advisory loss.
    if (state !== 'clear' && state !== 'blocked'
        && JSON.stringify(record.programStatuses.get(key)) === JSON.stringify(status)) return;
    if (state === 'clear') {
      for (const candidate of record.programStatuses.keys()) if (!id || candidate === id || candidate.startsWith(id + '/')) record.programStatuses.delete(candidate);
    } else { record.programStatuses.set(key, status); }
  }
  record.emit({ sessionUpdate: 'woven_program_status', status, _meta: { wovenRunID: runID } });
}
