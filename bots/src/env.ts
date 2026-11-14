import type { Context } from "@earendil-works/chord/context";
import type { HarnessOptions } from "@earendil-works/pi-durable";
import type { Duplex } from "node:stream";

export type HarnessEnvFactory = NonNullable<HarnessOptions["env"]>;

/**
 * Builds the execution environment (filesystem, shell) a bot's tools run in. With an adapter the
 * bot gets Pi Durable's coding tools (bash, read, write, edit), all executing in that environment,
 * plus the container tools (restart list, browser, previews).
 */
export interface BotEnvironmentAdapter {
  readonly kind: string;
  /** The `HarnessOptions.env` callback for one bot. */
  harnessEnv(botId: string): HarnessEnvFactory;
  /** A request to the bot's in-container supervisor (`services.*`, `browser.*`, `ping`). */
  control?(botId: string, method: string, args: Record<string, unknown>, context: Context): Promise<unknown>;
  /** A stream to `port` inside the bot's container (previews); starts the container if needed. */
  connectPort?(botId: string, port: number): Promise<Duplex>;
  /** Something used the bot (a tool call, preview traffic, an open chat): restart its idle clock. */
  touch?(botId: string): void;
  /** Container state for status displays. */
  state?(botId: string): Promise<"missing" | "running" | "stopped">;
  /** Why a running bot is not idle now (undefined: idle). */
  busyReason?(botId: string): Promise<string | undefined>;
  /** When the runtime last saw the bot active (epoch ms). */
  lastActivity?(botId: string): number | undefined;
  /** Stop the bot's container now; the next tool call starts it again. */
  stop?(botId: string): Promise<void>;
  /** Snapshot, update in place, health-check, roll back on failure. */
  updateBot?(botId: string): Promise<import("./environment/container.ts").UpdateResult>;
  /** The current bot image's tools, and the bots still on an older image. */
  imageStatus?(): Promise<{
    tag: string;
    tools: import("./environment/images.ts").ImageTools;
    staleBots: string[];
  }>;
  /** Recreate the container from a clean image, keeping storage. */
  rebuild?(botId: string): Promise<void>;
  /**
   * Release the bot's runtime (containers) when it is soft-deleted. Keep volumes and other data on
   * disk: a soft delete never removes data.
   */
  dispose(botId: string): Promise<void>;
  /**
   * The user purged a deleted bot: remove its runtime and its storage. Already-missing pieces are
   * fine; throws when it could not.
   */
  purge?(botId: string): Promise<void>;
  /** A soft-deleted bot came back: bring its runtime back up. */
  restore?(botId: string): Promise<void>;
  /**
   * Startup: the soft-deleted bots' runtimes are stopped, running ones are watched for idleness.
   * Runtimes of bots this runtime doesn't know are left alone.
   */
  reconcile?(activeBotIds: readonly string[], deletedBotIds: readonly string[]): Promise<void>;
  /** Shutdown: drop connections; containers keep running and are reconciled on the next start. */
  close?(): void;
  shutdown?(): Promise<void>;
}

export {
  BotEnvironment,
  type BotEnvironmentOptions,
  containerName,
  volumeName,
} from "./environment/container.ts";
