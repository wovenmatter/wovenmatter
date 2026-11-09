const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })

// The Woven MCP groups this machine's library host serves (docs: "Library
// host", local API). Spreadsheet and HTML note artifacts are part of notes.
export const libraryServedGroups = Object.freeze(new Set(['notes', 'history', 'calendar', 'library']))
// Single library-backed tools of other groups (LibraryHost.servedTools).
export const libraryServedTools = Object.freeze(new Set(['woven_sessions_folders']))
const toolGroups = new Set([...libraryServedGroups, 'sessions'])

/**
 * The one adapter between Woven MCP and the local library socket: it registers
 * a session as a library caller once, then sends stateless JSON-RPC to
 * `POST /v1/mcp` with the caller's current tool selection. `callerInfo(id)`
 * supplies the session's title, harness and working directory.
 */
export function createLocalLibraryTools({ client, available, callerInfo = () => ({}), maximumReplyBytes = 4 * 1024 * 1024 }) {
  const registered = new Set()
  async function register(conversationID, groups) {
    if (registered.has(conversationID)) return
    let info = {}
    try { info = callerInfo(conversationID) ?? {} } catch {}
    // Registration names the session; `/v1/mcp` also registers on first use,
    // so a failure here is not fatal.
    try { await client.registerCaller({ conversationID, ...info, enabledGroups: groups }); registered.add(conversationID) } catch {}
  }
  // `bot` ({principal, botID, botName}) calls as an app-wide bot caller
  // (`woven:bot:<this host's member device ID>:<bot>`), with no conversation.
  async function call({ conversationID, bot, groups, message, signal }) {
    if (!available()) throw fail(503, 'This machine’s library is not running yet. Notes, calendar and history tools return when it restarts; inspect prior effects before retrying a change.')
    const served = [...groups].filter(group => toolGroups.has(group)).sort()
    const caller = bot
      ? { 'x-woven-caller': bot.principal, 'x-woven-bot-id': bot.botID, 'x-woven-bot-name': encodeURIComponent(bot.botName ?? 'Bot') }
      : { 'x-woven-conversation-id': conversationID }
    if (!bot) await register(conversationID, served)
    const reply = await client.mcp(message, { ...caller, 'x-woven-enabled-groups': served.join(','), 'mcp-protocol-version': '2025-06-18' }, { signal })
    if (reply.status === 202) return null
    if (reply.status !== 200 || !reply.body || typeof reply.body !== 'object' || Buffer.isBuffer(reply.body)) {
      throw fail(reply.status === 413 ? 413 : 502, typeof reply.body?.message === 'string' ? reply.body.message.slice(0, 512) : 'The local library refused this Woven MCP request.')
    }
    if (Buffer.byteLength(JSON.stringify(reply.body)) > maximumReplyBytes) throw fail(413, 'The library MCP response is too large. Request a smaller page.')
    return reply.body
  }
  return { call, available, forget: conversationID => registered.delete(conversationID) }
}
