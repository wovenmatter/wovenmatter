// Preloaded with `node --import` by tests: appends every file URL this process resolves to
// $WOVEN_RESOLUTION_LOG. Registered first, it sees each resolution after any later hook
// (bots' Pi Durable SDK hook) has chosen where the specifier resolves from.
import { appendFileSync } from "node:fs";
import { registerHooks } from "node:module";

const log = process.env.WOVEN_RESOLUTION_LOG;
if (!log) throw new Error("WOVEN_RESOLUTION_LOG is not set.");
registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context);
    if (resolved.url.startsWith("file:")) appendFileSync(log, `${resolved.url}\n`);
    return resolved;
  },
});
