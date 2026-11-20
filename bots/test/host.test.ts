import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { HostChannel } from "../src/host/channel.ts";
import type { AccountsSummary, HostRequest } from "../src/protocol.ts";
import { echoModels, tempDir } from "./helpers.ts";
import { startTestRuntime, type TestRuntime } from "./runtime.ts";
import { FakeServer } from "./ws-client.ts";

describe("the host interface", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let app: TestRuntime | undefined;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await app?.close();
    app = undefined;
    await dir.cleanup();
  });

  it("asks the server on the server's own connection and uses its answer", async () => {
    app = await startTestRuntime(dir.path, { models: echoModels().models });
    const server = await FakeServer.open(app.socket, {
      credentials: ({ provider }) => ({
        credential: provider === "openai" ? { type: "apiKey", key: "sk-test" } : null,
      }),
      "mirror.checkpoints": () => ({ bots: {}, forum: 0 }),
      "mirror.bot": () => ({}),
      "mirror.forum": () => ({}),
    });
    try {
      const { accounts } = await server.request<AccountsSummary>("settings.accounts");
      expect(accounts.find((account) => account.id === "openai")?.configured).toBe(true);
      expect(accounts.find((account) => account.id === "anthropic")?.configured).toBe(false);
      expect(server.calls("credentials")).toContainEqual({ provider: "openai" });
    } finally {
      await server.close();
    }
  });

  it("fails a request the server refuses, with the server's message", async () => {
    const channel = new HostChannel();
    channel.attach((request) =>
      queueMicrotask(() => channel.deliver({ type: "host.error", id: request.id, message: "No such bot." })),
    );
    await expect(channel.call("git.setup", { botId: "x" })).rejects.toThrow("No such bot.");
  });

  it("fails plainly with no server, without an answer in time, and when the server goes away", async () => {
    const channel = new HostChannel({ timeoutMs: 50 });
    await expect(channel.call("tools.access", { botId: "x" })).rejects.toThrow(
      "The Woven server is not connected.",
    );
    const sent: HostRequest[] = [];
    const detach = channel.attach((request) => sent.push(request));
    await expect(channel.call("tools.access", { botId: "x" })).rejects.toThrow(/did not answer tools.access in time/);
    const waiting = channel.call("tools.access", { botId: "y" });
    detach();
    await expect(waiting).rejects.toThrow("The Woven server disconnected.");
    expect(sent.map((request) => request.method)).toEqual(["tools.access", "tools.access"]);
  });
});
