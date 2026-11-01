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

The new-chat chooser, sidebar creation actions, companion requests, and
agent-created chats use these same creation methods. Scheduled new sessions pass
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
