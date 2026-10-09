import { Type } from 'typebox';

// A normal Pi coding-tool definition, adapted and journaled by Durable like
// the other native tools. Each successful result is a complete replacement.
export const checklistTool = {
  name: 'update_checklist', label: 'Update checklist',
  description: 'Replace the checklist for the current task. Use stable IDs and report only actual progress; mark completed only after the work is done. This is a work checklist, not a proposed plan. Send all items on each update, or an empty list to clear it.',
  parameters: Type.Object({ todos: Type.Array(Type.Object({
    id: Type.String({ minLength: 1, maxLength: 128 }),
    content: Type.String({ minLength: 1, maxLength: 256 }),
    status: Type.Union(['pending', 'in_progress', 'completed', 'cancelled'].map(status => Type.Literal(status))),
  // These bounds keep even astral Unicode within the lossless plan preview.
  }, { additionalProperties: false }), { maxItems: 32 }) }, { additionalProperties: false }),
  execute: async (_id, { todos }, signal) => {
    signal?.throwIfAborted();
    if (new Set(todos.map(item => item.id)).size !== todos.length) throw new Error('Checklist IDs must be unique.');
    const entries = todos.map(({ id, content, status }) => ({ id, content, status }));
    return { content: [{ type: 'text', text: JSON.stringify({ todos: entries }) }], details: { wovenChecklist: entries } };
  },
};
