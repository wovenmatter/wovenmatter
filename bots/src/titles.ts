import type { Api, AssistantMessage, Model, Models } from "@earendil-works/pi-ai";
import type { ModelRef } from "./config.ts";

/** `[models.titles]` reasoning levels (pi-ai's simple-stream levels). */
export const TITLE_REASONING = ["minimal", "low", "medium", "high", "xhigh"] as const;
export type TitleReasoning = (typeof TITLE_REASONING)[number];

/**
 * Woven Matter's title prompt, verbatim
 * (`app/Sources/WovenMatterClient/CodexConversationTitleGenerator.swift`, `titleInstructions`).
 */
export const TITLE_INSTRUCTIONS = `Generate a short title that helps the user recognize this conversation later.
Return only JSON in this form: {"title":"..."}.
Aim for 3 to 8 words and fewer than 40 characters.
Name the main topic and requested outcome. Avoid workflow, tool, model or agent names unless they are the subject of the conversation.
Do not claim completion. Do not include quotation marks within the title or end it with punctuation.
Do not call tools or modify files.`;

/** The one user message sent to the title model, as Woven builds it. */
export function titlePrompt(firstPrompt: string): string {
  return `${TITLE_INSTRUCTIONS}\n\nFirst message:\n${firstPrompt}`;
}

function jsonTitle(text: string): string | undefined {
  try {
    const value: unknown = JSON.parse(text);
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const title = (value as { title?: unknown }).title;
      if (typeof title === "string") return title;
    }
  } catch {
    // Not JSON.
  }
  return undefined;
}

const EDGE = " `\"'\n\r\t";

function trimChars(value: string, chars: string): string {
  let start = 0;
  let end = value.length;
  while (start < end && chars.includes(value.charAt(start))) start++;
  while (end > start && chars.includes(value.charAt(end - 1))) end--;
  return value.slice(start, end);
}

/**
 * Port of Woven's `CodexConversationTitleGenerator.sanitize`: take `{"title"}` from the whole
 * reply or its outermost braces, else the first line; strip quotes and backticks, collapse
 * whitespace, drop leading/trailing periods, and cap at 50 characters (47 plus an ellipsis).
 */
export function sanitizeTitle(raw: string): string {
  const trimmed = raw.trim();
  let candidate = jsonTitle(trimmed);
  if (candidate === undefined) {
    const start = trimmed.indexOf("{");
    const end = trimmed.lastIndexOf("}");
    if (start !== -1 && start <= end) candidate = jsonTitle(trimmed.slice(start, end + 1));
  }
  candidate ??= trimmed.split(/\r\n|\r|\n/).find(() => true) ?? "";
  const normalized = trimChars(
    trimChars(candidate, EDGE).split(/\s+/).filter(Boolean).join(" "),
    ".",
  );
  // Swift counts grapheme clusters; code points are close enough here.
  const chars = [...normalized];
  if (chars.length <= 50) return normalized;
  return `${chars.slice(0, 47).join("").trim()}…`;
}

export class TitleError extends Error {
  override name = "TitleError";
}

export type TitleGeneratorOptions = {
  readonly models: Models | (() => Models);
  /**
   * `[models.titles].model`, or else the default profile's main model: the one model that titles
   * every bot's threads. Undefined (nothing chosen yet): titling fails until a model is chosen.
   */
  readonly model: ModelRef | undefined | (() => ModelRef | undefined);
  /** `[models.titles].reasoning`. */
  readonly reasoning: TitleReasoning | (() => TitleReasoning);
  /** Per-request timeout; titles are best-effort. */
  readonly timeoutMs?: number;
};

const replyText = (message: AssistantMessage) =>
  message.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");

/** One title request: no tools, no system prompt, the configured model and reasoning level. */
export class TitleGenerator {
  readonly #options: TitleGeneratorOptions;

  constructor(options: TitleGeneratorOptions) {
    this.#options = options;
  }

  get model(): ModelRef | undefined {
    const model = this.#options.model;
    return typeof model === "function" ? model() : model;
  }

  /** Title `firstPrompt` with the global title model (`[models.titles]`). */
  generate(firstPrompt: string, signal?: AbortSignal): Promise<string> {
    if (signal?.aborted) return Promise.reject(new TitleError("title request aborted"));
    const model = this.model;
    if (!model) return Promise.reject(new TitleError("no title model: choose a main model first"));
    return this.#generateOn(model, firstPrompt, signal);
  }

  async #generateOn(ref: ModelRef, firstPrompt: string, signal?: AbortSignal): Promise<string> {
    const source = this.#options.models;
    const models = typeof source === "function" ? source() : source;
    const { provider, modelId } = ref;
    const model: Model<Api> | undefined = models.getModel(provider, modelId);
    if (!model) throw new TitleError(`unknown title model ${provider}/${modelId}`);
    const timeout = AbortSignal.timeout(this.#options.timeoutMs ?? 60_000);
    const reply = await models
      .streamSimple(
        model,
        {
          messages: [
            { role: "user", content: titlePrompt(firstPrompt.trim()), timestamp: Date.now() },
          ],
        },
        {
          reasoning:
            typeof this.#options.reasoning === "function"
              ? this.#options.reasoning()
              : this.#options.reasoning,
          signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
        },
      )
      .result();
    if (reply.stopReason === "error" || reply.stopReason === "aborted") {
      throw new TitleError(reply.errorMessage ?? `title request ${reply.stopReason}`);
    }
    const title = sanitizeTitle(replyText(reply));
    if (!title) throw new TitleError("the title model returned no title");
    return title;
  }
}
