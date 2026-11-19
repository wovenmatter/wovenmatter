/**
 * The Woven Matter release this runtime shipped in, as the Woven server that starts it says
 * (`WOVENMATTER_RELEASE_VERSION`); a checkout has none.
 */
export const releaseVersion = (environment: NodeJS.ProcessEnv = process.env): string =>
  environment.WOVENMATTER_RELEASE_VERSION || "development";

/**
 * Pi Bot's capabilities, plus the runtime additions: `bots.environment` (container state and
 * rebuild), `runtime.update` (snapshot, update, rollback) and `previews`.
 */
export const CAPABILITIES = [
  "groups",
  "woven.mcp",
  "message.context",
  "bots.environment",
  "runtime.update",
  "previews",
] as const;
