import { mkdtempSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createModels } from "@earendil-works/pi-ai/models";
import {
  type FauxResponseStep,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
} from "@earendil-works/pi-ai/providers/faux";
import { createBotHarnessOptions } from "../src/agent.ts";
import { BotManager, type BotManagerOptions } from "../src/bots.ts";
import { type ModelRef, normalizeProfiles, type Profile, parseModelRef } from "../src/config.ts";
import { parseSettings } from "../src/settings/store.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import type { TitleGenerator } from "../src/titles.ts";

export const FAUX_MODEL = { provider: "faux", modelId: "faux-1" } as const;

/** A one-off profile with `main` as its main model. */
export function profileOf(main: ModelRef, pool: Profile["pool"] = []): Profile {
  return { id: "default", name: "Default", main: `${main.provider}/${main.modelId}`, pool };
}

/** Settings as the runtime reads them from settings.json, with normalized profiles. */
export function parseTestSettings(input: Record<string, unknown>) {
  const settings = parseSettings(input);
  return {
    ...settings,
    modelProfiles: normalizeProfiles(settings),
    roles: { titles: parseModelRef(settings.titles.model) },
  };
}

export async function tempDir(): Promise<{ path: string; cleanup: () => Promise<void> }> {
  const path = await mkdtemp(join(tmpdir(), "pi-bot-test-"));
  return { path, cleanup: () => rm(path, { recursive: true, force: true }) };
}

type ContextLike = { messages?: readonly { role: string; content: unknown }[] };

function lastUserText(context: ContextLike): string {
  const users = (context.messages ?? []).filter((message) => message.role === "user");
  const content = users.at(-1)?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((block): block is { type: "text"; text: string } => block?.type === "text")
      .map((block) => block.text)
      .join("");
  }
  return "";
}

/** Faux models that answer `echo: <last user text>` (n<user messages seen>) forever. */
export function echoModels(tokensPerSecond = 2000) {
  // One-token (4 char) chunks; pi-durable publishes partial messages every 100 ms.
  const faux = fauxProvider({ tokensPerSecond, tokenSize: { min: 1, max: 1 } });
  const echo: FauxResponseStep = (context) => {
    const ctx = context as unknown as ContextLike;
    const seen = (ctx.messages ?? []).filter((message) => message.role === "user").length;
    return fauxAssistantMessage([fauxText(`echo: ${lastUserText(ctx)} (n${seen})`)]);
  };
  faux.setResponses(Array.from({ length: 200 }, () => echo));
  const models = createModels();
  models.setProvider(faux.provider);
  return { faux, models };
}

export async function openTestManager(
  dbPath: string,
  options: {
    titles?: TitleGenerator;
    onReport?: (error: unknown) => void;
    onRecovered?: BotManagerOptions["onRecovered"];
    onBotDeleted?: BotManagerOptions["onBotDeleted"];
    onBotPurged?: BotManagerOptions["onBotPurged"];
    ensureAdmin?: boolean;
    onThreadsChanged?: BotManagerOptions["onThreadsChanged"];
    tokensPerSecond?: number;
  } = {},
) {
  const { tokensPerSecond, ...managerOptions } = options;
  const db = await openSharedDatabase(dbPath);
  const { faux, models } = echoModels(tokensPerSecond);
  const manager = await BotManager.open({
    db,
    ...managerOptions,
    harnessOptions: (bot, self) =>
      createBotHarnessOptions({
        bot,
        models,
        profile: () =>
          self.profiles?.resolve(self.assignedProfile(bot.id)) ?? profileOf(FAUX_MODEL),
      }),
  });
  return {
    db,
    faux,
    models,
    manager,
    close: async () => {
      await manager.close();
      await db.close();
    },
  };
}

/**
 * Unix socket paths are limited by sun_path: 104 bytes on macOS, 108 on Linux. A long
 * TMPDIR (a sandbox's per-session temp folder, a deep worktree) would push the sockets
 * past it, and a listen that fails silently becomes a test timeout. Sockets stay under
 * the test's own folder when they fit, and otherwise go to a short private /tmp folder.
 */
export function socketDirectory(root: string, longestName = "00000000.sock"): string {
  if (Buffer.byteLength(join(root, longestName)) < 100) return root;
  return mkdtempSync("/tmp/wbt-");
}
