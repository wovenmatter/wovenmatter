import { defineExtension, defineTool, type Extension } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import type { Forum } from "./forum.ts";
import type { BotRecord, BotRegistry } from "./storage/registry.ts";
import { run } from "./tools.ts";
import { localTimeZone, parseDate, parseTimeOfDay, zonedEpoch } from "./zoned-time.ts";

const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/**
 * A bot's Forum tools: `forum_post` and `forum_read`, and for Admin Bot `forum_schedule`. Every
 * bot has them in all its conversations; a bot that is not in the Forum is told so when it calls
 * one. Subagents never get them.
 */
export function forumTools(
  record: BotRecord,
  forum: () => Forum | undefined,
  registry: () => BotRegistry,
): Extension {
  const botId = record.id;
  const open = (): Forum => {
    const found = forum();
    if (!found) throw new Error("the Forum is still starting");
    return found;
  };
  const tools = [
    defineTool({
      name: "forum_post",
      description:
        "Post to the Forum, the group chat the user and every bot here share. From your Forum conversation or a Forum thread it posts there; from any other conversation it posts to the Forum. Everyone in that room sees it. You cannot @mention or start threads: only the user does.",
      parameters: Type.Object({
        text: Type.String({ description: "The post" }),
        threadId: Type.Optional(
          Type.Integer({ description: "Post to this Forum thread instead (one you are in)" }),
        ),
      }),
      execute: (args, api) =>
        run(async () => {
          const post = await open().postAsBot(botId, {
            text: args.text,
            ...(args.threadId !== undefined ? { threadId: args.threadId } : {}),
            conversationId: Number(api.conversationId),
          });
          return `Posted as #${post.id}.`;
        }),
    }),
    defineTool({
      name: "forum_read",
      description:
        "Read the Forum (or one of its threads you are in) back: its posts, newest last. Without `before` you get the newest ones.",
      parameters: Type.Object({
        threadId: Type.Optional(Type.Integer({ description: "A Forum thread you are in" })),
        before: Type.Optional(Type.Integer({ description: "Only posts before this post number" })),
        limit: Type.Optional(
          Type.Integer({ minimum: 1, maximum: 200, description: "How many posts (default 40)" }),
        ),
      }),
      replay: "safe",
      execute: (args, api) =>
        run(() =>
          open().read(botId, {
            ...(args.threadId !== undefined ? { threadId: args.threadId } : {}),
            ...(args.before !== undefined ? { before: args.before } : {}),
            ...(args.limit !== undefined ? { limit: args.limit } : {}),
            conversationId: Number(api.conversationId),
          }),
        ),
    }),
  ];
  if (record.kind !== "admin") return defineExtension({ name: "woven-forum", tools });
  const schedule = defineTool({
    name: "forum_schedule",
    description:
      "Manage the user's scheduled Forum posts when they ask: texts Woven Matter posts to the Forum as the user at a set time. list: every scheduled post. add: a new one (once on a date, or repeating daily, on weekdays, or weekly on one day). remove: one by its id. Only while you are in the Forum.",
    parameters: Type.Object({
      action: Type.Union([Type.Literal("list"), Type.Literal("add"), Type.Literal("remove")]),
      id: Type.Optional(Type.String({ description: "remove: the scheduled post's id (from list)" })),
      text: Type.Optional(Type.String({ description: "add: what to post" })),
      repeat: Type.Optional(
        Type.Union([
          Type.Literal("once"),
          Type.Literal("daily"),
          Type.Literal("weekdays"),
          Type.Literal("weekly"),
        ]),
      ),
      time: Type.Optional(Type.String({ description: "add: time of day, HH:MM (24-hour)" })),
      date: Type.Optional(Type.String({ description: "add, once: the date, YYYY-MM-DD" })),
      weekday: Type.Optional(Type.String({ description: "add, weekly: the day, e.g. monday" })),
      timeZone: Type.Optional(
        Type.String({ description: "IANA time zone; default: this machine's" }),
      ),
      mention: Type.Optional(
        Type.Array(Type.String(), {
          description: 'add: names of bots the post asks to reply, or ["everyone"]',
        }),
      ),
    }),
    execute: (args) =>
      run(async () => {
        const target = open();
        const self = await registry().get(botId);
        if (!self || !(await target.isActive(self))) {
          throw new Error(
            "You are not in the Forum. The user can add you from the Forum's member list.",
          );
        }
        if (args.action === "list") return target.schedules();
        if (args.action === "remove") {
          if (!args.id) throw new Error("id is required");
          await target.deleteSchedule(args.id);
          return "Removed that scheduled post.";
        }
        if (!args.text) throw new Error("text is required");
        const repeat = args.repeat ?? "once";
        const time = parseTimeOfDay(args.time ?? "");
        if (!time) throw new Error("time is required, as HH:MM (24-hour)");
        const timeZone = args.timeZone ?? localTimeZone();
        const asked = (args.mention ?? []).map((name) => name.trim().toLowerCase());
        const everyone = asked.includes("everyone");
        const bots = await registry().list();
        const mentions: string[] = [];
        for (const name of everyone ? [] : asked) {
          const found = bots.find((bot) => bot.name.toLowerCase() === name);
          if (!found) throw new Error(`no bot named ${name}`);
          mentions.push(found.id);
        }
        let at: number | undefined;
        if (repeat === "once") {
          const date = parseDate(args.date ?? "");
          if (!date) throw new Error("date is required for a one-time post, as YYYY-MM-DD");
          at = zonedEpoch(date.year, date.month, date.day, time.hour, time.minute, timeZone);
        }
        const weekday = WEEKDAYS.indexOf((args.weekday ?? "").trim().toLowerCase());
        if (repeat === "weekly" && weekday < 0) {
          throw new Error("weekday is required for a weekly post");
        }
        const saved = await target.saveSchedule({
          text: args.text,
          mentions,
          everyone,
          repeat,
          ...(repeat === "once" ? { at: at as number } : { time: args.time as string }),
          ...(repeat === "weekly" ? { weekday } : {}),
          timeZone,
        });
        return { scheduled: saved.at(-1) };
      }),
  });
  return defineExtension({ name: "woven-forum", tools: [...tools, schedule] });
}
