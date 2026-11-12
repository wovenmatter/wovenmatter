import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import type { BotManager } from "./bots.ts";
import type { BotEnvironmentAdapter } from "./env.ts";
import type { UpdateResult } from "./environment/container.ts";
import type { PreviewManager } from "./environment/previews.ts";
import type { EnvironmentSummary, ServerMessage } from "./protocol.ts";

/** What a bot is told after an update stopped its turn. */
export const INTERRUPTED_NOTE =
  "[Woven Matter: your environment was just updated, which stopped your last turn part-way. Your files, restart list and browser are back. Check what was left unfinished and continue if it still needs doing.]";

/**
 * Operations on bots' environments that the Woven UI starts: status, stop, rebuild and the
 * all-bots update. They belong to the runtime, not to a single bot's tools.
 */
export class RuntimeOperations {
  readonly #manager: BotManager;
  readonly #env: BotEnvironmentAdapter | undefined;
  readonly #previews: PreviewManager | undefined;
  readonly #notify: (message: ServerMessage) => void;
  readonly #log: (message: string) => void;
  #updating: Promise<UpdateResult[]> | undefined;

  constructor(options: {
    manager: BotManager;
    env?: BotEnvironmentAdapter;
    previews?: PreviewManager;
    notify?: (message: ServerMessage) => void;
    log?: (message: string) => void;
  }) {
    this.#manager = options.manager;
    this.#env = options.env;
    this.#previews = options.previews;
    this.#notify = options.notify ?? (() => {});
    this.#log = options.log ?? (() => {});
  }

  #requireEnv(): BotEnvironmentAdapter {
    if (!this.#env) throw new Error("bots on this machine have no environment");
    return this.#env;
  }

  async environment(botId: string): Promise<EnvironmentSummary> {
    await this.#manager.record(botId);
    const env = this.#env;
    const previews = (this.#previews?.list(botId) ?? []).map((p) => ({ port: p.containerPort, url: p.url }));
    if (!env?.state) return { botId, state: "unavailable", previews };
    let state: EnvironmentSummary["state"];
    try {
      state = await env.state(botId);
    } catch {
      return { botId, state: "unavailable", previews };
    }
    const lastActivity = env.lastActivity?.(botId);
    let busy: string | undefined;
    let services: unknown[] | undefined;
    if (state === "running") {
      busy = await env.busyReason?.(botId).catch(() => undefined);
      if (env.control) {
        const context = withAbortSignal(AbortSignal.timeout(10_000), BACKGROUND_CONTEXT);
        services = (await env.control(botId, "services.list", {}, context).catch(() => undefined)) as
          | unknown[]
          | undefined;
      }
    }
    return {
      botId,
      state,
      ...(busy ? { busy } : {}),
      ...(lastActivity ? { lastActivity } : {}),
      ...(services ? { services } : {}),
      previews,
    };
  }

  async stop(botId: string): Promise<void> {
    await this.#manager.record(botId);
    const env = this.#requireEnv();
    if (!env.stop) throw new Error("this environment cannot stop bots");
    await env.stop(botId);
    this.#notify({ type: "bots.environment.changed", botId, state: "stopped" });
  }

  async rebuild(botId: string): Promise<void> {
    await this.#manager.record(botId);
    const env = this.#requireEnv();
    if (!env.rebuild) throw new Error("this environment cannot rebuild bots");
    await env.rebuild(botId);
    this.#notify({ type: "bots.environment.changed", botId, state: "running" });
  }

  /** Conversations (main and threads) of a bot with a turn running now. */
  async #running(botId: string): Promise<number[]> {
    const bot = await this.#manager.get(botId);
    const live = await bot.harness.inspect(BACKGROUND_CONTEXT);
    const busy = new Set<number>([
      ...live.tasks.map((task) => Number(task.record.conversationId)),
      ...live.submissions.map((submission) => Number(submission.conversationId)),
    ]);
    const own = (await bot.conversations()).map((conversation) => conversation.conversationId);
    return own.filter((id) => busy.has(id));
  }

  /** The update, one at a time; a second request joins the running one. */
  update(botIds?: readonly string[]): Promise<UpdateResult[]> {
    if (this.#updating) return this.#updating;
    const run = this.#update(botIds).finally(() => {
      this.#updating = undefined;
    });
    this.#updating = run;
    return run;
  }

  async #update(requested?: readonly string[]): Promise<UpdateResult[]> {
    const env = this.#requireEnv();
    if (!env.updateBot) throw new Error("this environment cannot update bots");
    const ids = requested?.length ? [...requested] : (await this.#manager.list()).map((bot) => bot.id);
    // Stop running work first, everywhere, so nothing writes while snapshots are taken.
    const interrupted = new Map<string, number[]>();
    for (const botId of ids) {
      this.#notify({ type: "runtime.update", botId, phase: "stopping" });
      const conversations = await this.#running(botId).catch(() => []);
      const bot = await this.#manager.get(botId);
      for (const conversationId of conversations) await bot.abort(conversationId).catch(() => {});
      if (conversations.length) interrupted.set(botId, conversations);
    }
    const results: UpdateResult[] = [];
    for (const botId of ids) {
      this.#notify({ type: "runtime.update", botId, phase: "updating" });
      let result: UpdateResult;
      try {
        result = await env.updateBot(botId);
      } catch (error) {
        result = { botId, ok: false, error: error instanceof Error ? error.message : String(error) };
      }
      results.push(result);
      this.#notify({
        type: "runtime.update",
        botId,
        phase: result.skipped ? "skipped" : result.ok ? "updated" : "rolledBack",
        ...(result.error ? { error: result.error } : {}),
      });
      this.#notify({ type: "bots.environment.changed", botId, state: result.skipped ? "missing" : "running" });
      if (!result.ok && !result.rolledBack) this.#log(`bot ${botId}: update failed: ${result.error}`);
    }
    for (const [botId, conversations] of interrupted) {
      const bot = await this.#manager.get(botId).catch(() => undefined);
      for (const conversationId of conversations) {
        await bot?.send(INTERRUPTED_NOTE, conversationId).catch((error: unknown) =>
          this.#log(`bot ${botId}: could not tell it about the update: ${String(error)}`),
        );
      }
    }
    this.#notify({ type: "runtime.update", phase: "done" });
    return results;
  }
}
