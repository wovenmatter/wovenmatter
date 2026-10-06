import { createRegistry } from '@earendil-works/pi-durable';
import { NativeContext } from './native-context.mjs';

// The pinned SDK's decline hook completes compaction with an empty result.
// Overflow recovery requires the actual entry which made the context smaller.
// Decorate the application-owned registry's public task view, keeping the
// stock task identity, phases, status cleanup and scheduler intact.
export function createNativeCompactionRegistry() {
  const registry = createRegistry(), snapshots = new WeakMap(), tasks = new WeakMap();
  const nativeTask = task => {
    if (!task || task.definition.name !== 'pi.compaction') return task;
    if (!tasks.has(task)) {
      const select = task.definition.phases.select;
      const decorated = { ...task, definition: { ...task.definition, phases: {
        ...task.definition.phases,
        select: (current, runtime, context) => {
          const commit = async (change, callContext) => runtime.commit(async (tx, live) => {
            const next = await change(tx, live);
            if (next?.status !== 'terminal' || next.outcome?.status !== 'completed'
                || next.outcome.result?.entryId !== undefined || next.outcome.result?.submissionId !== undefined) return next;
            const receipt = (await tx.doc(NativeContext, runtime.conversationId)).nativeCompaction;
            if (receipt?.taskID !== runtime.taskId || !Number.isSafeInteger(receipt.entryID)) return next;
            const entry = await tx.entry(receipt.entryID);
            if (entry?.kind !== 'woven.native-compaction' || entry.conversationId !== runtime.conversationId) return next;
            return { ...next, outcome: { ...next.outcome, result: { ...next.outcome.result, entryId: entry.id } } };
          }, callContext);
          const scoped = new Proxy(runtime, { get(target, key) {
            if (key === 'commit') return commit;
            const value = Reflect.get(target, key, target);
            return typeof value === 'function' ? value.bind(target) : value;
          } });
          return select(current, scoped, context);
        },
      } } };
      tasks.set(task, decorated);
    }
    return tasks.get(task);
  };
  const snapshot = () => {
    const current = registry.snapshot();
    if (!snapshots.has(current)) snapshots.set(current, new Proxy(current, { get(target, key) {
      if (key === 'task') return name => nativeTask(target.task(name));
      if (key === 'tasks') return () => target.tasks().map(nativeTask);
      const value = Reflect.get(target, key, target);
      return typeof value === 'function' ? value.bind(target) : value;
    } }));
    return snapshots.get(current);
  };
  return new Proxy(registry, { get(target, key) {
    if (key === 'snapshot') return snapshot;
    const value = Reflect.get(target, key, target);
    return typeof value === 'function' ? value.bind(target) : value;
  } });
}
