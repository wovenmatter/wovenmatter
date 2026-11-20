import { defineExtension, defineTool, section, type Extension } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import type { HostChannel } from "./host/channel.ts";

/** One Woven tool as the server's catalog describes it (MCP's `tools/list` shape). */
type CatalogTool = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  annotations?: { readOnlyHint?: boolean };
};

/**
 * A bot's Woven tools: the server's one catalog, carried out by the server. The server says
 * whether the bot may use them (`bots.wovenTools`: paused for all, or this bot switched off), and
 * it is asked again every time the server connects, not only when the bot opens: a bot that was
 * off when it opened gets the tools once a later connection allows them. The server checks the
 * same setting on every call, so a bot turned off later is refused.
 */
export function wovenTools(
  botId: string,
  host: HostChannel,
  install: (extension: Extension) => void,
  inForum: (conversationId: number) => Promise<boolean>,
): void {
  let installed = false;
  const ask = async () => {
    if (installed || !host.connected) return;
    const reply = await host.call("tools.list", { botId });
    if (!reply.allowed || installed) return;
    installed = true;
    install(extension(botId, host, reply.tools, reply.instructions, inForum));
  };
  host.onConnected(() => void ask().catch(() => {}));
  void ask().catch(() => {});
}

/**
 * A call says when it comes from the bot's Forum seat (`forum`), and its result's `_meta` becomes the
 * result's details: a page `render_html` published (`wovenPage`), which the chat and the library
 * copy show in its place.
 */
function extension(
  botId: string,
  host: HostChannel,
  tools: CatalogTool[],
  instructions: string,
  inForum: (conversationId: number) => Promise<boolean>,
): Extension {
  return defineExtension({
    name: "woven",
    sections: [section("woven", () => instructions, { tag: false })],
    tools: tools.map((tool) =>
      defineTool({
        name: `woven_${tool.name}`,
        description: tool.description,
        parameters: Type.Unsafe<Record<string, unknown>>(tool.inputSchema),
        ...(tool.annotations?.readOnlyHint ? { replay: "safe" as const } : {}),
        execute: async (args, api) => {
          try {
            const forum = await inForum(Number(api.conversationId));
            const result = await host.call("tools.call", {
              botId,
              name: tool.name,
              arguments: args ?? {},
              ...(forum ? { forum } : {}),
            });
            return {
              output: result.content.map((block) =>
                block.type === "image"
                  ? { type: "image" as const, data: block.data, mimeType: block.mimeType }
                  : { type: "text" as const, text: block.text },
              ),
              isError: result.isError,
              ...(result._meta ? { details: result._meta } : {}),
            };
          } catch (error) {
            return {
              output: [{ type: "text" as const, text: error instanceof Error ? error.message : String(error) }],
              isError: true,
            };
          }
        },
      }),
    ),
  });
}
