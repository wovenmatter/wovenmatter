import type { ConversationId, EntryId } from "@earendil-works/pi-durable";

// pi-durable ids are branded numbers; its own `idFromNumber` is not exported from the package
// root, so wire values from clients are branded here after validation.
function brand<I>(value: number, kind: string): I {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`invalid ${kind} id ${value}`);
  return value as unknown as I;
}

export const conversationId = (value: number): ConversationId =>
  brand<ConversationId>(value, "conversation");
export const entryId = (value: number): EntryId => brand<EntryId>(value, "entry");
