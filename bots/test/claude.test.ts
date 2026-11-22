import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { delimiter, join } from "node:path";
import { createModels } from "@earendil-works/pi-ai/models";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { claudeAgentProvider } from "../src/claude/provider.ts";
import { ClaudeAgentRuntime, type ClaudeSdkQuery, claudeExecutable } from "../src/claude/runtime.ts";
import { NATIVE_KEY, ServerCredentials } from "../src/host/credentials.ts";
import { FileModelsStore } from "../src/model-catalog.ts";
import { SettingsStore } from "../src/settings/store.ts";
import { tempDir } from "./helpers.ts";

describe("the installed Claude Code", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  it("is the first executable claude on PATH, or a clear error", async () => {
    const none = join(dir.path, "none");
    const plain = join(dir.path, "plain");
    const installed = join(dir.path, "installed");
    for (const folder of [none, plain, installed]) await mkdir(folder);
    await writeFile(join(plain, "claude"), "");
    await writeFile(join(installed, "claude"), "#!/bin/sh\n");
    await chmod(join(installed, "claude"), 0o755);
    expect(claudeExecutable([none, plain, installed].join(delimiter))).toBe(join(installed, "claude"));
    expect(() => claudeExecutable([none, plain].join(delimiter))).toThrow("Claude Code is not installed on this machine.");
  });
});

describe("bots' Claude subscription", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  it("runs Claude Code with its own sign-in, as Pi Durable does", () => {
    const runtime = new ClaudeAgentRuntime({ directory: dir.path });
    const env = runtime.environment({
      PATH: "/bin",
      CLAUDE_CONFIG_DIR: "/somewhere",
      ANTHROPIC_API_KEY: "sk-ant-api",
      ANTHROPIC_BASE_URL: "https://example.invalid",
      CLAUDECODE: "1",
      CLAUDE_CODE_ENTRYPOINT: "cli",
      CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat-token",
    });
    expect(env.CLAUDE_CONFIG_DIR).toBe("/somewhere");
    expect(env.PATH).toBe("/bin");
    for (const name of ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_OAUTH_TOKEN"]) {
      expect(env[name]).toBeUndefined();
    }
  });

  it("lists the models Claude Code offers, asks it only when none are stored, and keeps them", async () => {
    let asked = 0;
    const listed = [
      { value: "default", displayName: "Default (recommended)", resolvedModel: "claude-opus-5-5", supportedEffortLevels: ["low", "high", "max"] },
      { value: "opus", displayName: "Opus", resolvedModel: "claude-opus-5-5", supportedEffortLevels: ["low", "high", "max"] },
      { value: "haiku", displayName: "Haiku", resolvedModel: "claude-haiku-5-5" },
    ];
    const query: ClaudeSdkQuery = () => {
      asked += 1;
      return Object.assign((async function* () {})(), { supportedModels: async () => listed });
    };
    const store = new FileModelsStore(join(dir.path, "provider-models"));
    const credentials = new ServerCredentials(async () => ({ credential: { type: "native" } }));
    const make = () => {
      const claude = claudeAgentProvider({ directory: join(dir.path, "claude"), query });
      const models = createModels({ credentials, modelsStore: store });
      models.setProvider(claude.provider);
      return models;
    };
    const first = make();
    expect(first.getModels("claude-subscription")).toEqual([]);
    await first.refresh({ allowNetwork: true });
    expect(first.getModels("claude-subscription").map((model) => [model.id, model.name])).toEqual([
      ["default", "Default (recommended)"],
      ["opus", "Opus 5.5"],
      ["haiku", "Haiku 5.5"],
    ]);
    expect(first.getModel("claude-subscription", "opus")?.thinkingLevelMap).toMatchObject({ low: "low", max: "max", medium: null });
    expect(asked).toBe(1);

    // Stored: a new process lists them without starting Claude Code; a forced refresh asks again.
    const second = make();
    await second.refresh({ allowNetwork: true });
    expect(second.getModels("claude-subscription")).toHaveLength(3);
    expect(asked).toBe(1);
    await second.refresh({ allowNetwork: true, force: true });
    expect(asked).toBe(2);
  });

  it("never runs without Claude Code's sign-in marker", async () => {
    const query: ClaudeSdkQuery = () => {
      throw new Error("Claude Code must not start");
    };
    const { provider } = claudeAgentProvider({ directory: join(dir.path, "claude"), query });
    const model = { id: "opus", api: "claude-agent-sdk", provider: "claude-subscription" } as never;
    const reply = await provider
      .stream(model, { messages: [{ role: "user", content: "hi", timestamp: 0 }] } as never, { apiKey: "sk-ant-oat-token" } as never)
      .result();
    expect(reply.errorMessage).toMatch(/No Claude connection/);
    expect(NATIVE_KEY).toBe("woven-native");
  });

  it("moves saved Anthropic model ids to Claude Code's model of the same family", async () => {
    const path = join(dir.path, "settings.json");
    const opened = async (model: string) => {
      await writeFile(path, JSON.stringify({ titles: { model } }));
      const settings = await SettingsStore.open(path);
      expect(JSON.parse(await readFile(path, "utf8")).titles.model).toBe(settings.current.titles.model);
      return settings.current.titles.model;
    };
    expect(await opened("claude-subscription/claude-haiku-4-5")).toBe("claude-subscription/haiku");
    expect(await opened("claude-subscription/claude-opus-5-5")).toBe("claude-subscription/opus");
    expect(await opened("claude-subscription/claude-fable-5-2")).toBe("claude-subscription/claude-fable-5-2[1m]");
    expect(await opened("claude-subscription/claude-fable-5-2[1m]")).toBe("claude-subscription/claude-fable-5-2[1m]");
    expect(await opened("claude-subscription/opus")).toBe("claude-subscription/opus");
    expect(await opened("anthropic/claude-opus-5-5")).toBe("anthropic/claude-opus-5-5");
  });
});
