# Conversations

Choose **New chat** and select an agent. Agent names in the sidebar open their
most recent chat; the separate plus starts a new chat with that agent in the
selected folder. Woven groups agents by their local or remote workspace. Select
a model and thinking level where the harness offers them.

Before the first message, the composer's folder selector lists **All Workspaces**
and the sidebar folders. Folders belonging to another execution workspace are
disabled. All Workspaces gives each chat its own blank scratch directory. The
first message fixes the folder and working directory; use a new chat for another root.

## Models, thinking, tools, and permissions

Selections belong to the conversation and stay with it when you reopen it. The
composer popouts contain the choices for that conversation. Previously saved
workspace and harness defaults are retained. New conversations use this order:

1. A choice supplied for that conversation.
2. The workspace default for that harness.
3. The harness default.
4. Woven Matter's starting default: **Full access** for permissions on supported
   harnesses; the harness's own default for other selections.

New conversations start with Full access unless you choose the harness's auto
mode or saved it as a default.

Existing conversations keep their selections when defaults change. Defaults are
independent for each control, so a saved workspace default can override the model
while inheriting the harness's permission choice.

Woven Matter offers two permission choices, and only those the harness
supports appear:

- **Full access** allows commands and edits without ordinary approval prompts,
  within the harness's enforced policy. It is the default everywhere.
- The harness's auto mode uses the harness's own review system to evaluate
  actions and decide what it can approve. This is not blanket acceptance of
  requests. Codex calls it **Approve for me**; Claude Code and Grok Build call
  it **Auto**, and show it only when their adapter supports it.

Pi Durable and OpenCode have no auto mode, so they always run in Full access.
Questions and sign-in steps still need your response in every mode. Changing
Grok Build's policy reconnects the same conversation before the next message.

There is no Ask for approval mode. A conversation or default saved in Ask for
approval, or in another mode Woven Matter no longer offers (such as Read only,
Plan, Auto-accept edits, Don't ask, or OpenCode's Deny), moves to Full access
the next time it runs. If the harness withholds Full access, it moves to the
harness's auto mode instead.

Wait for a settings change to finish before sending.

## App tools and session access

Use **Tools** in the composer to turn Notes, Conversation history, Session
management, Timers, Usage data, Calendar, Library, Executor, Browser Use, and
Computer Use on or off for that conversation. Defaults for new chats are in
**Settings → Woven MCP → Tools for new chats**. Calendar can be Full access or
Read only; Usage data and Library are read-only tools. Library lets an agent find
exchanged files, links, and photos and identify their source messages. Browser
Use controls the browser inside Woven Matter. Computer Use lets an agent see and
use other apps on your Mac once Accessibility and Screen Recording are allowed in
**Settings → Permissions & Access**. Executor starts off; see
[Executor apps](executor.md). Goals and visual replies are always available.

Use the plus button to **Upload photos or files**, **Attach note**, or
**Attach conversation**. You can also drop files onto the composer or paste
a screenshot. Attachments remain drafts until you send the message. Files and
photos appear in [Library](notes-and-data.md#library) after sending; note and
conversation references stay attached to the message.

Attaching a conversation grants read-only access to that session even when
Conversation history is disabled. Session management lets an agent create or
message other sessions. Managing an existing session without history or an
attachment grant asks for your approval. You can end coordination from the
session controls; answering permission requests remains your responsibility.

## Work across sessions in parallel

Run multiple sessions with the same harness or across different harnesses. Use
panels to view up to five sessions at once, while additional sessions can continue
running in the background. Open a note beside your conversation to work on it
with your agent.

Read responses and tool activity as the agent works. Answer questions and
permission requests in the conversation; the available choices come from the harness.

## Organize and continue your work

Use folders to keep related conversations and notes together. **Recents** lets
you return to work across your harnesses. Woven Matter saves conversation
transcripts in your library alongside your notes and other items, and each
paired Mac and Linux host keeps its own copy.

Reopen a conversation to review the work or continue a supported session.
Reconnect an unavailable agent before sending another request. Agents in the
same project can work on its files; each conversation retains its own harness,
execution workspace, and working directory.

Sessions from the former workspace layout remain readable as archived history.
Their composer is disabled and they cannot be resumed. Start a new chat to
continue working; existing project files are preserved.

Local OpenCode settings also offer session imports.
Available history and import limits depend on the integration. Imported sessions
retain their original working directory where supplied by the harness.

## Attachments and connections

Use the attachment picker to add files or references. Supported file attachments
are copied into managed remote workspaces when you send them. Attachment support
still depends on the harness. Entering a Mac path in message text does not upload
that file to a remote workspace.

A chat running on another Mac or a Linux host streams live from that machine
while it is open. When that machine is offline, the chat shows its saved
history and goes live again when the machine is back.

If a connection drops while sending, review the conversation status before
retrying. The agent may have accepted the request even if the app did not receive
a response.

Next: [Notes and data](notes-and-data.md) or [Troubleshooting](troubleshooting.md).
