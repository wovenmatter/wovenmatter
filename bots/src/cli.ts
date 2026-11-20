#!/usr/bin/env node
import { parseArgs } from "node:util";
import { ConfigError, loadRuntimeConfig } from "./config.ts";
import { usePiDurableSDK } from "./pi-durable-sdk.ts";

const USAGE = `Usage: node bots/src/cli.ts serve --config <file>
       node bots/src/cli.ts files export|import|remove --config <file> [--dir <folder>]

serve runs the Woven Matter bots runtime: every bot in one process, a WebSocket on the configured
Unix socket for the server, tools in each bot's container on the configured Docker Engine. The
server writes the JSON config and supervises this process.

files, while the runtime is stopped, writes each bot's files out of the engine as archives in
<folder>, reads such archives into the engine, or removes every bot's container and files.`;

async function main(argv: string[]): Promise<void> {
  const { positionals, values } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      config: { type: "string", short: "c" },
      dir: { type: "string" },
      help: { type: "boolean", short: "h" },
    },
  });
  const [command, action] = positionals;
  if (values.help || !command) return void console.log(USAGE);
  if (command !== "serve" && command !== "files") throw new Error(`unknown command ${command}\n\n${USAGE}`);
  if (!values.config) throw new Error(`${command} needs --config <file>`);
  const config = await usePiDurableSDK(await loadRuntimeConfig(values.config));
  if (command === "files") {
    if (action !== "export" && action !== "import" && action !== "remove") {
      throw new Error(`files needs export, import or remove\n\n${USAGE}`);
    }
    const { botFiles } = await import("./files.ts");
    await botFiles(config, action, values.dir);
    process.exit(0);
  }
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
