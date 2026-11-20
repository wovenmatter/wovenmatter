import type { Extension } from "@earendil-works/pi-durable";
import type { HostCall } from "./host/channel.ts";

/**
 * Where Woven tools attach for a bot. The server says whether the bot may use them
 * (`tools.access`, from Settings → Bots → Bot access); when it may, the Woven tool catalog's
 * extension is returned here and installed on the bot's harness. The catalog is not offered to
 * bots yet, so no bot gets Woven tools today.
 */
export async function wovenTools(botId: string, call: HostCall): Promise<Extension | undefined> {
  const { allowed } = await call("tools.access", { botId });
  if (!allowed) return undefined;
  // The Woven tool catalog's extension is returned here once bots are offered it.
  return undefined;
}
