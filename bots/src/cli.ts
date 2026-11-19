#!/usr/bin/env node
import { parseArgs } from "node:util";
import { ConfigError, loadRuntimeConfig } from "./config.ts";
import { join, sep } from "node:path";
import { loadSDKFrom, piDurableSDKAt, usePiDurableSDK } from "./pi-durable-sdk.ts";
import { releaseVersion } from "./identity.ts";

const USAGE = `wovenmatter-bots ${releaseVersion()}

Usage: node bots/src/cli.ts serve --config <file>
       node bots/src/cli.ts verify-sdk <Pi Durable SDK copy>

Runs the Woven Matter bots runtime: every bot of this machine in one process, a
WebSocket at /ws on the configured loopback port, tools in each bot's container on the
configured Docker Engine. The machine's Woven server writes the JSON config and supervises
this process. verify-sdk loads the whole runtime and its container helper from an SDK copy
without starting anything; Pi Durable's SDK update runs it before it activates a copy.`;

/**
 * Everything `serve` loads, from the SDK copy at `root`, without starting it: the runtime's
 * module graph through the same resolve hook, the Claude Agent SDK and binary it runs, and the
 * in-container helper as a bot's container would get it from this copy.
 */
async function verifySDK(root: string): Promise<void> {
  const sdk = piDurableSDKAt(root);
  loadSDKFrom(sdk.root);
  await import("./app.ts");
  const { loadClaudeAgentSDK } = await import("./claude/runtime.ts");
  await loadClaudeAgentSDK();
  const { verifyHelper } = await import("./environment/images.ts");
  await verifyHelper(join(sdk.root, "node_modules") + sep);
}

async function main(argv: string[]): Promise<void> {
  const { positionals, values } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      config: { type: "string", short: "c" },
      help: { type: "boolean", short: "h" },
      version: { type: "boolean", short: "v" },
    },
  });
  const [command] = positionals;
  if (values.version) return void console.log(releaseVersion());
  if (values.help || !command) return void console.log(USAGE);
  if (command === "verify-sdk") {
    if (!positionals[1]) throw new Error("verify-sdk needs the SDK copy's directory");
    await verifySDK(positionals[1]);
    return void process.exit(0);
  }
  if (command !== "serve") throw new Error(`unknown command ${command}\n\n${USAGE}`);
  if (!values.config) throw new Error("serve needs --config <file>");
  const config = await usePiDurableSDK(await loadRuntimeConfig(values.config));
  // Imported only now, so every SDK import resolves from Pi Durable's copy.
  const { startRuntime } = await import("./app.ts");
  const runtime = await startRuntime(config);
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    void runtime.close().then(
      () => process.exit(0),
      (error: unknown) => {
        console.error(`shutdown: ${String(error)}`);
        process.exit(1);
      },
    );
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
}

main(process.argv.slice(2)).catch((error: unknown) => {
  console.error(error instanceof ConfigError || error instanceof Error ? error.message : error);
  process.exit(1);
});
