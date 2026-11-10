#!/usr/bin/env node
import { parseArgs } from "node:util";
import { startRuntime } from "./app.ts";
import { ConfigError, loadRuntimeConfig } from "./config.ts";
import { VERSION } from "./version.ts";

const USAGE = `wovenmatter-bots ${VERSION}

Usage: node bots/src/cli.ts serve --config <file>

Runs the Woven Matter bots runtime: every bot of this machine in one process, a protocol-1
WebSocket at /ws on the configured loopback port, tools in each bot's container on the
configured Docker Engine. The machine's Woven server writes the JSON config and supervises
this process.`;

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
  if (values.version) return void console.log(VERSION);
  if (values.help || !command) return void console.log(USAGE);
  if (command !== "serve") throw new Error(`unknown command ${command}\n\n${USAGE}`);
  if (!values.config) throw new Error("serve needs --config <file>");
  const config = await loadRuntimeConfig(values.config);
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
