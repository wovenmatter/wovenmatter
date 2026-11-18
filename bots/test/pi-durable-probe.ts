// Runs as its own process: `node pi-durable-probe.ts <config.json> app|helper|<specifier>...`.
// It prepares the process as `cli.ts serve` does, then reports every SDK module it loads (and,
// for `helper`, the version of each package the in-container helper carries).
import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { validateRuntimeConfig } from "../src/config.ts";
import { sdkPackage, usePiDurableSDK } from "../src/pi-durable-sdk.ts";

const [file, ...imports] = process.argv.slice(2);
if (!file) throw new Error("usage: pi-durable-probe <config.json> app|<specifier>...");
const config = await usePiDurableSDK(validateRuntimeConfig(JSON.parse(readFileSync(file, "utf8"))), () => {});
const resolved: string[] = [];
registerHooks({
  resolve(specifier, context, nextResolve) {
    const result = nextResolve(specifier, context);
    if (sdkPackage(specifier)) resolved.push(result.url);
    return result;
  },
});
const copies: unknown[] = [];
const helper: Record<string, string> = {};
for (const specifier of imports) {
  if (specifier === "helper") {
    const { helperArchive } = await import("../src/environment/images.ts");
    const { readTar } = await import("../src/environment/tar.ts");
    for (const entry of readTar((await helperArchive()).tar)) {
      const match = /^node_modules\/(.+)\/package\.json$/.exec(entry.path);
      if (match?.[1] && entry.data) helper[match[1]] = (JSON.parse(entry.data.toString("utf8")) as { version: string }).version;
    }
    continue;
  }
  const module = (await import(specifier === "app" ? "../src/app.ts" : specifier)) as { copy?: unknown };
  if (specifier !== "app") copies.push(module.copy);
}
process.stdout.write(JSON.stringify({ executable: config.claude?.executable ?? null, resolved, copies, helper }));
