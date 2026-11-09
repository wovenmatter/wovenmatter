import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ADMIN_PROMPT, createBotHarnessOptions } from "../src/agent.ts";
import { type Bot, BotManager } from "../src/bots.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import { type BotPlatform, MessageLimiter } from "../src/tools.ts";
import { FAUX_MODEL, parseTestSettings, profileOf, tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

describe("bot tools", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let db: Awaited<ReturnType<typeof openSharedDatabase>>;
  let manager: BotManager;
  let openManager: () => Promise<BotManager>;
  let platform: BotPlatform;
  const faux = fauxProvider({ tokensPerSecond: 5000 });
  // Each request's context as JSON: the prompt and tool declarations ride in system messages.
  const seen: string[] = [];
  type Step = (context: unknown) => ReturnType<typeof fauxAssistantMessage>;
  const tool =
    (name: string, args: Record<string, string>): Step =>
    (context) => {
      seen.push(JSON.stringify(context));
      return fauxAssistantMessage([fauxToolCall(name, args)], {
        stopReason: "toolUse",
      });
    };
  const reply: Step = (context) => {
    seen.push(JSON.stringify(context));
    return fauxAssistantMessage([fauxText("ok")]);
  };

  beforeEach(async () => {
    dir = await tempDir();
    seen.length = 0;
    const models = createModels();
    models.setProvider(faux.provider);
    db = await openSharedDatabase(join(dir.path, "db.sqlite"));
    platform = { manager: () => manager, maxMessagesPerHourPerPair: 1 };
    openManager = () =>
      BotManager.open({
        db,
        ensureAdmin: true,
        harnessOptions: (bot) =>
          createBotHarnessOptions({ bot, models, profile: profileOf(FAUX_MODEL), platform }),
      });
    manager = await openManager();
  });

  afterEach(async () => {
    await manager.close();
    await db.close();
    await dir.cleanup();
  });

  const say = async (bot: Bot, text: string) => {
    const sent = await bot.send(text);
    await expect(sent.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
  };
  const hasTool = (context: string | undefined, name: string) =>
    (context ?? "").includes(`"name":"${name}"`);

  it("names the admin bot Admin Bot and renames an older admin row on open", async () => {
    const admin = await manager.admin();
    expect(admin?.name).toBe("Admin Bot");
    await manager.close();
    await db.run("UPDATE pibot_bots SET name = 'Admin' WHERE kind = 'admin'");
    manager = await openManager();
    expect((await manager.list()).map((bot) => bot.name)).toEqual(["Admin Bot"]);
  });

  it("gives Admin Bot the profile tools and prompt; other bots get bot tools", async () => {
    const admin = await manager.admin();
    if (!admin) throw new Error("no Admin Bot");
    faux.setResponses([reply, reply]);
    await say(await manager.get(admin.id), "hi");
    expect(seen[0]).toContain(JSON.stringify(ADMIN_PROMPT).slice(1, 60));
    for (const name of [
      "create_bot",
      "message_bot",
      "set_team",
      "settings_status",
      "list_profiles",
      "save_profile",
      "set_bot_profile",
      "write_account_notes",
    ]) {
      expect(hasTool(seen[0], name)).toBe(true);
    }
    expect(hasTool(seen[0], "my_team")).toBe(false);
    for (const name of ["update_config", "restart_server", "read_config"]) {
      expect(hasTool(seen[0], name)).toBe(false);
    }

    const plain = await manager.create("Plain");
    await say(await manager.get(plain.id), "hi");
    expect(seen[1]).toContain("You are Plain");
    for (const name of ["create_bot", "list_bots", "message_bot", "my_team"]) {
      expect(hasTool(seen[1], name)).toBe(true);
    }
    for (const name of ["set_team", "settings_status", "save_profile"]) {
      expect(hasTool(seen[1], name)).toBe(false);
    }
  });

  it("creates bots on the creator's team and messages them, with a per-pair limit", async () => {
    const lead = await manager.create("Lead");
    await manager.setManager(lead.id, true);
    const leadBot = await manager.get(lead.id);
    faux.setResponses([tool("create_bot", { name: "Helper" }), reply]);
    await say(leadBot, "make a helper");
    const helper = (await manager.list()).find((bot) => bot.name === "Helper");
    expect(helper).toMatchObject({ managerId: lead.id, manager: false });
    if (!helper) throw new Error("no Helper");

    // The team shows up in the manager's prompt from the next request.
    const helperId = helper.id;
    // Lead and Helper share the faux queue, so each step answers by whose context it sees.
    const step: Step = (context) => {
      const json = JSON.stringify(context);
      if (json.includes("You are Helper")) return reply(context);
      const turn = json.slice(json.lastIndexOf('"content":"delegate"'));
      const results = turn.split('"role":"toolResult"').length - 1;
      if (results >= 2) return reply(context);
      const text = results === 0 ? "please research X" : "again";
      return tool("message_bot", { botId: helperId, text })(context);
    };
    faux.setResponses(Array.from({ length: 10 }, () => step));
    const before = seen.length;
    await say(leadBot, "delegate");
    expect(seen[before]).toContain("You manage a team: Helper.");
    expect(seen.slice(before).join("\n")).toContain("message limit reached");

    const main = await (await manager.get(helperId)).main();
    let history = "";
    for (let tries = 0; tries < 100 && !history.includes("please research X"); tries++) {
      history = JSON.stringify(
        (await main.entries({ order: "ascending" }, 50, undefined, ctx)).items,
      );
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    expect(history).toContain('[Message from bot \\"Lead\\"');
    expect(history).not.toContain("again");
  });

  it("stops a bot-to-bot chain at max_rounds_per_request; a user message starts a new request", async () => {
    // The config default reaches the tools.
    const config = parseTestSettings({});
    expect(config.bot_to_bot.max_rounds_per_request).toBe(5);
    await manager.close();
    platform = {
      manager: () => manager,
      maxRoundsPerRequest: config.bot_to_bot.max_rounds_per_request,
    };
    manager = await openManager();
    const ping = await manager.create("Ping");
    const pong = await manager.create("Pong");
    // Each bot answers any message by messaging the other once, then replies.
    const step: Step = (context) => {
      const messages = (context as { messages: { role: string }[] }).messages;
      if (messages.at(-1)?.role === "toolResult") return reply(context);
      const other = JSON.stringify(context).includes("You are Ping") ? pong.id : ping.id;
      return tool("message_bot", { botId: other, text: "your turn" })(context);
    };
    faux.setResponses(Array.from({ length: 60 }, () => step));
    const settle = async () => {
      for (let tries = 0; tries < 300 && (await manager.activeWork()) > 0; tries++) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    };
    const history = async (id: string) => {
      const main = await (await manager.get(id)).main();
      return JSON.stringify(
        (await main.entries({ order: "ascending" }, 500, undefined, ctx)).items,
      );
    };
    const received = async (id: string) =>
      (await history(id)).split("[Message from bot").length - 1;
    const limit = "bot-to-bot round limit reached (5 per request); reply to the user instead";

    // User → Ping (round 0); Ping → Pong 1, → Ping 2, → Pong 3, → Ping 4, → Pong 5; Pong's 6th is refused.
    await say(await manager.get(ping.id), "start");
    await settle();
    expect(await received(pong.id)).toBe(3);
    expect(await received(ping.id)).toBe(2);
    expect(await history(pong.id)).toContain(limit);
    expect(await history(ping.id)).not.toContain(limit);

    // A user message to Pong is round 0 again: five more hops, and Ping is refused this time.
    await say(await manager.get(pong.id), "again");
    await settle();
    expect(await received(ping.id)).toBe(5);
    expect(await received(pong.id)).toBe(5);
    expect(await history(ping.id)).toContain(limit);
  });

  it("sets and clears the orchestrator from Admin Bot or a bot, and tells the orchestrator its role", async () => {
    const admin = await manager.admin();
    if (!admin) throw new Error("no Admin Bot");
    const chief = await manager.create("Chief");
    const lead = await manager.create("Lead");
    await manager.setManager(lead.id, true);
    await manager.create("Member", { managerId: lead.id });
    await manager.create("Loose");

    faux.setResponses([tool("set_team", { action: "make_orchestrator", botId: chief.id }), reply]);
    await say(await manager.get(admin.id), "make Chief the orchestrator");
    expect((await manager.record(chief.id)).orchestrator).toBe(true);
    faux.setResponses([tool("set_team", { action: "make_orchestrator", botId: admin.id }), reply]);
    await say(await manager.get(admin.id), "make yourself the orchestrator");
    expect(seen.at(-1)).toContain("the Admin Bot can't be the orchestrator");

    // The orchestrator's prompt names its role, the teams and the bots on no team.
    let before = seen.length;
    faux.setResponses([reply]);
    await say(await manager.get(chief.id), "hi");
    expect(seen[before]).toContain(
      "You are the orchestrator: you lead and oversee every bot and team",
    );
    expect(seen[before]).toContain("Teams: Lead (Member). Bots on no team: Loose.");
    // Other bots know who the orchestrator is.
    before = seen.length;
    faux.setResponses([reply]);
    await say(await manager.get(lead.id), "hi");
    expect(seen[before]).toContain("Chief is the orchestrator");

    // A bot can take over the slot itself, and give it up.
    faux.setResponses([tool("my_team", { action: "become_orchestrator" }), reply]);
    await say(await manager.get(lead.id), "be the orchestrator");
    expect((await manager.list()).filter((bot) => bot.orchestrator).map((bot) => bot.name)).toEqual(
      ["Lead"],
    );
    expect(await manager.record(lead.id)).toMatchObject({ manager: true });
    faux.setResponses([tool("my_team", { action: "stop_orchestrator" }), reply]);
    await say(await manager.get(lead.id), "stop being the orchestrator");
    expect((await manager.list()).some((bot) => bot.orchestrator)).toBe(false);

    faux.setResponses([tool("set_team", { action: "make_orchestrator", botId: chief.id }), reply]);
    await say(await manager.get(admin.id), "Chief again");
    faux.setResponses([tool("set_team", { action: "clear_orchestrator" }), reply]);
    await say(await manager.get(admin.id), "no orchestrator");
    expect((await manager.list()).some((bot) => bot.orchestrator)).toBe(false);
  });

  it("renames bots by telling the bot itself or Admin Bot, never Admin Bot", async () => {
    const admin = await manager.admin();
    if (!admin) throw new Error("no Admin Bot");
    const scout = await manager.create("Scout");
    await manager.setOrchestrator(scout.id);

    faux.setResponses([tool("rename_me", { name: "Ranger" }), reply]);
    await say(await manager.get(scout.id), "call yourself Ranger");
    expect(await manager.record(scout.id)).toMatchObject({ name: "Ranger", orchestrator: true });
    // The next prompt uses the new name.
    let before = seen.length;
    faux.setResponses([reply]);
    await say(await manager.get(scout.id), "hi");
    expect(seen[before]).toContain("You are Ranger,");

    faux.setResponses([tool("rename_bot", { botId: scout.id, name: "Scout Two" }), reply]);
    await say(await manager.get(admin.id), "rename Ranger to Scout Two");
    expect((await manager.record(scout.id)).name).toBe("Scout Two");

    faux.setResponses([tool("rename_bot", { botId: admin.id, name: "Boss" }), reply]);
    await say(await manager.get(admin.id), "rename yourself Boss");
    expect(seen.at(-1)).toContain("the Admin Bot is always");
    expect((await manager.record(admin.id)).name).toBe("Admin Bot");

    // Admin Bot has no rename_me; other bots have no rename_bot.
    before = seen.length;
    faux.setResponses([reply]);
    await say(await manager.get(admin.id), "tools?");
    expect(hasTool(seen[before], "rename_bot")).toBe(true);
    expect(hasTool(seen[before], "rename_me")).toBe(false);
    before = seen.length;
    faux.setResponses([reply]);
    await say(await manager.get(scout.id), "tools?");
    expect(hasTool(seen[before], "rename_me")).toBe(true);
    expect(hasTool(seen[before], "rename_bot")).toBe(false);
  });

  it("searches and reads only the bot's own main channel and threads", async () => {
    const ada = await manager.get((await manager.create("Ada")).id);
    const bob = await manager.get((await manager.create("Bob")).id);
    faux.setResponses(Array.from({ length: 5 }, () => reply));
    await say(ada, "The code word is Pelican");
    await say(bob, "bob also says pelican");
    const main = await ada.main();
    const forkAt = (await main.entries({ order: "descending" }, 1, undefined, ctx)).items[0];
    const thread = await ada.fork({ entryId: Number(forkAt?.id) });
    const sent = await ada.send("pelican migration plans", thread.conversationId);
    await sent.submission.wait(ctx);
    await manager.registry.setThreadTitleIfUntitled(ada.id, thread.conversationId, "Bird trips");

    // Ada searches, reads her thread, then tries a conversation that isn't hers.
    const calls: [string, Record<string, string | number>][] = [
      ["search_history", { query: "PELICAN", limit: 5 }],
      ["read_thread", { threadId: thread.conversationId }],
      ["read_thread", { threadId: 999 }],
    ];
    const step: Step = (context) => {
      const json = JSON.stringify(context);
      seen.push(json);
      const turn = json.slice(json.lastIndexOf('"content":"look it up"'));
      const next = calls[turn.split('"role":"toolResult"').length - 1];
      if (!next) return fauxAssistantMessage([fauxText("done")]);
      return fauxAssistantMessage([fauxToolCall(next[0], next[1])], { stopReason: "toolUse" });
    };
    faux.setResponses(Array.from({ length: 5 }, () => step));
    await say(ada, "look it up");
    const last = JSON.parse(seen.at(-1) ?? "{}") as {
      messages: { role: string; content: { type: string; text?: string }[] }[];
    };
    const results = last.messages
      .filter((message) => message.role === "toolResult")
      .map((message) => message.content.map((part) => part.text ?? "").join(""));
    expect(results).toHaveLength(3);

    const hits = JSON.parse(results[0] ?? "[]") as { conversationId: number; title: string }[];
    // Newest first: the thread message, then the main channel one; never Bob's.
    expect(hits.map((hit) => [hit.conversationId, hit.title])).toEqual([
      [thread.conversationId, "Bird trips"],
      [main.id, "Main channel"],
    ]);
    expect(results[0]).toContain("The code word is Pelican");
    expect(results[0]).not.toContain("bob also says");

    expect(results[1]).toMatch(/^Thread \d+: Bird trips\n\[\d+\] user: pelican migration plans\n/);
    expect(results[1]).not.toContain("The code word"); // inherited entries belong to main
    expect(results[2]).toContain("no thread 999");
  });

  it("limits messages per pair over a sliding hour", () => {
    let now = 0;
    const limiter = new MessageLimiter(2, () => now);
    expect(limiter.take("a", "b")).toBe(true);
    expect(limiter.take("a", "b")).toBe(true);
    expect(limiter.take("a", "b")).toBe(false);
    expect(limiter.take("b", "a")).toBe(true);
    now = 3_600_001;
    expect(limiter.take("a", "b")).toBe(true);
  });
});
