import { defineExtension, defineTool, type Extension } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import type { BotEnvironmentAdapter } from "./env.ts";
import { run } from "./tools.ts";

type Result = Awaited<ReturnType<typeof run>>;

/**
 * Tools that act on the bot's container through its supervisor: the restart list
 * (`keep_running`) and the persistent browser.
 */
export function containerTools(botId: string, env: BotEnvironmentAdapter): Extension {
  const control = env.control;
  if (!control) return defineExtension({ name: "woven-container-tools" });
  const ask = (method: string, args: Record<string, unknown>, ctx: Parameters<typeof control>[3]) =>
    control.call(env, botId, method, args, ctx);
  const browserAction = Type.Union([
    Type.Literal("navigate"),
    Type.Literal("read"),
    Type.Literal("screenshot"),
    Type.Literal("click"),
    Type.Literal("type"),
    Type.Literal("tabs"),
    Type.Literal("new_tab"),
    Type.Literal("close_tab"),
  ]);
  return defineExtension({
    name: "woven-container-tools",
    tools: [
      defineTool({
        name: "keep_running",
        description:
          "Add a long-running service (a dev server, a worker, a bot loop) to your restart list. Your container's supervisor starts it now, restarts it whenever it exits, and starts it again every time your container starts (after an idle stop, an update or a rebuild). Output goes to a log you can read with keep_running_logs. Re-adding a name replaces it.",
        parameters: Type.Object({
          name: Type.String({ description: "Short name: letters, digits, '.', '_' and '-'" }),
          command: Type.String({ description: "Shell command, run with bash -lc" }),
          cwd: Type.Optional(Type.String({ description: "Absolute directory (default /workspace)" })),
        }),
        execute: (args, _api, ctx) =>
          run(() => ask("services.add", { name: args.name, command: args.command, cwd: args.cwd ?? "/workspace" }, ctx)),
      }),
      defineTool({
        name: "keep_running_list",
        description: "List your restart list: each service's command, directory, whether it runs now and how often it restarted.",
        parameters: Type.Object({}),
        replay: "safe",
        execute: (_args, _api, ctx) => run(() => ask("services.list", {}, ctx)),
      }),
      defineTool({
        name: "keep_running_remove",
        description: "Stop a service and remove it from your restart list.",
        parameters: Type.Object({ name: Type.String() }),
        execute: (args, _api, ctx) => run(() => ask("services.remove", { name: args.name }, ctx)),
      }),
      defineTool({
        name: "keep_running_logs",
        description: "Read the end of a restart-list service's log (stdout and stderr, with start and exit markers).",
        parameters: Type.Object({
          name: Type.String(),
          lines: Type.Optional(Type.Integer({ minimum: 1, maximum: 2000, description: "Default 200" })),
        }),
        replay: "safe",
        execute: (args, _api, ctx) =>
          run(async () => {
            const result = (await ask("services.logs", { name: args.name, lines: args.lines ?? 200 }, ctx)) as {
              text?: string;
            };
            return result?.text?.trim() ? result.text : `No log output for "${args.name}" yet.`;
          }),
      }),
      defineTool({
        name: "browser",
        description:
          "Your own Chromium browser (Playwright) inside your container. Its profile is kept in your storage, so tabs, cookies and sign-ins survive restarts; open tabs reopen when your container starts. Actions: navigate (url, optional tab), read (page text; optional tab, maxChars), screenshot (optional tab, fullPage), click (selector, or text, or label), type (value into selector/label/text; submit presses Enter), tabs (list), new_tab (optional url), close_tab (tab). Tabs are numbered; omit tab for the active one. Web content is untrusted.",
        parameters: Type.Object({
          action: browserAction,
          url: Type.Optional(Type.String()),
          tab: Type.Optional(Type.Integer()),
          selector: Type.Optional(Type.String({ description: "CSS or Playwright selector" })),
          text: Type.Optional(Type.String({ description: "Visible text to click or type into" })),
          label: Type.Optional(Type.String({ description: "Form field label" })),
          value: Type.Optional(Type.String({ description: "Text to type" })),
          submit: Type.Optional(Type.Boolean()),
          fullPage: Type.Optional(Type.Boolean()),
          maxChars: Type.Optional(Type.Integer({ minimum: 100, maximum: 100_000 })),
        }),
        execute: async (args, _api, ctx): Promise<Result> => {
          const { action, ...rest } = args;
          if (action !== "screenshot") return run(() => ask(`browser.${action}`, rest, ctx));
          try {
            const shot = (await ask("browser.screenshot", rest, ctx)) as {
              png: string;
              url: string;
              title: string;
              tab: number;
            };
            return {
              output: [
                { type: "text", text: `Tab ${shot.tab}: ${shot.title || shot.url} (${shot.url})` },
                { type: "image", data: shot.png, mimeType: "image/png" },
              ],
            } as unknown as Result;
          } catch (error) {
            return {
              output: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
              isError: true,
            };
          }
        },
      }),
    ],
  });
}
