// Approval requests live only as long as their turn. Disconnection does not
// approve anything; cancellation and expiration always deny the request.
export class PermissionRequests {
  pending = new Map();
  request(params, signal, publish, cancel) {
    if (signal?.aborted) return Promise.resolve(false);
    const id = crypto.randomUUID();
    return new Promise(resolve => {
      const finish = allowed => {
        clearTimeout(timer); signal?.removeEventListener('abort', abort);
        this.pending.delete(id); resolve(allowed);
      };
      const abort = () => { cancel?.(id); finish(false); };
      const timer = setTimeout(abort, 30 * 60 * 1000);
      this.pending.set(id, { params, finish, cancel: abort });
      signal?.addEventListener('abort', abort, { once: true });
      publish(id, params);
    });
  }
  resolve(id, result) {
    this.pending.get(id)?.finish(result?.outcome?.outcome === 'selected' && result.outcome.optionId === 'allow');
  }
  cancelSession(sessionId) {
    for (const request of this.pending.values()) if (request.params.sessionId === sessionId) request.cancel();
  }
}

// Continue polling while the Mac shows an approval. Another attached client or
// the server can settle it; stale dialogs must not hold up the event stream.
export class RemotePermissionRequests {
  pending = new Map();
  seen = new Set();
  error;
  constructor(request, reply) { this.request = request; this.reply = reply; }
  update(page) {
    const active = new Set(page.done ? [] : page.pendingPermissions ?? []);
    for (const [id, controller] of this.pending) if (!active.has(id)) controller.abort();
    for (const event of page.updates) {
      if (event.sessionUpdate !== 'woven_permission' || !active.has(event.id) || this.seen.has(event.id)) continue;
      this.seen.add(event.id);
      const controller = new AbortController();
      this.pending.set(event.id, controller);
      void this.request(event.params, controller.signal).then(async allowed => {
        if (!controller.signal.aborted) await this.reply(event.id, allowed);
      }).catch(error => { this.error = error; }).finally(() => this.pending.delete(event.id));
    }
    if (this.error) throw this.error;
  }
  close() { for (const controller of this.pending.values()) controller.abort(); }
}
