# Conversations

Choose **New chat** and select an agent. WovenMatter groups agents by their local,
remote, or linked Buzz workspace. Choose where you want the work to run, then
select a model and thinking level where the harness offers those controls.

## Models, thinking, tools, and permissions

Selections belong to the conversation and stay with it when you reopen it. Each
control also lets you save its current selection for new chats in this workspace
or for new chats with this harness. New conversations use this order:

1. A choice supplied for that conversation.
2. The workspace default for that harness.
3. The harness default.
4. The harness's own default.

Saving or resetting a default does not change existing conversations. Defaults
are independent for each control, so a workspace can override the model while
inheriting the harness's permission choice. Resetting a workspace default restores
inheritance from the harness default.

Permission choices follow the selected harness:

- Codex and Claude Code show their available native approval modes.
- Grok Build offers its native approval policies. Changing the policy reconnects
  the same conversation before the next message.
- OpenClaw offers its native session policies, including Read only, Guarded,
  Workspace, and Full access.
- Hermes offers its inherited approval policy or Full access for this session.
  A profile or process that already forces Full access cannot be restricted by
  this conversation control.
- OpenCode and Cursor offer native approval handling or automatic one-time
  approval of this conversation's tool requests while WovenMatter is connected.
  Their native deny rules remain in effect; questions and sign-in steps still
  need your response. Returning to native approvals stops automatic replies and
  preserves permissions already allowed by the harness.
- Pi has no permission selector. WovenMatter does not manage Pi permission
  extensions.

Wait for a settings change to finish before sending. If a saved choice is no
longer available, choose a supported value before continuing the conversation.

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

Attachment support depends on the harness. Add files to the workspace where the
agent is working before referring to their paths. Entering a Mac path does not
upload that file to a remote workspace.

If a connection drops while sending, review the conversation status before
retrying. The agent may have accepted the request even if the app did not receive
a response.

Next: [Notes and data](notes-and-data.md) or [Troubleshooting](troubleshooting.md).
