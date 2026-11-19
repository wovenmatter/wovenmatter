export const PROTOCOL = 1;
/**
 * Pi Bot's capabilities, plus the runtime additions: `bots.environment` (container state and
 * rebuild), `runtime.update` (snapshot, update, rollback), `previews`, `forum` (the group chat)
 * and `user.name` (what bots call the user).
 */
export const CAPABILITIES = [
  "groups",
  "woven.mcp",
  "message.context",
  "bots.environment",
  "runtime.update",
  "previews",
  "forum",
  "user.name",
] as const;
