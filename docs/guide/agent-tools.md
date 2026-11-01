# Agent tools

Woven Matter gives every supported harness the same app tools through Woven MCP:
Pi Durable, Codex, Claude Code, Grok Build, and OpenCode, on your Mac and in
remote workspaces. Tools are grouped, and you decide which groups each
conversation can use.

## Tool groups

| Group | What the agent can do | Starts |
| --- | --- | --- |
| **Notes** | Find, read, create, and edit notes, spreadsheets, HTML, and managed databases | On |
| **Conversation history** | Search and read earlier conversations | On |
| **Session management** | Create other sessions, message them, and coordinate their work | On |
| **Timers** | Schedule one-time or recurring follow-ups in its own conversation | On |
| **Usage data** | Read usage analytics and cached limits. Always read only | On |
| **Calendar** | Read, and with Full access create and edit, events and scheduled tasks | On, Full access |
| **Library** | Find files, links, and photos exchanged in conversations, with their source messages. Read only | On |
| **Browser Use** | Control the workspace's shared browser, including screenshots | On |
| **Computer Use** | Control your Mac's desktop | Off |
| **Executor** | Search and run actions in connected apps you select | Off |

Two capabilities are always available and have no switch:

- **Goals** keep a conversation working toward an outcome across turns. See
  [Goals](agents.md#goals).
- **Visual replies** let the agent publish an interactive HTML page in the
  conversation.

Browser Use on your Mac controls Woven Matter's built-in browser, including the
sites you are signed in to. In a remote workspace it controls that host's own
browser, which you can watch with **View browser**. See
[Remote workspaces](remote-workspaces.md#browse-inside-a-workspace).

Computer Use works only on a Mac. You must also grant Woven Matter Screen
Recording and Accessibility in macOS; agents cannot grant these themselves.

Executor needs its own setup before it does anything. See [Executor apps](executor.md).

## Defaults and per-conversation controls

Defaults apply only to **new** conversations. Each conversation keeps its own
selection, and changing a default never changes existing conversations.

- **Settings → General → Woven MCP** sets the shared defaults, the Calendar
  access mode (Full access or Read only), and session limits.
- A harness's Settings page has its own **Woven MCP** card for defaults in a
  particular workspace. **Use shared defaults** returns to the General settings.
  Turning off **Enable Woven MCP** there starts new chats with every optional
  group off.
- **Settings → General → Connected apps · Executor** chooses which Executor apps
  new conversations receive.

In a conversation, open **Tools** in the composer to turn groups on or off. Changes
apply from the next tool call. Disabling Timers while timers are active asks you
to confirm pausing them.

Permissions come from you, not the agent. A tool call cannot turn on a group,
raise Calendar access, or change the conversation's permission mode.

## Access to other conversations

Attaching a conversation with the composer's plus button gives the agent read
access to that one conversation, even when Conversation history is off. With
Session management on, an agent can message and manage sessions it created.
Managing an existing session without history access or an attachment asks for
your approval first. Revoking access stops future reads; it cannot remove
content the agent already retrieved.

## Outside agents

Agents that Woven Matter did not launch can use the same tools through
**Settings → General → Outside agents · Woven MCP**. This is off by default.

When you turn on **Expose Woven MCP**, Woven Matter publishes a private HTTPS
endpoint on your Tailnet and you choose which optional groups it offers. Goals
and visual replies are always included. Computer Use and Executor start off.

Access is instance-wide. **Any agent that your Tailnet policy allows to reach
the endpoint can use every enabled group, including writes.** There is no
per-agent token, enrollment, or expiry, and access is not tied to a particular
chat. Use your Tailscale access controls to limit which devices can reach it.

- Outside agents name a target conversation for goals, timers, and visual
  replies. Naming one does not grant access to that chat's history.
- Calendar writes follow this page's Calendar switch, independently of the
  Calendar access default for Woven Matter chats.
- Turning exposure off rejects new requests. Timers that were already accepted
  keep their schedule until you pause or remove them.
- Woven Matter never exposes the endpoint publicly through Tailscale Funnel. If
  Tailscale is unavailable, Settings shows the error and only a local endpoint.

For tool names, arguments, and retry behavior, see the technical
[agent tools reference](../AGENT_TOOLS.md).
