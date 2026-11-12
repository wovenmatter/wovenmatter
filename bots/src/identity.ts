export const PROTOCOL = 1;
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
