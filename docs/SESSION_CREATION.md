# Session creation

Creating a chat owns its initialization. It captures the latest persisted defaults
on the execution owner, applies that snapshot once, and returns the chat. Opening
or refreshing a chat reads its current configuration; neither opening nor sending
its first message retries initial defaults.

Defaults currently live in `SessionSelectionPreferences` (persisted preferences),
with native session configuration stored in the workspace database. Creation reads
the owner's saved preferences, never an uncommitted Settings view or a frontend
copy. A save still in flight does not gate creation: the values already saved when
creation captures them are used. Later default edits apply only to later chats.

| Harness | Initialization owner | Opening an existing chat |
| --- | --- | --- |
| Pi Durable | Local or remote creation in `ApplicationModel` | Read current native metadata |
| Codex | Local or remote creation in `ApplicationModel` | Read current native metadata |
| Claude Code | Local or remote creation in `ApplicationModel` | Read current native metadata |
| Grok Build | Local or remote creation in `ApplicationModel` | Read current native metadata |
| OpenCode | `OpenCodeModel.create`, before returning its saved chat | Read catalog/snapshot and watch updates |

New chats start with each harness's Full access mode (Codex agent-full-access,
Claude Code and Grok Build bypassPermissions, OpenCode allow, Pi Durable full)
on every workspace unless the user saved the harness's auto mode as the
default. Full access and the auto mode (Codex agent, Claude Code and Grok Build
auto) are the only permission modes offered (`AgentRuntimeKind.supportedPermissions`,
`supportedPermissions` in `remote/src/config.mjs`). A saved or native mode
outside them, such as Ask for approval, moves to Full access when the session
next starts or runs.

The new-chat chooser, sidebar creation actions, requests from the iOS app, and
agent-created chats use these same creation methods. Agent-created chats use the
destination workspace's saved defaults, including permission and tools, without
capping them to the calling chat (Linux applies them in
`remote/src/workspace-mcp-orchestration.mjs`). An agent can create a chat on
any Mac or Linux workspace, named by workspace ID (`local` is not accepted).
A chat on another workspace is created there with a signed request
(`createSession`, then a rename to the agent's title, then the first message;
`remote/src/member-sessions.mjs` on Linux, `ApplicationModel+MemberSessions.swift`
on a Mac), so the destination applies its own saved defaults exactly as for
a chat the user starts there. Scheduled new sessions pass
their explicitly captured task settings through creation as well. Imported
transcripts retain their native settings and do not inherit new-chat defaults.

An unavailable model, thinking level, or initial configuration does not reject the
new chat or leave a settings retry attached to it. Creation retains the native
configuration it could accept. The composer displays that configuration and its
dropdowns can change individual fields normally. Tool selections are applied
independently of native model defaults.

Explicit composer changes and scheduled updates to existing sessions still apply
their requested configuration. They are not additional initialization paths.
Execution ownership, folder validity, authentication, and native transport checks
remain necessary to execute a chat.
