import type { AssistantMessage, Message } from "@earendil-works/pi-ai";
import { contentText } from "@earendil-works/pi-ai";
import type { EntryRecord } from "@earendil-works/pi-durable";
import { stripFallbackNote } from "./limits.ts";
import { stripContextNote } from "./message-context.ts";

/** What clients render for one durable entry. */
export type DisplayEntry = {
  readonly id: number;
  /** The conversation that owns the entry; differs from the viewed one for inherited entries. */
  readonly conversationId: number;
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly error?: string;
  /** An assistant reply the user stopped part-way (`conversation.abort`). */
  readonly stopped?: true;
};

function messageText(message: Message): string {
  if (message.role === "user") {
    // A fallback note in front of a turn is for the model, not the chat.
    return stripContextNote(
      stripFallbackNote(
        typeof message.content === "string" ? message.content : contentText(message.content),
      ),
    );
  }
  if (message.role === "assistant") {
    return message.content
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("");
  }
  return "";
}

/** Chat-visible user and assistant messages; tool results and bookkeeping entries are skipped. */
export function displayEntry(entry: EntryRecord): DisplayEntry | undefined {
  for (const message of entry.model ?? []) {
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = messageText(message);
    const stopReason = message.role === "assistant" ? message.stopReason : undefined;
    const error =
      stopReason === "error"
        ? ((message as AssistantMessage).errorMessage ?? "model error")
        : undefined;
    if (!text && !error) continue;
    return {
      id: entry.id,
      conversationId: entry.conversationId,
      role: message.role,
      text,
      ...(error ? { error } : {}),
      ...(stopReason === "aborted" ? { stopped: true as const } : {}),
    };
  }
  return undefined;
}

export function assistantText(message: AssistantMessage | undefined): string {
  return message ? messageText(message) : "";
}
