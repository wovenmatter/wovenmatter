import type { AssistantMessage, Message, ToolResultMessage } from "@earendil-works/pi-ai";
import { contentText } from "@earendil-works/pi-ai";
import type { EntryRecord } from "@earendil-works/pi-durable";
import { type ErrorIssue, errorIssue } from "./issues.ts";
import { stripFallbackNote } from "./limits.ts";
import { stripContextNote } from "./message-context.ts";
import type { PublishedPage } from "./protocol.ts";

/** What clients render for one durable entry. */
export type DisplayEntry = {
  readonly id: number;
  /** The conversation that owns the entry; differs from the viewed one for inherited entries. */
  readonly conversationId: number;
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly error?: string;
  /** What the user can do about `error` (issues.ts); clients show the matching actions. */
  readonly issue?: ErrorIssue;
  /** An assistant reply the user stopped part-way (`conversation.abort`). */
  readonly stopped?: true;
  /** Pages the bot published here with `render_html`, shown above the text. */
  readonly pages?: readonly PublishedPage[];
};

/** The page a successful `render_html` call published, from its result's details. */
export function publishedPage(message: ToolResultMessage | undefined): PublishedPage | undefined {
  if (!message || message.isError) return undefined;
  const page = (message.details as { wovenPage?: PublishedPage } | undefined)?.wovenPage;
  return page && typeof page.digest === "string" ? page : undefined;
}

/** The chat text of a user or assistant message (notes for the model removed). */
export function messageText(message: Message): string {
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
/** Hidden inputs (Admin Bot's greeting trigger) reach the model, never the chat. */
export function hiddenInput(entry: EntryRecord): boolean {
  const data = entry.data;
  return (
    entry.kind === "bot.input" &&
    !!data &&
    typeof data === "object" &&
    !Array.isArray(data) &&
    data.hidden === true
  );
}

export function displayEntry(entry: EntryRecord): DisplayEntry | undefined {
  if (hiddenInput(entry)) return undefined;
  const pages = (entry.model ?? []).flatMap((message) => {
    const page = message.role === "toolResult" ? publishedPage(message as ToolResultMessage) : undefined;
    return page ? [page] : [];
  });
  const shown = pages.length ? { pages } : {};
  for (const message of entry.model ?? []) {
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = messageText(message);
    const stopReason = message.role === "assistant" ? message.stopReason : undefined;
    const error =
      stopReason === "error"
        ? ((message as AssistantMessage).errorMessage ?? "model error")
        : undefined;
    if (!text && !error) continue;
    const issue = error ? errorIssue(message as AssistantMessage) : undefined;
    return {
      id: entry.id,
      conversationId: entry.conversationId,
      role: message.role,
      text,
      ...(error ? { error } : {}),
      ...(issue ? { issue } : {}),
      ...(stopReason === "aborted" ? { stopped: true as const } : {}),
      ...shown,
    };
  }
  return pages.length
    ? { id: entry.id, conversationId: entry.conversationId, role: "assistant", text: "", pages }
    : undefined;
}

export function assistantText(message: AssistantMessage | undefined): string {
  return message ? messageText(message) : "";
}
