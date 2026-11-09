import { readFile } from "node:fs/promises";
import { isIP } from "node:net";
import { isAbsolute, resolve } from "node:path";
import { z } from "zod";
import { isCronExpression } from "./cron.ts";
import { TITLE_REASONING } from "./titles.ts";

/** `provider/model-id`, e.g. `openai/gpt-6-sol`. The model id may contain further slashes. */
export type ModelRef = { readonly provider: string; readonly modelId: string };

const MODEL_REF = /^([a-z0-9][a-z0-9._-]*)\/(\S+)$/;

export function parseModelRef(value: string): ModelRef {
  const match = MODEL_REF.exec(value);
  if (!match?.[1] || !match[2]) throw new Error(`invalid model reference: ${value}`);
  return { provider: match[1], modelId: match[2] };
}

/** The runtime listens on loopback only; the machine's Woven server proxies remote members. */
export function isLoopbackHost(host: string): boolean {
  const value = host.trim().toLowerCase();
  if (value === "localhost") return true;
  const bare = value.startsWith("[") && value.endsWith("]") ? value.slice(1, -1) : value;
  if (isIP(bare) === 4) return bare.startsWith("127.");
  return bare === "::1";
}

function isTimeZone(value: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value });
    return true;
  } catch {
    return false;
  }
}

export class ConfigError extends Error {
  override name = "ConfigError";
}

/**
 * The runtime configuration the machine's Woven server writes (JSON). It names where data lives,
 * where to listen, the engine socket and the host API; secrets here are the runtime's own WS
 * token and the host API bearer, both minted by the Woven server.
 */
export const runtimeConfigSchema = z.strictObject({
  dataDir: z.string().min(1),
  listen: z.strictObject({
    host: z.string().default("127.0.0.1").refine(isLoopbackHost, "must be a loopback address"),
    port: z.number().int().min(0).max(65535),
  }),
  runtimeToken: z.string().min(32).max(512),
  engine: z.strictObject({
    socket: z.string().min(1),
    kind: z.enum(["linux-dockerd", "mac-vm"]),
  }),
  /**
   * The bot image. A name without a tag (`wovenmatter-bots`) gets a content-hash tag of
   * bots/image and is built through the Engine API when missing; a name with a tag is used as is.
   */
  image: z.strictObject({ tag: z.string().min(1).max(256) }),
  limits: z.strictObject({
    /** Container memory limit per bot; null: no cap. */
    botMemoryBytes: z
      .number()
      .int()
      .min(64 * 1024 * 1024)
      .nullable(),
  }),
  host: z.strictObject({
    url: z
      .string()
      .url()
      .refine((value) => {
        const url = new URL(value);
        return url.protocol === "http:" && isLoopbackHost(url.hostname);
      }, "the host API is a loopback http URL"),
    token: z.string().min(16).max(8192),
  }),
  machine: z.strictObject({
    deviceID: z.string().min(1).max(128),
    name: z.string().min(1).max(200),
  }),
});

export type RuntimeConfig = z.infer<typeof runtimeConfigSchema> & {
  readonly paths: {
    readonly dataDir: string;
    readonly database: string;
    readonly settings: string;
    readonly claude: string;
  };
};

export function validateRuntimeConfig(input: unknown, source = "config"): RuntimeConfig {
  const result = runtimeConfigSchema.safeParse(input);
  if (!result.success) {
    throw new ConfigError(`invalid ${source}:\n${z.prettifyError(result.error)}`);
  }
  const raw = result.data;
  if (!isAbsolute(raw.dataDir)) throw new ConfigError(`invalid ${source}: dataDir must be absolute`);
  const dataDir = resolve(raw.dataDir);
  return {
    ...raw,
    paths: {
      dataDir,
      database: resolve(dataDir, "bots.sqlite"),
      settings: resolve(dataDir, "settings.json"),
      claude: resolve(dataDir, "claude-agent"),
    },
  };
}

export async function loadRuntimeConfig(path: string): Promise<RuntimeConfig> {
  const absolute = resolve(path);
  let text: string;
  try {
    text = await readFile(absolute, "utf8");
  } catch (error) {
    throw new ConfigError(`cannot read config ${absolute}: ${(error as Error).message}`);
  }
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch (error) {
    throw new ConfigError(`invalid JSON in ${absolute}: ${(error as Error).message}`);
  }
  return validateRuntimeConfig(json, absolute);
}

/** `profiles.<id>` keys. */
export const PROFILE_ID = /^[a-z0-9][a-z0-9_-]{0,39}$/;

const modelRef = z
  .string()
  .regex(MODEL_REF, "expected provider/model-id, e.g. openai/gpt-6-sol")
  .describe("provider/model-id");

/**
 * Settings the runtime owns and edits live (Settings → Bots in the Woven UI): model profiles, the
 * thread-title model, memory extraction, compaction and bot-to-bot limits. Kept in
 * `<dataDir>/settings.json`; no secrets.
 */
export const settingsSchema = z.strictObject({
  defaultProfile: z.string().regex(PROFILE_ID).default("default"),
  profiles: z
    .record(
      z.string().regex(PROFILE_ID, "profile ids are lowercase letters, digits, - and _"),
      z.strictObject({
        name: z.string().trim().min(1).max(80),
        main: modelRef,
        fallbacks: z.array(modelRef).max(5, "at most 5 fallbacks").default([]),
        memoryModel: modelRef.optional(),
        guidance: z.string().max(4000).optional(),
        pool: z
          .array(z.strictObject({ model: modelRef, useFor: z.string().max(500).default("") }))
          .max(50)
          .default([]),
      }),
    )
    .default({
      default: {
        name: "Default",
        main: "claude-subscription/claude-opus-5-5",
        fallbacks: [],
        pool: [],
      },
    }),
  titles: z
    .strictObject({
      model: modelRef.default("openai-codex/gpt-6-luna"),
      reasoning: z.enum(TITLE_REASONING).default("high"),
    })
    .prefault({}),
  extraction: z
    .strictObject({
      enabled: z.boolean().default(true),
      schedule: z
        .string()
        .default("0 3 * * *")
        .refine(isCronExpression, "expected a 5-field cron expression"),
      timezone: z.string().default("UTC").refine(isTimeZone, "unknown IANA time zone"),
      idle_minutes: z.number().int().min(0).max(10_080).default(30),
    })
    .prefault({}),
  bot_to_bot: z
    .strictObject({
      max_rounds_per_request: z.number().int().min(1).max(100).default(5),
      max_messages_per_hour_per_pair: z.number().int().min(1).max(10_000).default(30),
    })
    .prefault({}),
  compaction: z
    .strictObject({
      enabled: z.boolean().default(true),
      reserve_tokens: z.number().int().min(0).default(16_384),
      keep_recent_tokens: z.number().int().min(0).default(20_000),
      background_tokens: z.number().int().min(0).default(0),
      native: z.enum(["auto", "off"]).default("auto"),
      models: z
        .record(
          modelRef,
          z.strictObject({
            enabled: z.boolean().optional(),
            reserve_tokens: z.number().int().min(0).optional(),
            keep_recent_tokens: z.number().int().min(0).optional(),
            background_tokens: z.number().int().min(0).optional(),
          }),
        )
        .default({}),
    })
    .prefault({}),
});

export type RawSettings = z.infer<typeof settingsSchema>;
/** Kept for the ported modules that read `RawConfig["compaction"]` and friends. */
export type RawConfig = RawSettings;

/** One additional model the main model may run subagents on. */
export type PoolModel = {
  readonly model: string;
  /** Optional notes on this model for the main model (`use_for`); "" for none. */
  readonly useFor: string;
};

export type Profile = {
  readonly id: string;
  readonly name: string;
  /** `provider/model-id` of the main channel and every thread. */
  readonly main: string;
  /** Ordered main-model fallbacks for usage limits (0–5); none: the bot pauses at a limit. */
  readonly fallbacks?: readonly string[];
  /** Memory extraction model. Unset: the main model the bot runs at that moment. */
  readonly memoryModel?: string;
  /** Model preferences: the user's free-text notes for choosing subagent models. */
  readonly guidance?: string;
  /** Additional subagent models; the main model can always run subagents on itself. */
  readonly pool: readonly PoolModel[];
};

export type ProfileSet = {
  readonly defaultId: string;
  readonly profiles: readonly Profile[];
};

function checkFallbacks(id: string, main: string, fallbacks: readonly string[]): string[] {
  const seen = new Set<string>([main]);
  for (const ref of fallbacks) {
    if (seen.has(ref)) {
      throw new Error(`profiles.${id}.fallbacks: ${ref} is listed twice or is the main model`);
    }
    seen.add(ref);
  }
  return [...fallbacks];
}

export function normalizeProfiles(raw: RawSettings): ProfileSet {
  const profiles: Profile[] = Object.entries(raw.profiles).map(([id, value]) => ({
    id,
    name: value.name,
    main: value.main,
    ...(value.fallbacks.length ? { fallbacks: checkFallbacks(id, value.main, value.fallbacks) } : {}),
    ...(value.memoryModel ? { memoryModel: value.memoryModel } : {}),
    ...(value.guidance?.trim() ? { guidance: value.guidance.trim() } : {}),
    pool: value.pool.map((entry) => ({ model: entry.model, useFor: entry.useFor })),
  }));
  if (profiles.length === 0) throw new Error("settings need at least one model profile");
  const defaultId = profiles.some((profile) => profile.id === raw.defaultProfile)
    ? raw.defaultProfile
    : (profiles[0]?.id ?? "default");
  return { defaultId, profiles };
}

/** The settings as a ProfileSet's serialized form, for writing back. */
export function profilesToRaw(set: ProfileSet): Pick<RawSettings, "defaultProfile" | "profiles"> {
  return {
    defaultProfile: set.defaultId,
    profiles: Object.fromEntries(
      set.profiles.map((profile) => [
        profile.id,
        {
          name: profile.name,
          main: profile.main,
          fallbacks: [...(profile.fallbacks ?? [])],
          ...(profile.memoryModel ? { memoryModel: profile.memoryModel } : {}),
          ...(profile.guidance ? { guidance: profile.guidance } : {}),
          pool: profile.pool.map((entry) => ({ model: entry.model, useFor: entry.useFor })),
        },
      ]),
    ),
  };
}
