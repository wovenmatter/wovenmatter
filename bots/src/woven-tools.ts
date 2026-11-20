import { defineExtension, defineTool, section, type Extension } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import type { HostChannel } from "./host/channel.ts";
import type { VisualReply } from "./protocol.ts";

/** One Woven tool as the server's catalog describes it (MCP's `tools/list` shape). */
type CatalogTool = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  annotations?: { readOnlyHint?: boolean };
};

const WOVEN = "woven";

/**
 * Where the Woven tools go in a bot's extensions until the server lists them: conversations select
 * extensions by name from the harness's list, so the tools installed later under this name replace
 * it in place and are offered.
 */
export const wovenToolsSlot: Extension = defineExtension({ name: WOVEN });

/** The bot's Forum seats, as its Woven tools need them. */
export type WovenForumSeats = {
  /** Whether a conversation of the bot is one of its Forum seats. */
  seated(conversationId: number): Promise<boolean>;
  /** A visual reply published from a seat becomes a post in that seat's room. */
  publish(conversationId: number, visualReply: VisualReply): Promise<void>;
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
  seats: WovenForumSeats,
): void {
  let installed = false;
  const ask = async () => {
    if (installed || !host.connected) return;
    const reply = await host.call("tools.list", { botId });
    if (!reply.allowed || installed) return;
    installed = true;
    install(extension(botId, host, reply.tools, reply.instructions, seats));
  };
  host.onConnected(() => void ask().catch(() => {}));
  void ask().catch(() => {});
}

/**
 * A call says when it comes from the bot's Forum seat (`forum`), and its result's `_meta` becomes the
 * result's details: a visual reply `render_html` published (`wovenVisualReply`), which the chat and the
 * library copy show in its place. One published from a seat is posted to the seat's room.
 */
function extension(
  botId: string,
  host: HostChannel,
  tools: CatalogTool[],
  instructions: string,
  seats: WovenForumSeats,
): Extension {
  return defineExtension({
    name: WOVEN,
    sections: [section("woven", () => instructions, { tag: false })],
    tools: tools.map((tool) =>
      defineTool({
        name: `woven_${tool.name}`,
        description: tool.description,
        parameters: Type.Unsafe<Record<string, unknown>>(tool.inputSchema),
        ...(tool.annotations?.readOnlyHint ? { replay: "safe" as const } : {}),
        execute: async (args, api) => {
          try {
            const conversationId = Number(api.conversationId);
            const forum = await seats.seated(conversationId);
            const result = await host.call("tools.call", {
              botId,
              name: tool.name,
              arguments: args ?? {},
              ...(forum ? { forum } : {}),
            });
            const visualReply = result.isError ? undefined : result._meta?.wovenVisualReply;
            if (forum && visualReply) await seats.publish(conversationId, visualReply);
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
