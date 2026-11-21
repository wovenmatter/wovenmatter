/**
 * The longest context a message or Forum post carries, in UTF-16 units: it must match the app's
 * `SendTurn.maximumContextLength`, to which the app trims what it sends.
 */
export const MAX_CONTEXT_LENGTH = 4000;

/** Host context is attached to one user turn; bot messages cannot supply it. */
export function contextNote(context: string): string {
  if (context.length > MAX_CONTEXT_LENGTH) {
    throw new Error(`message context exceeds ${MAX_CONTEXT_LENGTH} characters`);
  }
  return `[Woven Matter context: ${JSON.stringify(context)}]`;
}

export function stripContextNote(text: string): string {
  return text.replace(/^\[Woven Matter context: "(?:[^"\\]|\\.)*"\]\n\n/, "");
}
