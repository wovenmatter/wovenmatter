# Native Hermes Gateway

Technical reference for the Hermes integration. For setup and everyday use,
see [Agent setup](../guide/agents.md) and [Scheduled work](../guide/schedules-and-usage.md).

## Verified upstream contract

Verified against installed Hermes v0.21.2 at revision
`d4063e6260ce1f015181a2712165503efee188f9` on September 14, 2026, including
its strict request schemas and live backend. Woven Matter is a client of the
native Desktop/TUI JSON-RPC API. `hermes gateway` manages messaging platforms;
that separate service is not required for this integration.

Native implementation and contracts at the verified revision:

- [WebSocket transport](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/ws.py)
- [Strict session request schemas](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/contracts/sessions.py)
- [Session RPC](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/methods_session.py)
- [Prompt and interaction RPC](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/methods_prompt.py)
- [Configuration](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/methods_config_set.py)
- [Current server-to-client request transport](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/server_requests.py)
- [Current request and response shapes](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/contracts/server_requests.py)
- [Crash continuation behavior](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/tui_gateway/session_auto_continue.py)
- [Native session export](https://github.com/NousResearch/hermes-agent/blob/d4063e6260ce1f015181a2712165503efee188f9/hermes_cli/web_routers/sessions.py)

Woven Matter launches the installed `hermes serve --isolated --host 127.0.0.1
--port 0`. Hermes publishes the selected port through its supported
`HERMES_DESKTOP_READY_FILE`. A random `HERMES_DASHBOARD_SESSION_TOKEN` authenticates
`/api/ws`; HTTP export uses the same token in an Authorization header. Local clients connect directly. Remote clients use the authenticated workspace
service proxy; the native backend token remains on the agent host.
The private connection registration is scoped to the Hermes profile home.

Independent review on September 15 checked installed revision
`78d338b9ee917b73468c38ba4633ed53de4942e6`: the session, replay,
attachment and server-request contracts used here remain compatible. This was
source inspection, not a repeat of the live acceptance described below.
Saved conversation identities are checked against the resolved profile and
remote workspace before any resume request.

## Behavior

- Native `session.create` and `session.resume` return live IDs distinct from the
  durable conversation key. Woven Matter stores the durable key with its profile
  home. Existing ACP IDs address Hermes's same `state.db` and remain resumable.
  Empty drafts have no durable native row and may be reaped after disconnect.
  Configuration and local slash commands therefore do not persist a new ID.
  The client publishes the identity before `prompt.submit`, so a failed database
  write prevents submission and a lost acknowledgement cannot orphan accepted work.
  Create, resume and image requests use their distinct native parameter schemas.
- `session.cwd.set` applies the existing local workspace root only to Woven
  Matter-created sessions, including legacy local ACP sessions. Its Repos and
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
matches inputs by text or automatically resends them. A configuration-only draft can be recreated. Once submission has been attempted,
a failed resume is reported instead of silently replacing the conversation.

Secure input supports the native secret/sudo requests; Hermes-specific vault,
terminal-preview, browser-control, voice, and Desktop tour request surfaces are
not implemented here. Remote/container Hermes uses the same native transport
through the workspace service. New imports map native tool calls and results into transcript activities while
retaining their raw payloads. Previously imported rows are not silently rebuilt;
see the [transcript repair audit](../PR48_TRANSCRIPT_REPAIR_AUDIT.md) for that change.

Validation is provider-free: a loopback WebSocket peer covers request-frame routing
and reconnect epoch checks; transport fixtures cover approvals, clarification,
secrets, cancellation, event replay, open requests, and lost acknowledgements.
Database tests cover atomic import, profile identities, and streaming replacement.
Live acceptance also used the installed backend with the existing Hermes profile:
startup/reuse, authenticated ping and profile/epoch validation, provider readiness,
session listing and durable export, create/resume, and guarded idle shutdown.
The isolated native app verified Ready, real history import, new-chat controls,
and native `/help` execution after the 20-second orphan-draft grace period.
Image attach/detach and file staging also passed against the live backend,
including filenames containing spaces.
No provider prompts were submitted; actual model execution remains a separate
acceptance check. The user's Hermes Desktop process was left running.

## Historical integration with PR38

PR38 and PR45 have merged. Both session-import paths and both scheduled-result
refreshers are present on main. Their original merge-order instructions are no
longer an action for contributors. Preserve profile/workspace-scoped import
provenance and the shared `desktop_session_imports` records when changing either
integration.

## Scheduled results and remote containers

The Cron Jobs page groups Hermes and OpenClaw. Hermes supports creating paused
jobs, pausing/resuming, viewing retained textual outputs, and routing results to
a new conversation per run or an existing conversation belonging to that agent.
**Continue in chat** opens an unsent draft; the user explicitly sends it.

The bundled native `wovenmatter-delivery` platform writes each output to the
profile's `.woven-matter/scheduled-results.sqlite` before acknowledging delivery.
Its identity comes from Hermes's execution ledger, not timestamps or content.
The desktop commits the message, unread state, and receipt together, so reconnect
or restart cannot duplicate a collected execution. Receipts survive conversation
deletion. Routes and receipts include the profile and remote workspace identity.
Host outputs are currently retained without pruning. Attachments are rejected
with a visible delivery error; this destination currently supports text only.

Enabling a delivery destination installs and enables the plugin in that profile.
An idle Woven Matter-owned backend may restart once to load it. A separate
`hermes gateway` that already owns scheduling needs an explicit restart by its
operator after initial plugin enablement; Woven Matter never restarts that service.
Restart decisions inspect the running backend's `plugins.list`, so an earlier
enable whose idle restart was blocked can be retried after active work finishes.
The native desktop scheduler runs with `HERMES_DESKTOP=1` and respects Hermes's
gateway ownership check. Active turns and scheduled executions block explicit stop.

In remote workspace containers, the service persists the enabled preference and
authenticated native process registration. It restores the backend after container
restart and reuses a healthy registered process after service reconnect. Closing
Woven Matter or its tunnel does not stop the remote scheduler. Explicit Stop
Gateway disables automatic restart. The container must have compatible Hermes
installed, a configured provider, and a persistent home volume; execution while
the container or host is stopped requires that infrastructure to resume.

Provider-free code checks cover durable delivery, retries, conversation routing,
remote ownership, and persisted restart preferences. A native no-agent scheduler
probe also delivered a script result through the plugin. Live model execution
and Linux container acceptance remain user validation.
