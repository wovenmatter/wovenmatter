# Native Hermes Gateway

## Verified upstream contract

Inspected installed Hermes `422bc9bde9d212ab3741fbc45a871a3938436d59` and upstream
`3f86ed75dad1933036c52018e991dbd839837126` on September 13, 2026. The original session and
prompt handlers matched at those commits. The production-readiness review also
inspected installed revision `d4063e6260ce1f015181a2712165503efee188f9` on September
14. Its interactive request contract has changed to peer JSON-RPC requests. The protocol is Hermes's Desktop/TUI
JSON-RPC backend, not OpenClaw's Gateway protocol.

Primary sources at the inspected upstream revision:

- [WebSocket transport](https://github.com/NousResearch/hermes-agent/blob/3f86ed75dad1933036c52018e991dbd839837126/tui_gateway/ws.py)
- [Session RPC](https://github.com/NousResearch/hermes-agent/blob/3f86ed75dad1933036c52018e991dbd839837126/tui_gateway/methods_session.py)
- [Prompt and interaction RPC](https://github.com/NousResearch/hermes-agent/blob/3f86ed75dad1933036c52018e991dbd839837126/tui_gateway/methods_prompt.py)
- [Configuration](https://github.com/NousResearch/hermes-agent/blob/3f86ed75dad1933036c52018e991dbd839837126/tui_gateway/methods_config_set.py)
- [Current server-to-client request transport](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/server_requests.py)
- [Current request and response shapes](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/contracts/server_requests.py)
- [Crash continuation behavior](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/session_auto_continue.py)
- [Native session export](https://github.com/NousResearch/hermes-agent/blob/3f86ed75dad1933036c52018e991dbd839837126/hermes_cli/web_routers/sessions.py)

Woven Matter launches the installed `hermes serve --isolated --host 127.0.0.1
--port 0`. Hermes publishes the selected port through its supported
`HERMES_DESKTOP_READY_FILE`. A random `HERMES_DASHBOARD_SESSION_TOKEN` authenticates
`/api/ws`; HTTP export uses the same token in an Authorization header. No custom
server, proxy, OpenClaw credential, or Hermes configuration rewrite is involved.
The private connection registration is scoped to the Hermes profile home.

## Behavior

- Native `session.create` and `session.resume` return live IDs distinct from the
  durable conversation key. Woven Matter stores the durable key with its profile
  home. Existing ACP IDs address Hermes's same `state.db` and remain resumable.
- `session.cwd.set` applies the existing local workspace root only to Woven
  Matter-created sessions, including legacy local ACP sessions. Its REPOS and
  Databases links retain their configured external targets. Imported sessions
  retain the cwd recorded by Hermes. Global `terminal.cwd` is never changed.
- Agent-definition context retains Woven Matter's existing ACP v1 compatibility:
  the optional `systemPrompt` supplied by the existing session coordinator is
  prepended once to the first user turn. This is agent-definition context, not
  repeated directory instructions. Hermes's `config.set prompt` writes the
  profile-wide custom prompt, so it is not used for per-conversation context.
- Text, final authoritative text, reasoning, tool activity, and usage use native
  events. Stop sends `session.interrupt`; steering sends `session.steer`.
  Neither action kills the shared server. Disabling an idle Hermes runtime stops
  only Woven Matter's authenticated service; active turns must finish first.
- Model selection uses native provider-qualified values. Thinking uses the
  native effort values and model capability flags. Neither changes profile
  defaults. Native confirmation-required model switches are surfaced as errors
  with the backend's explanation, rather than bypassing confirmation.
- Native approval choices remain intact. Clarification uses the existing question
  card. Secret/sudo responses use a transient SecureField and are never written
  to messages, activity, preferences, or application logs. Current Gateway requests
  receive JSON-RPC response frames with the same request ID; `request.cancel`
  dismisses the interaction, and replay restores `open_requests`. Unsupported
  requests are declined. The older request-event protocol remains supported.
- Same-process reconnect holds live events while replaying `session.events.since`,
  orders/deduplicates by sequence, and checks the replay epoch. A changed epoch or
  truncated ring fails the interrupted turn visibly without resubmitting input.
  Epoch validation precedes recovery resume. Explicit resume uses `defer_history`
  to avoid the native cold-resume path that automatically continues crashed turns.
  Lost submit acknowledgements require a fresh running-state check before another
  explicit send, so a still-running turn cannot silently receive a duplicate.
  Failed replay disconnects and suspends heartbeat recovery, forcing the next
  explicit prompt through full guarded initialization. Durable history stays in
  Hermes. Non-lazy resume may follow a compression tip: a changed durable ID must
  match the backend's explicit `resumed` acknowledgement, while Woven Matter
  retains its original durable association. Imported resume sends no cwd.
- Settings lists at most 100 native sessions. Native `session.list` has a limit
  but no cursor; this is not an exhaustive inventory. Import uses the native
  export endpoint (32 MB bound), including durable message IDs and tool results.
  One database transaction creates the association and transcript; duplicate IDs
  roll it back. Existing associations are reused across repeated imports.

## Limits and validation boundary

There is no client-supplied durable input receipt in the inspected `prompt.submit`
handler. Cross-process restart or a replay gap therefore cannot safely establish
which unacknowledged input was accepted. The client reports uncertainty and never
matches inputs by text or automatically resends them. A draft that never reached
Hermes's first prompt may have no durable database row after a server restart;
its failed resume is reported instead of silently replacing it with a new session.

Secure input supports the native secret/sudo requests; Hermes-specific vault,
terminal-preview, browser-control, voice, and Desktop tour request surfaces are
not implemented here. Remote/container Hermes remains on its existing transport;
this change is the direct local integration. Imported tool output is retained as
transcript content rather than reconstructed as Woven Matter live-run activity.

Validation is provider-free: a loopback WebSocket peer covers request-frame routing
and reconnect epoch checks; transport fixtures cover approvals, clarification,
secrets, cancellation, event replay, open requests, and lost acknowledgements.
Database tests cover atomic import, profile identities, and streaming replacement.
Actual provider turns and live service adoption require separate acceptance.

## Integration with PR38

The branch is based on main and does not contain PR38. Preserve both optional
payloads when combining `WorkspaceDatabase.createLocalACPSession`:
`importedOpenCodeSnapshot` from PR38 and `hermesImport` here. Both branches contain
the same `desktop_session_imports` schema, `markSessionImportedUnlocked` helper,
and `WorkspaceConversationRecord.importedAt` / shared hover definition. Hermes
imports already call the marker inside their transaction and preserve import
recency through later transcript updates. Keep one copy of those common hunks;
PR38 additionally supplies its legacy OpenClaw provenance fallback.

Other overlaps are ApplicationModel runtime/settings methods,
LocalACPRuntime, LocalACPSessionCoordinator, SettingsView,
SettingsLocalWorkspaceView, DashboardConversation, and the Xcode source list.
Keep PR38's OpenClaw per-session cwd and OpenCode import behavior intact.
