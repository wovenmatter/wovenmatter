/** Host context is attached to one user turn; bot messages cannot supply it. */
export function contextNote(context: string): string {
  if (context.length > 4000) throw new Error("message context exceeds 4000 characters");
  return `[Woven Matter context: ${JSON.stringify(context)}]`;
}

export function stripContextNote(text: string): string {
  return text.replace(/^\[Woven Matter context: "(?:[^"\\]|\\.)*"\]\n\n/, "");
}
