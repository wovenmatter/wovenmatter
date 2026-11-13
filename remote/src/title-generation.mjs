import { openEphemeralACP, ephemeralSession } from './ephemeral-acp.mjs'

// The Mac's title instructions (`CodexConversationTitleGenerator`), verbatim.
export const titleInstructions = `Generate a short title that helps the user recognize this conversation later.
Return only JSON in this form: {"title":"..."}.
Aim for 3 to 8 words and fewer than 40 characters.
Name the main topic and requested outcome. Avoid workflow, tool, model or agent names unless they are the subject of the conversation.
Do not claim completion. Do not include quotation marks within the title or end it with punctuation.
Do not call tools or modify files.`

// The Mac's cleanup: the JSON `title` (or the first line), trimmed of quotes
// and whitespace, runs of whitespace collapsed, trailing periods removed, and
// at most 50 characters. Null when nothing is left.
export function sanitizeTitle(raw) {
  const text = String(raw ?? '').trim()
  const field = value => { try { const parsed = JSON.parse(value); return typeof parsed?.title === 'string' ? parsed.title : null } catch { return null } }
  const start = text.indexOf('{'), end = text.lastIndexOf('}')
  let title = field(text) ?? (start >= 0 && end > start ? field(text.slice(start, end + 1)) : null) ?? text.split('\n')[0]
  title = title.replace(/^[`"'\s]+|[`"'\s]+$/g, '').replace(/\s+/g, ' ').replace(/^\.+|\.+$/g, '')
  if ([...title].length > 50) title = [...title].slice(0, 47).join('').trimEnd() + '…'
  return title || null
}

// Titles a chat from its first message with this host's Codex, as the Mac
// titles its chats with its own Codex. The harness runs in `cwd` with no
// Woven tools and every permission request denied.
export function createTitleGenerator({ catalog, environment, cwd, spawnProcess, timeoutMilliseconds = 60000, runtimeKind = 'codex' }) {
  return async function generate(firstMessage) {
    const harness = catalog.get(runtimeKind)
    if (!harness || !['acp', 'agent-stdio'].includes(harness.transport) || typeof firstMessage !== 'string' || !firstMessage.trim()) return null
    let answer = ''
    const connection = openEphemeralACP({ harness, runtimeKind, cwd: await cwd(), environment, spawnProcess, timeoutMilliseconds,
      onUpdate: update => { if (update.sessionUpdate === 'agent_message_chunk' && typeof update.content?.text === 'string') answer += update.content.text } })
    try {
      const session = await ephemeralSession(connection, await cwd())
      await connection.request('session/prompt', { sessionId: session.sessionId,
        prompt: [{ type: 'text', text: `${titleInstructions}\n\nFirst message:\n${firstMessage}` }] }, timeoutMilliseconds)
      return sanitizeTitle(answer)
    } finally { await connection.close() }
  }
}
