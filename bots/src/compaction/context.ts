import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Api, FetchFunction, Message, Model, Models } from "@earendil-works/pi-ai";
import {
  AgentDoc,
  type ContextView,
  type Conversation,
  createRegistry,
  defineDoc,
  type EntryId,
  type Harness,
  type HookApi,
  type JsonObject,
  type Registry,
} from "@earendil-works/pi-durable";
import { type BeforeCompactHook, noopBeforeCompact } from "../memory.ts";
import {
  applyWindow,
  compactNative,
  type NativeRoute,
  type NativeWindow,
  nativeStrategy,
  sameRoute,
  summaryMessage,
} from "./native.ts";

/**
 * Compaction for every conversation of a bot: the main channel and every thread run exactly this
 * code. Ported from Woven Matter's `default-agent/src/native-context.mjs`,
 * `native-compaction-registry.mjs` and the hooks in `durable-session.mjs`.
 *
 * Pi Durable decides when to compact (thresholds, overflow recovery, manual) and selects the
 * covered prefix. `beforeCompact` then runs the provider's native compaction, records the opaque
 * window in a rewindable conversation doc, appends a head-marker entry, and declines the built-in
 * summarizer. `beforeRequest` replays the window in front of later requests on the same route.
 * Models without native compaction get Pi Durable's summarizer. Covered entries are never deleted:
 * a head marker only moves the start of the model context, so SQLite keeps the full history.
 */

export const NATIVE_COMPACTION_KIND = "pibot.native-compaction";

type ActiveWindow = {
  /** Which compaction produced it; matches the head entry's `data.id`. */
  readonly id: string;
  readonly route: NativeRoute;
  readonly window?: NativeWindow;
  /** Portable summary text for a route without native compaction (after a model change). */
  readonly summary?: string;
};

export type NativeContextState = {
  /** Every entry a native compaction has covered, oldest first. */
  covered: number[];
  active?: ActiveWindow;
  /** The compaction task that wrote the current head, for idempotent retries and overflow recovery. */
  receipt?: { taskId: number; entryId: number };
};

export const NativeContextDoc = defineDoc<NativeContextState & JsonObject>({
  kind: "pibot.native-context",
  version: 1,
  scope: "conversation",
  history: "rewindable",
  fork: "current",
  checkpointWhen: () => false,
  initial: () => ({ covered: [] }),
});

export type CompactionOptions = {
  /** `"off"` disables provider-native compaction; Pi Durable's summarizer then always runs. */
  readonly native?: "auto" | "off";
  /** Fetch for native compaction and generation requests; tests inject a fake. */
  readonly fetch?: FetchFunction;
  /** The memory-extraction hook every compaction calls first. */
  readonly onBeforeCompact?: BeforeCompactHook;
  readonly onReport?: (error: unknown, info: unknown) => void;
};

/** A late-bound handle: hook APIs read docs but cannot commit, so hooks commit through the Harness. */
export class HarnessRef {
  #harness: Harness | undefined;
  attach(harness: Harness): void {
    this.#harness = harness;
  }
  async conversation(id: HookApi["conversationId"]): Promise<Conversation> {
    if (!this.#harness) throw new Error("the bot harness is not open yet");
    const conversation = await this.#harness.conversation(id, BACKGROUND_CONTEXT);
    if (!conversation) throw new Error(`conversation ${id} is not open`);
    return conversation;
  }
}

type Compaction = Parameters<
  NonNullable<import("@earendil-works/pi-durable").CompactionHooks["beforeCompact"]>
>[0];
type HookContext = Parameters<
  NonNullable<import("@earendil-works/pi-durable").CompactionHooks["beforeCompact"]>
>[2];

const PORTABLE_PROMPT =
  "Summarize the conversation above as a context checkpoint another assistant will continue from. " +
  "Keep the user's goals, constraints, decisions, open requests, exact names, paths and errors. " +
  "Do not continue the conversation and do not call tools; answer with the summary only.";

function currentSystem(messages: readonly Message[]): Message | undefined {
  return messages.findLast((message) => message.role === "system");
}

function withoutSystem(messages: readonly Message[]): Message[] {
  return messages.filter((message) => message.role !== "system");
}

function previousId(id: EntryId): EntryId {
  return ((id as unknown as number) - 1) as unknown as EntryId;
}

/** The composition: hooks, a models proxy and a registry, shared by main and every thread. */
export class NativeCompaction {
  readonly harness = new HarnessRef();
  readonly #options: CompactionOptions;
  readonly #windows = new WeakMap<Message, NativeWindow>();
  readonly #models: () => Models;

  constructor(models: () => Models, options: CompactionOptions = {}) {
    this.#models = models;
    this.#options = options;
  }

  /** Models whose requests carry the active native window; `transport: "sse"` like Woven. */
  models(): Models {
    const windows = this.#windows;
    const fetch = this.#options.fetch;
    const base = this.#models;
    return new Proxy({} as Models, {
      get(_target, key) {
        const models = base();
        if (key === "streamSimple" || key === "stream") {
          return (
            model: Model<Api>,
            input: { messages: readonly Message[] },
            options?: Record<string, unknown>,
          ) => {
            const first = input.messages[0];
            const window = first ? windows.get(first) : undefined;
            const onPayload = options?.onPayload as
              | ((payload: unknown, model: Model<Api>) => unknown)
              | undefined;
            const merged = {
              ...options,
              ...(fetch && !options?.fetch ? { fetch } : {}),
              ...(key === "streamSimple" && !options?.transport ? { transport: "sse" } : {}),
              ...(window
                ? {
                    onPayload: async (payload: unknown, target: Model<Api>) => {
                      const next = (await onPayload?.(payload, target)) ?? payload;
                      return applyWindow(next as JsonObject, window);
                    },
                  }
                : {}),
            };
            return (models[key] as (...args: unknown[]) => unknown).call(
              models,
              model,
              input,
              merged,
            );
          };
        }
        if (key === "completeSimple" || key === "complete") {
          return (model: Model<Api>, input: unknown, options?: Record<string, unknown>) =>
            (models[key] as (...args: unknown[]) => unknown).call(models, model, input, {
              ...options,
              ...(fetch && !options?.fetch ? { fetch } : {}),
            });
        }
        const value = Reflect.get(models, key, models);
        return typeof value === "function" ? value.bind(models) : value;
      },
    });
  }

  async #model(api: HookApi, ctx: HookContext): Promise<Model<Api> | undefined> {
    const agent = await api.snapshot(AgentDoc, api.conversationId, ctx);
    const ref = agent?.model;
    return ref ? this.#models().getModel(ref.provider, ref.modelId) : undefined;
  }

  #native(model: Model<Api>): boolean {
    return this.#options.native !== "off" && nativeStrategy(model) !== undefined;
  }

  /**
   * The original model messages of every entry before `before` in `view`, rebuilt from SQLite. A
   * native head marker stands for opaque provider state, so it is replaced, recursively, by what it
   * covered: the entries before its `head` in the view just before the marker was written. Pi
   * Durable summaries are readable and stay as they are.
   */
  async #original(
    conversation: Conversation,
    view: ContextView,
    before: EntryId,
    ctx: HookContext,
  ): Promise<Message[]> {
    let prefix: Message[] = [];
    let start = 0;
    const head = view.head;
    if (head?.kind === NATIVE_COMPACTION_KIND && head.head !== undefined) {
      const page = await conversation.entries(
        { maxEntryId: previousId(head.id), order: "descending" },
        1,
        undefined,
        ctx,
      );
      const previous = page.items[0];
      if (previous) {
        const earlier = await conversation.context(ctx, { at: previous.id });
        prefix = await this.#original(conversation, earlier, head.head, ctx);
      }
      start = 1;
    }
    const own = view.entries.flatMap((entry, index) =>
      index >= start && (entry.id as unknown as number) < (before as unknown as number)
        ? [...(view.contributions[index] ?? [])]
        : [],
    );
    return [...prefix, ...withoutSystem(own)];
  }

  async #portable(
    model: Model<Api>,
    messages: readonly Message[],
    instructions?: string,
  ): Promise<string> {
    const now = Date.now();
    const reply = await this.models().completeSimple(
      model,
      {
        messages: [
          ...messages,
          {
            role: "user",
            content: [
              {
                type: "text",
                text: instructions
                  ? `${PORTABLE_PROMPT}\n\nFocus: ${instructions}`
                  : PORTABLE_PROMPT,
              },
            ],
            timestamp: now,
          },
        ],
      },
      { maxRetries: 0 },
    );
    const text = reply.content
      .flatMap((part) => (part.type === "text" ? [part.text] : []))
      .join("\n")
      .trim();
    if (reply.stopReason !== "stop" || !text) {
      throw new Error(`portable compaction failed: ${reply.errorMessage ?? reply.stopReason}`);
    }
    return text;
  }

  /** `pi.compaction` → `beforeCompact`. */
  readonly beforeCompact = async (
    compaction: Compaction,
    api: HookApi,
    ctx: HookContext,
  ): Promise<{ decline: true } | { summary: string } | undefined> => {
    try {
      await (this.#options.onBeforeCompact ?? noopBeforeCompact)(
        {
          conversationId: api.conversationId as unknown as number,
          reason: compaction.reason,
          entries: compaction.entries,
          messages: compaction.messages,
        },
        ctx,
      );
    } catch (error) {
      if (ctx.abortSignal?.aborted) throw error;
      this.#options.onReport?.(error, { kind: "before-compact-failed" });
    }
    const saved = (await api.snapshot(NativeContextDoc, api.conversationId, ctx)) ?? {
      covered: [],
    };
    // The window and its receipt commit together, so a retried task completes without recompacting.
    if (saved.receipt?.taskId === (api.taskId as unknown as number)) return { decline: true };
    const model = await this.#model(api, ctx);
    if (!model) return undefined;
    const conversation = await this.harness.conversation(api.conversationId);
    const head = compaction.entries[0];
    const nativeHead = head?.kind === NATIVE_COMPACTION_KIND ? head : undefined;
    const coveredIds = compaction.entries
      .filter((entry) => entry !== nativeHead)
      .map((entry) => entry.id as unknown as number);
    const system =
      currentSystem(compaction.messages) ??
      currentSystem((await conversation.context(ctx)).messages);
    const delta = withoutSystem(compaction.messages);

    if (this.#native(model)) {
      const route = { provider: model.provider, modelId: model.id, api: model.api };
      const active = saved.active;
      const continues =
        nativeHead !== undefined &&
        active?.id === (nativeHead.data as { id?: unknown } | undefined)?.id &&
        active?.window !== undefined &&
        active.route.provider === route.provider &&
        active.route.modelId === route.modelId &&
        active.route.api === route.api;
      // The same route continues from its own window; another route recompacts the original history.
      const covered =
        nativeHead && !continues
          ? [
              ...(await this.#original(
                conversation,
                await conversation.context(ctx),
                compaction.firstKept,
                ctx,
              )),
            ]
          : delta;
      try {
        const outcome = await compactNative({
          models: this.models(),
          model,
          messages: [...(system ? [system] : []), ...covered],
          ...(continues && active?.window ? { prior: active.window } : {}),
          ...(compaction.instructions ? { instructions: compaction.instructions } : {}),
          ...(this.#options.fetch ? { fetch: this.#options.fetch } : {}),
          signal: ctx.abortSignal,
        });
        if (!("unsupported" in outcome)) {
          await this.#commit(conversation, api, compaction, saved, coveredIds, system, {
            id: `${api.taskId}`,
            route: outcome.route,
            window: outcome.window,
          });
          return { decline: true };
        }
        this.#options.onReport?.(new Error(outcome.unsupported), {
          kind: "native-compaction-unsupported",
        });
      } catch (error) {
        if (ctx.abortSignal?.aborted) throw error;
        this.#options.onReport?.(error, { kind: "native-compaction-failed" });
      }
    }
    // Fallback. With no native window in context, Pi Durable's own summarizer covers everything.
    if (!nativeHead) return undefined;
    // An opaque window cannot be read by a summarizer: summarize the original history instead.
    const original = await this.#original(
      conversation,
      await conversation.context(ctx),
      compaction.firstKept,
      ctx,
    );
    const summary = await this.#portable(
      model,
      [...(system ? [system] : []), ...original],
      compaction.instructions,
    );
    await conversation.commit(async (tx) => {
      const current = await tx.doc(NativeContextDoc, conversation.id);
      delete current.active;
    }, ctx);
    return { summary };
  };

  async #commit(
    conversation: Conversation,
    api: HookApi,
    compaction: Compaction,
    saved: NativeContextState,
    coveredIds: readonly number[],
    system: Message | undefined,
    active: ActiveWindow,
  ): Promise<void> {
    const covered = [...new Set([...saved.covered, ...coveredIds])];
    await conversation.commit(async (tx) => {
      const entry = await tx.appendEntry(conversation.id, {
        kind: NATIVE_COMPACTION_KIND,
        head: compaction.firstKept,
        model: system ? [system] : [],
        data: { id: active.id, reason: compaction.reason, strategy: active.route.strategy },
      });
      const current = await tx.doc(NativeContextDoc, conversation.id);
      current.covered = covered;
      current.active = structuredClone(active) as typeof current.active;
      current.receipt = {
        taskId: api.taskId as unknown as number,
        entryId: entry.id as unknown as number,
      };
    }, BACKGROUND_CONTEXT);
  }

  /** `pi.generation` → `beforeRequest`: put the active window in front of this request. */
  readonly beforeRequest = async (
    request: { readonly messages: readonly Message[] },
    api: HookApi,
    ctx: HookContext,
  ): Promise<{ readonly messages: readonly Message[] } | undefined> => {
    const state = await api.snapshot(NativeContextDoc, api.conversationId, ctx);
    const active = state?.active;
    if (!active) return undefined;
    const conversation = await this.harness.conversation(api.conversationId);
    const view = await conversation.context(ctx);
    if (
      view.head?.kind !== NATIVE_COMPACTION_KIND ||
      (view.head.data as { id?: unknown } | undefined)?.id !== active.id
    ) {
      return undefined;
    }
    const model = await this.#model(api, ctx);
    if (!model) return undefined;
    const strategy = nativeStrategy(model);
    const route: NativeRoute | undefined =
      strategy && this.#options.native !== "off"
        ? {
            provider: model.provider,
            modelId: model.id,
            api: model.api,
            strategy,
            endpoint: active.route.endpoint,
          }
        : undefined;
    let current = active;
    if (
      !(current.window && sameRoute(current.route, route)) &&
      !(
        current.summary &&
        current.route.modelId === model.id &&
        current.route.provider === model.provider
      )
    ) {
      current = await this.#reproject(conversation, view.head.head, model, active, ctx);
    }
    const [first, ...rest] = request.messages;
    const summary =
      current.summary ?? (current.window?.kind === "summary" ? current.window.text : undefined);
    if (summary !== undefined) {
      const system = first?.role === "system" ? [first] : [];
      const others = first?.role === "system" ? rest : request.messages;
      return { messages: [...system, summaryMessage(summary), ...others] };
    }
    if (!first || !current.window) return undefined;
    // A fresh object identifies this request's message list to the models proxy.
    const key = { ...first } as Message;
    this.#windows.set(key, current.window);
    return { messages: [key, ...rest] };
  };

  /** The model changed since the last native compaction: rebuild the covered history for it. */
  async #reproject(
    conversation: Conversation,
    firstKept: EntryId | undefined,
    model: Model<Api>,
    active: ActiveWindow,
    ctx: HookContext,
  ): Promise<ActiveWindow> {
    if (firstKept === undefined) return active;
    const view = await conversation.context(ctx);
    const original = await this.#original(conversation, view, firstKept, ctx);
    const system = currentSystem(view.messages);
    const messages = [...(system ? [system] : []), ...original];
    let next: ActiveWindow | undefined;
    if (this.#native(model)) {
      const outcome = await compactNative({
        models: this.models(),
        model,
        messages,
        ...(this.#options.fetch ? { fetch: this.#options.fetch } : {}),
        signal: ctx.abortSignal,
      });
      if (!("unsupported" in outcome))
        next = { id: active.id, route: outcome.route, window: outcome.window };
    }
    next ??= {
      id: active.id,
      route: { ...active.route, provider: model.provider, modelId: model.id, api: model.api },
      summary: await this.#portable(model, messages),
    };
    const saved = next;
    await conversation.commit(async (tx) => {
      const current = await tx.doc(NativeContextDoc, conversation.id);
      current.active = structuredClone(saved) as typeof current.active;
    }, BACKGROUND_CONTEXT);
    return next;
  }
}

/**
 * Woven's `createNativeCompactionRegistry`: a declined compaction completes with an empty result,
 * but overflow recovery needs the entry that made the context smaller. Decorate the `pi.compaction`
 * select phase so its terminal result carries the head entry from the doc receipt.
 */
export function createCompactionRegistry(): Registry {
  const registry = createRegistry();
  const snapshots = new WeakMap<object, unknown>();
  const tasks = new WeakMap<object, unknown>();
  // biome-ignore lint/suspicious/noExplicitAny: decorating Pi Durable's internal task shape.
  const decorate = (task: any) => {
    if (task?.definition?.name !== "pi.compaction") return task;
    if (!tasks.has(task)) {
      const select = task.definition.phases.select;
      tasks.set(task, {
        ...task,
        definition: {
          ...task.definition,
          phases: {
            ...task.definition.phases,
            // biome-ignore lint/suspicious/noExplicitAny: Pi Durable task runtime.
            select: (current: unknown, runtime: any, context: unknown) => {
              // biome-ignore lint/suspicious/noExplicitAny: Pi Durable transaction.
              const commit = (change: any, callContext: unknown) =>
                // biome-ignore lint/suspicious/noExplicitAny: Pi Durable transaction.
                runtime.commit(async (tx: any, live: unknown) => {
                  const next = await change(tx, live);
                  const result = next?.outcome?.result;
                  if (
                    next?.status !== "terminal" ||
                    next.outcome?.status !== "completed" ||
                    result?.entryId !== undefined ||
                    result?.submissionId !== undefined
                  ) {
                    return next;
                  }
                  const receipt = (await tx.doc(NativeContextDoc, runtime.conversationId)).receipt;
                  if (receipt?.taskId !== runtime.taskId) return next;
                  const entry = await tx.entry(receipt.entryId);
                  if (
                    entry?.kind !== NATIVE_COMPACTION_KIND ||
                    entry.conversationId !== runtime.conversationId
                  ) {
                    return next;
                  }
                  return {
                    ...next,
                    outcome: { ...next.outcome, result: { ...result, entryId: entry.id } },
                  };
                }, callContext);
              const scoped = new Proxy(runtime, {
                get(target, key) {
                  if (key === "commit") return commit;
                  const value = Reflect.get(target, key, target);
                  return typeof value === "function" ? value.bind(target) : value;
                },
              });
              return select(current, scoped, context);
            },
          },
        },
      });
    }
    return tasks.get(task);
  };
  const snapshot = () => {
    const current = registry.snapshot();
    if (!snapshots.has(current)) {
      snapshots.set(
        current,
        new Proxy(current, {
          get(target, key) {
            if (key === "task") return (name: string) => decorate(target.task(name));
            if (key === "tasks") return () => target.tasks().map(decorate);
            const value = Reflect.get(target, key, target);
            return typeof value === "function" ? value.bind(target) : value;
          },
        }),
      );
    }
    return snapshots.get(current);
  };
  return new Proxy(registry, {
    get(target, key) {
      if (key === "snapshot") return snapshot;
      const value = Reflect.get(target, key, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  }) as Registry;
}
