# Conversations

Choose **New chat** and select an agent. WovenMatter groups agents by their local,
remote, or linked Buzz workspace. Choose where you want the work to run, then
select a model and thinking level where the harness offers those controls.

## Models, thinking, tools, and permissions

Selections belong to the conversation and stay with it when you reopen it. The
composer popouts contain the choices for that conversation. Previously saved
workspace and harness defaults are retained. New conversations use this order:

1. A choice supplied for that conversation.
2. The workspace default for that harness.
3. The harness default.
4. WovenMatter's starting default: **Full access** for permissions on supported
   harnesses; the harness's own default for other selections.

New conversations start with Full access unless you choose a different policy
or have a previously saved default. Existing and imported conversations keep their current policy.
Pi has no permission setting.

Existing conversations keep their selections when defaults change. Defaults are
independent for each control, so a saved workspace default can override the model
while inheriting the harness's permission choice.

Permission choices follow the selected harness. Similar names have consistent
meanings:

- **Ask for approval** keeps the harness's approval prompts.
- **Auto-accept edits** allows file edits while leaving other actions subject to
  approval.
- **Auto**, **Auto-review**, or **Smart approvals** uses the harness's own review
  system to evaluate actions and decide what it can approve. This is not blanket
  acceptance of requests.
- **Full access** allows commands and edits without ordinary approval prompts,
  within the harness's enforced policy.

Only supported choices appear. A harness may also offer more specific policies:

- Codex offers **Ask for approval**, **Approve for me**, and **Full access** when
  its adapter advertises those native modes. Approve for me uses native automatic
  review; older adapters without that capability do not advertise it as smart
  approval.
- Claude Code offers its available native **Ask for approval**, **Auto-accept
  edits**, **Auto**, and **Full access** modes. Auto appears only when supported.
- Grok Build offers its native approval policies. Changing the policy reconnects
  the same conversation before the next message.
- OpenClaw offers **Ask for approval**, **Auto**, and **Full access**. Auto uses
  OpenClaw's command reviewer within the session workspace.
- Hermes offers **Ask for approval** and **Full access** in the composer. Ask
  restores the profile's approval policy. Choose **Ask for approval** or **Smart
  approvals** in Hermes Settings; that choice applies to every conversation
  using that profile. Smart approvals uses Hermes's native reviewer. A profile
  or process that already forces Full access cannot be restricted by the
  conversation control.
- OpenCode offers **Ask for approval**, **Auto-accept edits**, and **Full access**.
  Cursor offers **Ask for approval** and **Full access**. These apply to the
  conversation while WovenMatter is connected. They do not run a smart reviewer
  or save permissions for other conversations. Native deny rules remain in
  effect; questions and sign-in steps still need your response. Returning to Ask
  stops accepting new requests and preserves permissions already allowed by the
  harness.
- Pi has no permission selector. WovenMatter does not manage Pi permission
  extensions.

Wait for a settings change to finish before sending. If a saved choice is no
longer available, choose a supported value before continuing the conversation.

## App tools and session access

Use **Tools** in the composer to control Notes, Conversation history, Session
management, Timers, Usage data, Calendar, and Library independently. General
settings supplies defaults for new sessions. Calendar can be Full access or Read
only; Usage data and Library are read-only tools. Library lets an agent find
exchanged files, links, and photos and identify their source messages.

Use the plus button to **Attach or upload photos or files**, **Attach notes**,
or **Attach conversation**. You can also drop files onto the composer or paste
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
you return to work across your harnesses. WovenMatter saves conversation
transcripts in its local SQLite database alongside your notes and other items.

Reopen a conversation to review the work or continue a supported session.
Reconnect an unavailable agent before sending another request. Shared workspace
files let different harnesses work on the same material; each conversation
retains its own harness and session connection.

OpenClaw, Hermes, and local OpenCode settings also offer session imports.
Available history and import limits depend on the integration. Imported sessions
retain their original working directory where supplied by the harness.

## Attachments and connections

Use the attachment picker to add files or references. Supported file attachments
are copied into managed remote workspaces when you send them. Attachment support
still depends on the harness. Entering a Mac path in message text does not upload
that file to a remote workspace.

If a connection drops while sending, review the conversation status before
retrying. The agent may have accepted the request even if the app did not receive
a response.

Next: [Notes and data](notes-and-data.md) or [Troubleshooting](troubleshooting.md).
