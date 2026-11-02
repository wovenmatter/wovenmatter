import { ConversationTranscript } from '@earendil-works/pi-durable';

// Keep Woven's device snapshot/progress wire format while consuming Durable's
// state watches. Recover window gaps before publishing; an overflow must not
// lose committed replies, tool results or background-progress receipts.
export async function watchConversation(conversation, context) {
  const watch = await conversation.watch(context);
  const transcript = new ConversationTranscript((query, limit, ctx) => conversation.entries(query, limit, undefined, ctx));
  const project = async value => {
    let view = transcript.merge(value);
    while (view.items.some(item => item.kind !== 'entry')) {
      const missing = view.items.find(item => item.kind !== 'entry');
      view = missing.kind === 'earlier' ? await transcript.loadEarlier(context) : await transcript.fillGap(missing, context);
    }
    return { type: 'snapshot', conversationId: value.conversation.id,
      entries: view.items.map(item => item.entry), ...view.docs['pi.live'],
      agent: view.docs['pi.agent'], inbox: view.docs['pi.inbox'], usage: view.docs['pi.usage'] };
  };
  let snapshot;
  try { snapshot = await project(watch.value); }
  catch (error) { await watch.stop(); throw error; }
  let newest = snapshot.entries.at(-1)?.id ?? -1;
  let running = new Set(), pending;
  return {
    get snapshot() { return snapshot; }, closed: watch.closed, stop: async () => { const end = await watch.stop(); await pending; return end; },
    start(listener) {
      watch.start(({ value }) => pending = (async () => {
        const next = await project(value), events = [];
        const slots = [...(next.tools ?? []), ...(next.nestedTools ?? [])];
        const active = new Set(slots.filter(slot => slot.status === 'running').map(slot => slot.callId));
        for (const slot of slots) if (slot.status === 'running' && !running.has(slot.callId))
          events.push({ type: 'tool_execution_start', toolCallId: slot.callId, toolName: slot.name, args: slot.arguments });
        for (const entry of next.entries) if (entry.id > newest) {
          // These notifications derive from committed entries, never from a
          // polling tick or an unchanged snapshot (mobile background budgets).
          const completed = entry.model?.some(message => ['assistant', 'toolResult'].includes(message.role));
          events.push({ type: completed ? 'message_end' : 'entry_appended', entry });
          newest = entry.id;
        }
        if (snapshot.run && !next.run) events.push({ type: 'run_end' });
        snapshot = next; running = active;
        events.push(next);
        await listener(events);
      })());
    },
  };
}
