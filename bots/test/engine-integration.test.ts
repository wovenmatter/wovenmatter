/**
 * The bots runtime against a real Docker Engine. Opt-in: set WOVEN_BOTS_ENGINE_SOCKET to an
 * engine socket you own (never a production daemon) and run `npm run test:engine`. It builds the
 * bot image if missing, runs one bot through its whole life and removes what it created.
 *
 *   create → tool call in the container → keep_running service and browser → idle stop → wake
 *   (reply first, container after) → service restarted, browser tab and cookie restored →
 *   preview proxied (host API faked) → update with a forced health-check failure rolls back.
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { type BotsRuntime, startRuntime } from "../src/app.ts";
import type { Bot } from "../src/bots.ts";
import { type BotEnvironment, containerName } from "../src/environment/container.ts";
import { DockerEngineAPI } from "../src/environment/engine-api.ts";
import { tempDir } from "./helpers.ts";
import { FakeHost, testConfig, testSettings } from "./runtime.ts";

const SOCKET = process.env.WOVEN_BOTS_ENGINE_SOCKET;
const IMAGE = process.env.WOVEN_BOTS_ENGINE_IMAGE ?? "woven-bots-validation";
const MACHINE = `engine-test-${process.pid}`;
const ctx = BACKGROUND_CONTEXT;

type Content = { type: string; text?: string };
const text = (content: unknown) =>
  typeof content === "string"
    ? content
    : ((content as Content[]) ?? []).map((block) => (block.type === "text" ? (block.text ?? "") : "")).join("");

/**
 * A scripted model: a user message `TOOL <name> <json>` calls that tool; after a tool result it
 * answers `RESULT <tool output>`; anything else is echoed without tools.
 */
function scriptedModels() {
  const faux = fauxProvider({ tokensPerSecond: 100_000 });
  faux.setResponses(
    Array.from({ length: 400 }, () => (context: { messages: { role: string; content: unknown }[] }) => {
      const last = context.messages.at(-1);
      if (last?.role === "toolResult") return fauxAssistantMessage([fauxText(`RESULT ${text(last.content)}`)]);
      const said = text(context.messages.filter((m) => m.role === "user").at(-1)?.content);
      const match = /TOOL (\S+) (.*)$/s.exec(said);
      if (match) {
        return fauxAssistantMessage([fauxToolCall(match[1] ?? "", JSON.parse(match[2] ?? "{}"))], {
          stopReason: "toolUse",
        });
      }
      return fauxAssistantMessage([fauxText(`echo: ${said.slice(-60)}`)]);
    }) as never,
  );
  const models = createModels();
  models.setProvider(faux.provider);
  return models;
}

async function lastReply(bot: Bot): Promise<string> {
  const main = await bot.main();
  const page = await main.entries({ order: "descending" }, 20, undefined, ctx);
  for (const entry of page.items) {
    const message = entry.model?.find((m) => m.role === "assistant");
    if (message) return text((message as { content: unknown }).content);
  }
  return "";
}

async function ask(bot: Bot, said: string): Promise<string> {
  const { submission } = await bot.send(said);
  await submission.wait(ctx);
  await bot.harness.waitForIdle(ctx);
  return lastReply(bot);
}

const tool = (name: string, args: unknown) => `TOOL ${name} ${JSON.stringify(args)}`;

describe.skipIf(!SOCKET)("bots on a real Docker Engine", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let runtime: BotsRuntime;
  let env: BotEnvironment;
  let engine: DockerEngineAPI;
  let bot: Bot;
  let failHealth = false;
  const host = new FakeHost();
  const log: string[] = [];

  beforeAll(async () => {
    dir = await tempDir();
    engine = new DockerEngineAPI(SOCKET ?? "");
    runtime = await startRuntime(
      testConfig(dir.path, {
        engine: { socket: SOCKET, kind: "mac-vm" },
        image: { tag: IMAGE },
        limits: { botMemoryBytes: 2 * 1024 ** 3 },
        machine: { deviceID: MACHINE, name: "Engine test" },
      }),
      {
        models: scriptedModels(),
        host,
        settings: testSettings(),
        port: 0,
        log: (line) => log.push(line),
        environment: {
          idleMs: 6_000,
          sweepMs: 1_000,
          // The real apt upgrade needs the network and minutes; opt in with WOVEN_BOTS_ENGINE_REAL_UPGRADE=1.
          ...(process.env.WOVEN_BOTS_ENGINE_REAL_UPGRADE
            ? {}
            : { upgradeCommand: ["sh", "-c", "apt-get --version >/dev/null"] }),
          healthCheck: async () => {
            if (failHealth) throw new Error("forced health-check failure");
          },
        },
      },
    );
    env = runtime.env as BotEnvironment;
    await runtime.reconciled;
    bot = await runtime.manager.get((await runtime.manager.create("Engine")).id);
  }, 30 * 60_000);

  afterAll(async () => {
    const id = bot?.id;
    await runtime?.close();
    if (id) {
      const cleanup = (await import("../src/environment/container.ts")).BotEnvironment;
      const remover = new cleanup({
        engine,
        kind: "mac-vm",
        imageName: IMAGE,
        memoryBytes: null,
        machineId: MACHINE,
      });
      await remover.purge(id).catch(() => {});
      remover.close();
    }
    for (const container of await engine.listContainers("woven.bots.machine").catch(() => [])) {
      if (container.Labels["woven.bots.machine"] === MACHINE) await engine.removeContainer(container.Id);
    }
    await dir?.cleanup();
    if (process.env.WOVEN_BOTS_ENGINE_LOG) console.log(log.join("\n"));
  }, 120_000);

  it("runs a tool call in the bot's own container, as the bot user with sudo", async () => {
    expect(await env.state(bot.id)).toBe("missing");
    const reply = await ask(
      bot,
      tool("bash", { command: "id -un; sudo -n id -un; . /etc/os-release; echo $ID $VERSION_ID; node --version; pwd" }),
    );
    expect(reply).toContain("bot\nroot\nubuntu 26.04\nv26.");
    expect(reply).toContain("/workspace");
    expect(await env.state(bot.id)).toBe("running");
    const info = await engine.inspectContainer(containerName(bot.id));
    expect(info?.HostConfig?.Memory).toBe(2 * 1024 ** 3);
    // Exec streams: stdin half-closes and the output still comes back.
    expect(
      await engine.run(containerName(bot.id), ["sh", "-c", "cat | tr a-z A-Z"], { input: "hello", user: "bot" }),
    ).toEqual({ code: 0, stdout: "HELLO", stderr: "" });
  }, 10 * 60_000);

  it("keeps a service running and a browser session, then stops when idle", async () => {
    await ask(
      bot,
      tool("bash", {
        command:
          "mkdir -p /workspace/site && cat > /workspace/site/index.html <<'EOF'\n<html><body><p id=c>loading</p><script>if(!document.cookie.includes('woven=1'))document.cookie='woven=1; max-age=86400; path=/';document.getElementById('c').textContent='cookie:'+document.cookie</script></body></html>\nEOF",
      }),
    );
    const added = await ask(
      bot,
      tool("keep_running", { name: "site", command: "exec python3 -m http.server 8000 --bind 127.0.0.1 --directory /workspace/site" }),
    );
    expect(added).toContain('"running": true');
    const opened = await ask(bot, tool("browser", { action: "navigate", url: "http://127.0.0.1:8000/" }));
    expect(opened).toContain("http://127.0.0.1:8000/");
    const page = await ask(bot, tool("browser", { action: "read" }));
    expect(page).toContain("cookie:woven=1");
    const shot = await ask(bot, tool("browser", { action: "screenshot" }));
    expect(shot).toMatch(/^RESULT Tab 1: .*127\.0\.0\.1:8000/);
    const context = JSON.stringify(await (await bot.main()).context(ctx));
    expect(context).toContain('"mimeType":"image/png"');
    // Nothing runs now but the supervisor's own processes: the bot goes idle and stops.
    expect(await env.runningWork(bot.id)).toEqual([]);
    await expect.poll(() => env.state(bot.id), { timeout: 120_000, interval: 1_000 }).toBe("stopped");
    expect(log.some((line) => line.includes("stopped idle container"))).toBe(true);
  }, 10 * 60_000);

  it("replies at once on wake, then starts the container on the first tool call with its services and tabs back", async () => {
    const started = Date.now();
    expect(await ask(bot, "are you there?")).toContain("echo: are you there?");
    expect(Date.now() - started).toBeLessThan(10_000);
    expect(await env.state(bot.id)).toBe("stopped");
    const served = await ask(
      bot,
      tool("bash", { command: "for i in $(seq 1 40); do curl -fsS http://127.0.0.1:8000/ && exit 0; sleep 0.5; done; exit 1" }),
    );
    expect(served).toContain("cookie:");
    expect(await env.state(bot.id)).toBe("running");
    const tabs = await ask(bot, tool("browser", { action: "tabs" }));
    expect(tabs).toContain("http://127.0.0.1:8000/");
    const page = await ask(bot, tool("browser", { action: "read" }));
    // The cookie set before the stop came back with the profile.
    expect(page).toContain("cookie:woven=1");
  }, 10 * 60_000);

  it("shares a preview through the activity proxy and the host", async () => {
    const reply = await ask(bot, tool("share_preview", { port: 8000 }));
    expect(reply).toContain("https://test-host.tailnet.ts.net");
    const preview = runtime.previews?.list(bot.id)[0];
    if (!preview) throw new Error("no preview");
    expect(host.calls).toContainEqual({ method: "publishPreview", args: [bot.id, preview.port, 8000] });
    const before = env.lastActivity(bot.id) ?? 0;
    await new Promise((resolve) => setTimeout(resolve, 20));
    const response = await fetch(`http://127.0.0.1:${preview.port}/index.html`);
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("cookie:");
    expect(env.lastActivity(bot.id) ?? 0).toBeGreaterThan(before);
    expect(runtime.previews?.lastTraffic(bot.id)).toBeGreaterThan(0);
  }, 5 * 60_000);

  it("rolls an update back to its snapshot when the health check fails, and updates cleanly otherwise", async () => {
    await ask(bot, tool("bash", { command: "echo before-update > /workspace/marker; sudo touch /etc/woven-layer" }));
    failHealth = true;
    const [failed] = await runtime.operations.update([bot.id]);
    expect(failed).toMatchObject({ ok: false, rolledBack: true, error: "forced health-check failure" });
    expect(log.some((line) => line.includes("rolling back"))).toBe(true);
    const after = await ask(bot, tool("bash", { command: "cat /workspace/marker; test -f /etc/woven-layer && echo layer-kept" }));
    expect(after).toContain("before-update");
    expect(after).toContain("layer-kept");
    failHealth = false;
    const [ok] = await runtime.operations.update([bot.id]);
    expect(ok).toEqual({ botId: bot.id, ok: true });
    const services = await ask(bot, tool("keep_running_list", {}));
    expect(services).toContain('"running": true');
  }, 20 * 60_000);

  it("rebuilds from a clean image, keeping storage and bringing the restart list back", async () => {
    const before = (await engine.inspectContainer(containerName(bot.id)))?.Id;
    await runtime.operations.rebuild(bot.id);
    expect((await engine.inspectContainer(containerName(bot.id)))?.Id).not.toBe(before);
    const after = await ask(
      bot,
      tool("bash", {
        command:
          "cat /workspace/marker; test -f /etc/woven-layer && echo layer-kept || echo layer-gone; " +
          "for i in $(seq 1 40); do curl -fsS http://127.0.0.1:8000/ >/dev/null && echo served && exit 0; sleep 0.5; done; exit 1",
      }),
    );
    expect(after).toContain("before-update");
    expect(after).toContain("layer-gone");
    expect(after).toContain("served");
  }, 10 * 60_000);
});
