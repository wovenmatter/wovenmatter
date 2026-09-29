import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { sdkStatus, checkSDKUpdates, updateSDK, resolveSDKRuntime, SDKMaintenanceError } from './sdk-management.mjs';

// Only this proxy is loaded by the long-lived workspace HTTP service. SDKs and
// session state live in a replaceable process with one immutable generation.
export function createManagedDefaultAgentService({ cwd, directory }) {
  let worker, selection = Promise.resolve(), sequence = 0, leases = 0, closed = false, lastConfiguration;
  const installController = new AbortController();
  const updates = new Set();
  function launch(runtime) {
    const child = fork(fileURLToPath(new URL('./sdk-worker.mjs', import.meta.url)), [], { cwd, execPath: process.execPath,
      stdio: ['ignore', 'ignore', 'ignore', 'ipc'], serialization: 'advanced' });
    const pending = new Map();
    let exited = false;
    const value = { child, generation: runtime.generation, pending,
      call(method, ...args) {
        if (exited || !child.connected) return Promise.reject(new SDKMaintenanceError('The Built-in runtime stopped. Reconnect this workspace.'));
        const id = ++sequence;
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject });
          child.send({ id, method, args }, error => {
            if (error) { pending.delete(id); reject(new SDKMaintenanceError('The Built-in runtime could not receive this operation.')); }
          });
        });
      } };
    child.on('message', message => {
      const request = pending.get(message.id); if (!request) return;
      pending.delete(message.id);
      if (message.error) request.reject(Object.assign(new Error(message.error.message), { statusCode: message.error.statusCode }));
      else request.resolve(message.result);
    });
    const lost = () => {
      exited = true;
      for (const request of pending.values()) request.reject(new SDKMaintenanceError('The Built-in runtime stopped. Reconnect this workspace.'));
      pending.clear(); if (worker === value) worker = undefined;
    };
    child.once('error', lost); child.once('exit', lost);
    const id = ++sequence;
    value.ready = new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); child.send({ id, method: 'initialize', root: runtime.root, cwd, directory }, error => { if (error) { pending.delete(id); reject(error); } }); });
    return value;
  }
  async function stop(value) {
    if (!value) return;
    if (value.child.exitCode !== null || value.child.signalCode !== null) return;
    const finished = new Promise(resolve => value.child.once('exit', resolve));
    if (value.child.connected) value.child.disconnect();
    const timer = setTimeout(() => value.child.kill('SIGKILL'), 5000); timer.unref();
    try { await finished; } finally { clearTimeout(timer); }
  }
  async function select() {
    if (closed) throw new SDKMaintenanceError('This workspace is shutting down.');
    const runtime = await resolveSDKRuntime({ directory });
    if (worker && worker.generation !== runtime.generation && leases === 0) {
      // All dispatches pass through this queue. An idle acknowledgement fences
      // the old process before another request can enter it.
      if (await worker.call('prepareRetirement')) {
        const previous = worker; worker = undefined; await stop(previous);
      }
    }
    if (!worker) {
      worker = launch(runtime);
      const starting = worker;
      try {
        await starting.ready;
        if (lastConfiguration) await starting.call('configure', lastConfiguration);
      } catch (error) {
        if (worker === starting) worker = undefined;
        await stop(starting); throw error;
      }
    }
    return worker;
  }
  function selected(operation) {
    const next = selection.then(async () => operation(await select()));
    selection = next.then(() => {}, () => {});
    return next;
  }
  // Release the admission queue after sending, not after a prompt completes.
  function dispatch(method, ...args) {
    let response;
    return selected(value => { response = value.call(method, ...args); }).then(() => response);
  }
  async function inventory() {
    const result = await sdkStatus({ directory });
    const pendingActivation = Boolean(worker && worker.generation !== result.generation);
    return { ...result, pendingActivation, ...(pendingActivation ? { notice: 'SDK updated. Active work will finish before this workspace switches to it.' } : {}) };
  }
  return {
    async configure(payload) {
      // Save only after the service accepted it; the payload stays in private
      // process memory and is never written by SDK management or diagnostics.
      const result = await dispatch('configure', payload);
      lastConfiguration = structuredClone(payload); return result;
    },
    invoke: message => dispatch('invoke', message),
    poll: (id, after) => dispatch('poll', id, after),
    status: () => dispatch('status'),
    cancelActive: () => dispatch('cancelActive'),
    sdkStatus: inventory,
    checkSDKUpdates: async ({ id, signal } = {}) => { await checkSDKUpdates({ directory, id, signal }); return inventory(); },
    async updateSDK({ id, version, signal } = {}) {
      const combined = signal ? AbortSignal.any([signal, installController.signal]) : installController.signal;
      const update = updateSDK({ directory, id, version, signal: combined }); updates.add(update);
      try {
        await update;
        // Metadata-only updates do not start a runtime/credential process unless
        // this workspace already had one; otherwise the next use activates it.
        if (worker) await selected(() => {});
        return inventory();
      } finally { updates.delete(update); }
    },
    async withRuntimeLease(operation) {
      await selected(() => { leases++; });
      try { return await operation(); } finally { leases--; }
    },
    async close() {
      if (closed) return;
      installController.abort(); await Promise.allSettled([...updates]);
      await selection;
      closed = true;
      if (worker) {
        const previous = worker; worker = undefined;
        let deadline;
        try { await Promise.race([previous.call('cancelActive'), new Promise(resolve => { deadline = setTimeout(resolve, 10000); deadline.unref(); })]); }
        finally { clearTimeout(deadline); await stop(previous); }
      }
      lastConfiguration = undefined;
    },
  };
}
