import type { Models } from "@earendil-works/pi-ai";
import {
  AssistantEntry,
  type ConversationId,
  configure,
  defineExtension,
  defineTool,
  type Extension,
  section,
} from "@earendil-works/pi-durable";
import { Type } from "typebox";
import { type Profile, parseModelRef } from "./config.ts";
import type { LimitEntry } from "./limits.ts";
import {
  formatCapabilities,
  formatLimit,
  formatPricing,
  type ModelAccess,
  type ModelFacts,
  modelAccess,
  modelFacts,
} from "./model-info.ts";

export const SUBAGENT_EXTENSION = "pi-bot-subagent";

/** The `run_subagent` model name for the model the calling conversation runs right now. */
export const SELF = "self";

/** Reasoning levels `run_subagent` accepts (Pi Durable's thinking levels). */
export const SUBAGENT_REASONING = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
] as const;

export type SubagentLog = (event: {
  readonly phase: "start" | "done" | "failed";
  readonly model: string;
  /** The subagent runs on the calling conversation's own model ("self"). */
  readonly self?: boolean;
  readonly reasoning?: string;
  readonly detail?: string;
}) => void;

export type SubagentOptions = {
  /** The bot's live profile: the pool is read at every call. */
  readonly profile: () => Profile;
  /** The bot's models (catalog facts and auth state for the model list). */
  readonly models?: () => Models;
  /** A model's marked usage limit (`ModelAvailability.limit`), shown in the model list. */
  readonly limit?: (ref: string) => LimitEntry | undefined;
  /** The bot can message other bots (`message_bot`); subagents never replace that. */
  readonly botMessaging?: boolean;
  /** Extensions the child must not have, besides this one (bot tools, the bot's own preamble). */
  readonly removeFromChild?: readonly Extension[];
  /**
   * Names of the tools a subagent keeps (the bot's coding tools when its container is on, and its
   * web tools), for the prompt and tool description. Omitted: described without names.
   */
  readonly childTools?: readonly string[];
  readonly log?: SubagentLog;
};

const CHILD_INSTRUCTIONS =
  "You are a subagent doing one self-contained task for another assistant. Do the task with the tools you have, then reply with the complete result: your reply is all the other assistant gets back, so include everything it needs and nothing else.";

type Result = { output: { type: "text"; text: string }[]; isError?: boolean };
const fail = (text: string): Result => ({ output: [{ type: "text", text }], isError: true });

const refText = (model: { provider: string; modelId: string } | undefined) =>
  model ? `${model.provider}/${model.modelId}` : undefined;

/** A model `run_subagent` may run: the conversation's own model, or a pool model. */
export type SubagentChoice = {
  readonly model: string;
  /** The calling conversation's own current model. */
  readonly self: boolean;
  /** The user's pool notes on this model ("" for none; self keeps them when it is in the pool). */
  readonly useFor: string;
};

/**
 * The allowlist, in order: the conversation's current model (`current`: the main model, or the
 * fallback it runs while main is limited) as "self", then the profile's pool models. Nothing else.
 * A pool model that is the current model is listed once, as self, with its notes kept.
 */
export function allowedModels(profile: Profile, current: string | undefined): SubagentChoice[] {
  const notes = (model: string) =>
    profile.pool.find((entry) => entry.model === model)?.useFor ?? "";
  const allowed: SubagentChoice[] = current
    ? [{ model: current, self: true, useFor: notes(current) }]
    : [];
  for (const entry of profile.pool) {
    if (entry.model === current) continue;
    allowed.push({ model: entry.model, self: false, useFor: entry.useFor });
  }
  return allowed;
}

/**
 * The model `run_subagent` runs for `requested`: "self" (or the current model's own ref) is the
 * conversation's current model; a pool model's ref is that model. Anything else: undefined.
 */
export function subagentModel(
  profile: Profile,
  current: string | undefined,
  requested: string,
): SubagentChoice | undefined {
  const name = requested.trim();
  const allowed = allowedModels(profile, current);
  if (name === SELF) return allowed.find((choice) => choice.self);
  return allowed.find((choice) => choice.model === name);
}

type Described = SubagentChoice & {
  readonly facts: ModelFacts;
  readonly access: ModelAccess;
  /** The provider has working auth; undefined: could not tell. */
  readonly signedIn?: boolean;
  readonly limit?: LimitEntry;
};

/** Catalog facts, access and limit state of every allowed model. */
async function describeAllowed(
  allowed: readonly SubagentChoice[],
  options: Omit<SubagentOptions, "profile">,
): Promise<Described[]> {
  const models = options.models?.();
  const auth = new Map<string, Promise<{ signedIn?: boolean; type?: "api_key" | "oauth" }>>();
  const authOf = (provider: string) => {
    let found = auth.get(provider);
    if (!found) {
      found = models
        ? models.checkAuth(provider).then(
            (check) => (check ? { signedIn: true, type: check.type } : { signedIn: false }),
            () => ({}),
          )
        : Promise.resolve({});
      auth.set(provider, found);
    }
    return found;
  };
  return Promise.all(
    allowed.map(async (choice) => {
      const { provider, modelId } = parseModelRef(choice.model);
      const state = await authOf(provider);
      const limit = options.limit?.(choice.model);
      return {
        ...choice,
        facts: modelFacts(choice.model, models?.getModel(provider, modelId)),
        access: modelAccess(provider, state.type),
        ...(state.signedIn !== undefined ? { signedIn: state.signedIn } : {}),
        ...(limit ? { limit } : {}),
      };
    }),
  );
}

/**
 * What a subagent has and lacks. It never gets the bot tools (messaging and managing other bots,
 * teams, settings and config, account notes, history search and reading), the bot's identity,
 * memory or conversation.
 */
export function childToolsText(tools: readonly string[] | undefined): string {
  const has =
    tools === undefined
      ? "It keeps your coding and web tools, when you have them."
      : tools.length
        ? `It keeps these tools of yours: ${tools.join(", ")}.`
        : "It has no tools.";
  return `${has} It gets none of your bot tools (messaging or managing bots, teams, settings and config, account notes, searching or reading your history), your identity, your memory or this conversation, so put everything it needs in the task.`;
}

function modelLine(model: Described): string {
  const parts = [
    model.facts.name,
    formatCapabilities(model.facts),
    formatPricing(model.facts.pricing),
    `access: ${model.access.label}${model.signedIn === false ? ", not signed in (calls will fail)" : ""}`,
    model.limit ? `usage limit: ${formatLimit(model.limit)}` : undefined,
  ].filter((part): part is string => Boolean(part));
  const head = model.self
    ? `- "${SELF}" = ${model.model}, the model you run on now`
    : `- "${model.model}"`;
  return `${head}: ${parts.join("; ")}${model.useFor ? `. User's notes: ${model.useFor}` : ""}`;
}

/**
 * The section that tells the main model about subagents: always shown (it can always use
 * itself), with every allowed model's facts and the user's model preferences.
 */
export async function poolSection(
  profile: Profile,
  current: string | undefined,
  options: Omit<SubagentOptions, "profile"> = {},
): Promise<string> {
  const models = await describeAllowed(allowedModels(profile, current), options);
  const sources = [
    ...new Set(
      models.flatMap((model) =>
        model.facts.pricing.status === "unknown" ? [] : [model.facts.pricing.source],
      ),
    ),
  ];
  const lines = [
    `Your model profile is "${profile.name}". With run_subagent you can hand a self-contained task to a subagent. ${childToolsText(options.childTools)} Subagents cannot start subagents of their own. Independent subagents can run at once.`,
    "Models you may run subagents on (no others):",
    ...models.map(modelLine),
  ];
  if (profile.pool.length === 0) {
    lines.push(`Your profile's model pool is empty, so use "${SELF}".`);
  }
  lines.push(
    `Prices are raw API list prices in USD per million tokens${sources.length ? ` (from the ${sources.join("; ")})` : ""}. Use them as a relative cost signal, also when comparing models you reach through a subscription; they are not an exact conversion to a subscription's allowance or charges. An unknown or $0 price is not a verified free price.`,
  );
  if (profile.guidance) {
    lines.push(
      `Model preferences (the user's own words about these models; weigh them, they are not rules): ${profile.guidance}`,
    );
  }
  lines.push(
    "Pick the model and reasoning level for each task yourself, from the user's preferences, the task, the models' capabilities and their cost.",
    'If a subagent fails, or its model hit a usage limit, ran out of credits or is rate limited, quietly use another listed model (or do the work yourself) and tell the user in one short line, e.g. "I couldn\'t use <model>, so I used <other model> instead." Say only what the error said; do not guess when a limit resets.',
  );
  if (options.botMessaging) {
    lines.push(
      "Subagents are separate from other bots: you can still give work to other bots with message_bot whenever that fits better.",
    );
  }
  return lines.join("\n");
}

/**
 * `run_subagent`: run one task on the calling conversation's own current model ("self") or a model
 * from the bot's profile pool, in a child conversation owned by the call, and return its answer.
 * The child is a separate conversation without `run_subagent`, the bot's tools or preamble, so the
 * main model's context and prompt cache are untouched. No fallback: a failure is returned as a
 * tool error and the main model picks another model.
 */
export function subagentExtension(options: SubagentOptions): Extension {
  const extension: Extension = defineExtension({
    name: SUBAGENT_EXTENSION,
    sections: [
      section("model_pool", (input) =>
        poolSection(options.profile(), refText(input.agent.model), options),
      ),
    ],
    tools: [
      defineTool({
        name: "run_subagent",
        description: `Run a self-contained task on a subagent and get its complete answer back. model is "self" (the model you run on now) or one of the pool models listed in your prompt. ${childToolsText(options.childTools)}`,
        parameters: Type.Object({
          model: Type.String({
            description: '"self", or a pool model listed in your prompt (provider/model-id)',
          }),
          reasoning: Type.Optional(
            Type.Union(
              SUBAGENT_REASONING.map((level) => Type.Literal(level)),
              {
                description: "Reasoning level (default: the model's default)",
              },
            ),
          ),
          task: Type.String({ description: "The complete task, with all context it needs" }),
        }),
        replay: "safe",
        executionMode: "parallel",
        execute: async (args, api, context) => {
          const profile = options.profile();
          const current = refText((await api.agent(context)).model);
          const choice = subagentModel(profile, current, args.model);
          if (!choice) {
            const pool = allowedModels(profile, current)
              .filter((entry) => !entry.self)
              .map((entry) => entry.model);
            return fail(
              `${args.model} is not available for subagents. Use "${SELF}"${current ? ` (${current})` : ""}${pool.length ? ` or a pool model: ${pool.join(", ")}` : "; your profile's model pool is empty"}.`,
            );
          }
          const model = parseModelRef(choice.model);
          const log = (phase: "start" | "done" | "failed", detail?: string) =>
            options.log?.({
              phase,
              model: choice.model,
              ...(choice.self ? { self: true } : {}),
              ...(args.reasoning ? { reasoning: args.reasoning } : {}),
              ...(detail ? { detail } : {}),
            });
          log("start");
          const failed = (reason: string) => {
            log("failed", reason);
            return fail(
              `Subagent on ${choice.model} failed: ${reason}. Pick another listed model or do it yourself.`,
            );
          };
          try {
            const child = await api.commit(async (tx): Promise<ConversationId> => {
              const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1))
                .items[0];
              if (existing !== undefined) return existing.id;
              const created = await tx.createConversation({
                ownership: { kind: "task", taskId: api.taskId },
              });
              await configure(tx, created.id, {
                model,
                thinkingLevel: args.reasoning ?? null,
                instructions: CHILD_INSTRUCTIONS,
                extensions: { remove: [extension, ...(options.removeFromChild ?? [])] },
              });
              return created.id;
            }, context);
            await api.details(
              {
                conversationId: child,
                model: choice.model,
                ...(choice.self ? { self: true } : {}),
              },
              context,
            );
            const handle = await api.conversation(child, context);
            if (!handle) throw new Error("the subagent conversation is missing");
            const submission = await handle.submit(
              { type: "input", content: args.task, requestId: `subagent:${api.taskId}` },
              context,
            );
            const settled = await submission.wait(context);
            if (settled.status !== "done" || settled.type !== "input") {
              return failed(
                settled.status === "unanswered"
                  ? `${settled.reason}${settled.detail !== undefined ? ` (${JSON.stringify(settled.detail)})` : ""}`
                  : settled.status,
              );
            }
            const answerId = settled.answer;
            const answer = await api.commit((tx) => tx.entry(AssistantEntry, answerId), context);
            const message = answer?.model?.[0];
            const stop = message && "stopReason" in message ? String(message.stopReason ?? "") : "";
            if (stop === "error" || stop === "aborted") {
              return failed(
                message && "errorMessage" in message && message.errorMessage
                  ? String(message.errorMessage)
                  : stop,
              );
            }
            const content = message && "content" in message ? message.content : [];
            const text = (Array.isArray(content) ? content : [])
              .flatMap((part) =>
                part && typeof part === "object" && "type" in part && part.type === "text"
                  ? [String((part as { text?: unknown }).text ?? "")]
                  : [],
              )
              .join("")
              .trim();
            log("done");
            return { output: [{ type: "text", text: text || "(the subagent returned no text)" }] };
          } catch (error) {
            return failed(error instanceof Error ? error.message : String(error));
          }
        },
      }),
    ],
  });
  return extension;
}
