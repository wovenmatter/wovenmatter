# OpenCode v2 local integration

Woven Matter is a conversation frontend for the local OpenCode v2 service. It is not an OpenCode administration interface. The integration replaces only OpenCode ACP; other harness transports retain their behavior. Existing v1 transcripts remain readable in SQLite and require new v2 sessions for new work.

## User experience

- Local Agent Workspace has one OpenCode connection status and a **Connect** button.
- Connect reuses OpenCode's standard authenticated local service, or starts it when absent. New Chat can also connect/start it. After a successful connection, reopening Woven Matter reconnects automatically.
- New OpenCode chats use the same Woven Matter workspace root as the other local harnesses. OpenCode owns the backend session; its v2 clients can access that same session through the same service.
- The existing shared composer supplies model and thinking-level controls, in both compact and expanded layouts. Thinking options come from the selected model's native variants; changing models resets the old variant. Normal sends use the backend's delivery default.
- Chat history, streaming text/tool activity, attachments, permission requests, questions, and interrupt remain part of the conversation flow. Older backend history loads through the existing scroll behavior. Uncertain sends are reconciled by identity and are never silently resent.
- There is no additional agent selector, Queue/Steer selector, Session panel, or Browse button. There are no terminal, file-management, provider-credential, MCP, plugin, or remote-server configuration panels.

## Local service contract

The tested runtime is `@opencode/cli@0.0.0-beta-19278` (`opencode2`). Native API reference: [OpenCode source at be41bc4](https://github.com/anomalyco/opencode/tree/be41bc4e7de76637f4c7a94d6110637270bfff37). This source reference is not asserted to be npm's exact build commit.

Discovery uses `$XDG_STATE_HOME/opencode/service.json`, defaulting to `~/.local/state/opencode/service.json`, just as OpenCode does. The service registration supplies the dynamic loopback URL, PID, and Basic password. Health verifies the PID and exact supported version. Woven Matter does not choose a private data directory, fixed port, separate service password, or alternate workspace.

Startup runs the installed `opencode2 serve --service` with the normal environment. It accepts the official version banner and lets the service handle a registration whose process has exited. A live incompatible or unhealthy service is never killed or replaced. Disconnecting network tasks and quitting Woven Matter leave the shared backend running. This does not install a login daemon; Woven Matter starts the service again when needed.

Earlier experimental custom/remote connections are no longer opened by this local flow. Their cached transcripts remain in SQLite; session identifiers are not transplanted into the standard service. Remote OpenCode integration is out of scope.

## Persistence and recovery

Recovery combines an exclusive durable session-log cursor with canonical HTTP snapshots. Cursor and transcript projection commit atomically in SQLite. Canonical message order wins over timestamps. Pagination follows native cursors without adding `order` to cursor requests. Catch-up preserves older loaded history and refreshes it after reconnect. The general event stream is not treated as a replay source.

## Validation boundary

Automated tests cover local service reuse without a CLI, refusing to replace a live incompatible service, version-banner parsing, provider/model identity and reasoning variants, lost prompt responses, pending interactions, fragmented events, 251-message and 1,700-message history recovery, database reopen, and transcript preservation. Automated tests must not consume provider services.

Human acceptance should exercise the same session through Woven Matter and a v2-capable OpenCode client, including provider-backed streaming, permissions, attachments, and reconnection. Green fixture tests are not a claim that those provider scenarios were performed.

Verified locally for this revision: the full validation suite passed (113 Swift tests, 11 remote-service tests, static checks, native app validation). Native UI checks confirmed standard-service startup from Connect, New Chat in the Woven Matter workspace, model and High reasoning selection persisted by the service, and reconnection after app restarts without changing the service PID. No provider prompt was executed in these checks.

## Installation and server lifecycle

- Download installs the exact supported OpenCode v2 npm package through Woven Matter's managed Node installer, verifies its version, and reveals Enable. Installation does not enable or connect the runtime.
- Stop server disconnects Woven Matter and terminates the authenticated local service. Automatic reconnect stays suspended until an explicit Connect/Restart/Enable action.
- Restart server stops the registered service before starting and reconnecting.
- Start on launch defaults on for an enabled integration. When off, startup may attach to an existing service but never launches one.
- Stop on quit defaults off. When enabled, normal application termination waits for the shared server to stop. A stop failure offers Cancel quit or Quit anyway. Force Quit cannot run application shutdown handlers.
- Disable remains separate: it disconnects Woven Matter without stopping the server.
