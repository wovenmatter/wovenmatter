# OpenCode v2 local integration

WovenMatter connects conversations to the standard local OpenCode v2 service.
This reference covers its connection, session, and persistence behavior. For
setup in the app, see [Agent setup](../guide/agents.md).

Existing v1 transcripts remain readable in SQLite; new work uses v2 sessions.
Other harness integrations keep their own transports.

## User experience

- **Settings → Local agent workspace** lists OpenCode under **Runtimes** with
  **Settings**, update controls, **Hide/Show**, and **Install** or **Enable/Disable**.
  Its **Settings** button opens the local server and model controls. The top-level
  **Settings → OpenCode** page lists local and remote OpenCode workspaces.
- Connect reuses OpenCode's standard authenticated local service, or starts it when absent. New Chat can also connect/start it. After a successful connection, reopening Woven Matter reconnects according to the saved lifecycle preferences.
- New OpenCode chats use the same Woven Matter workspace root as the other local harnesses. OpenCode owns the backend session; its v2 clients can access that same session through the same service.
- The OpenCode page contains connection status, **Open in browser**, **Manage models**, Connect, server controls, and lifecycle preferences. Model visibility is saved by Woven Matter; OpenCode browser show/hide preferences remain separate. Selected models sort first in Manage models.
- The existing shared composer supplies model and thinking-level controls, in both compact and expanded layouts. Thinking options come from the selected model's native variants; changing models resets the old variant. Normal sends use the backend's delivery default.
- Chat history, streaming text/tool activity, attachments, permission requests, questions, and interrupt remain part of the conversation flow. Older backend history loads through the existing scroll behavior. Uncertain sends are reconciled by identity and are never silently resent.
- There is no additional agent selector, Queue/Steer selector, Session panel, or Browse button. There are no terminal, file-management, provider-credential, MCP, plugin, or remote-server configuration panels.

## Local service contract

The tested runtime is `@opencode/cli@0.0.0-beta-19278` (`opencode2`). Native API reference: [OpenCode source at be41bc4](https://github.com/anomalyco/opencode/tree/be41bc4e7de76637f4c7a94d6110637270bfff37). This source reference is not asserted to be npm's exact build commit.

Discovery uses `$XDG_STATE_HOME/opencode/service.json`, defaulting to `~/.local/state/opencode/service.json`, just as OpenCode does. The service registration supplies the dynamic loopback URL, PID, and Basic password. Health verifies the PID and exact supported version. Woven Matter does not choose a private data directory, fixed port, separate service password, or alternate workspace.

Startup runs the installed `opencode2 serve --service` with the normal environment. It accepts the official version banner and lets the service handle a registration whose process has exited. A live incompatible or unhealthy service is never killed or replaced. Disabling the runtime leaves the shared backend running. Quitting also leaves it running by default; the optional stop-on-quit preference changes that behavior. This does not install a login daemon; Woven Matter starts the service again when needed.

Earlier custom/remote connections are no longer opened by this local flow. Their cached transcripts remain in SQLite; session identifiers are not transplanted into the standard service.

Remote workspaces now use a separate v2 service through the authenticated workspace
proxy; see [Runtime maintenance](../RUNTIME_MAINTENANCE.md). The local service
contract above does not describe that remote lifecycle.

## Persistence and recovery

Recovery combines an exclusive durable session-log cursor with canonical HTTP snapshots. Cursor and transcript projection commit atomically in SQLite. Canonical message order wins over timestamps. Pagination follows native cursors without adding `order` to cursor requests. Catch-up preserves older loaded history and refreshes it after reconnect. The general event stream is not treated as a replay source. Refresh and older-page loads are serialized, and disconnected connection generations cannot commit stale snapshots. Interrupted session creation recovers or retries the same idempotent session ID. Conditional forms follow native multi-select and cascading visibility semantics. Suggested string choices remain available alongside custom answers; external steps require explicit acknowledgement. A complete history response replaces the cached projection, including any removed prefix, while saved transcript rows remain in SQLite.

## Validation boundary

Automated tests cover local service reuse without a CLI, refusing to replace a live incompatible service, version-banner parsing, provider/model identity and reasoning variants, lost prompt responses, pending interactions, fragmented events, 251-message and 1,700-message history recovery, database reopen, and transcript preservation. Automated tests must not consume provider services.

Human acceptance should exercise the same session through Woven Matter and a v2-capable OpenCode client, including provider-backed streaming, permissions, attachments, and reconnection. Green fixture tests are not a claim that those provider scenarios were performed.

## Installation and server lifecycle

- **Install** in the local workspace runtime row installs and verifies the exact
  supported v2 package, then offers **Enable**. The server settings page can also
  offer **Download** when the local CLI is missing. Installing does not enable
  or connect the runtime.
- Stop server disconnects Woven Matter and terminates the authenticated local service. Automatic reconnect stays suspended until an explicit Connect/Restart/Enable action.
- Restart server stops the registered service before starting and reconnecting.
- Start on launch defaults on for an enabled integration. When off, startup may attach to an existing service but never launches one.
- Stop on quit defaults off. When enabled, normal application termination waits for the shared server to stop. A stop failure offers Cancel quit or Quit anyway. Force Quit cannot run application shutdown handlers.
- Disable remains separate: it disconnects Woven Matter without stopping the server.

## Local session imports

Settings lists eligible external sessions in pages of 25, up to ten pages, loading
each page on demand. Native Woven Matter origin metadata and known connection/session
associations exclude sessions already represented locally. Import reads all message
pages and preserves the upstream session location without creating or patching the
server session. The complete snapshot, association and import provenance commit
atomically; import activity keeps the conversation at the top of Recents. The hover
card shows `OpenCode (imported)`. Existing local snapshot rendering and native history
paging continue to apply. The import library is local-only.
