# Woven MCP agent tools

Woven Matter exposes its app capabilities through an authenticated HTTP MCP
endpoint. Pi Durable, Codex, Claude Code, Grok Build, and OpenCode use focused,
structured tools rather than shell commands. The former Woven Matter CLI and
separate automation stdio server are removed.

The shared catalog in
[`WovenMCPCatalog.swift`](../shared/Sources/WovenMatterCompanion/WovenMCPCatalog.swift)
defines tool names, descriptions, input schemas, and read-only annotations for
Mac, Linux, and device adapters. Clients discover it with MCP `tools/list` and
invoke tools with `tools/call`. Names use the `woven_` prefix; argument names use
camelCase, such as `noteID`, `allWorkspace`, and `requestID`.

Discovery stays stable within a credential’s scope so native clients can cache
schemas. Every call still checks current tool settings; a listed tool can be
disabled or temporarily unavailable.

The MCP adapter authenticates and resolves a caller, then invokes the same app
services as the interface. Each call checks current user-controlled tool policy.
Model arguments cannot choose a caller, change permissions, or supply a host
credential. Internal operation arrays remain a service implementation detail;
the MCP surface accepts neither arbitrary argv nor a host file path to read.

Pi Durable retains its normal file, shell, search, and code-mode tools and approval
checks. Woven app tools are registered from the same MCP catalog. External harness
adapters use their supported MCP configuration without replacing project
instructions or modifying a user's global harness configuration.

## Connections, hosts, and outside agents

A Woven-launched session receives its endpoint and opaque bearer credential from
its execution owner. Credentials are scoped to the calling conversation and are
not included in model messages, synchronized content, or saved tool arguments.
The endpoint is `/mcp`; HTTP is restricted to loopback, and inter-device access
uses the existing authenticated Tailscale HTTPS routes.

Other Macs retain their own execution identity and use their paired-library
adapters. Linux execution workspaces serve MCP themselves. They handle local
execution and managed data locally and use a separately provisioned, revocable
workspace grant for central-library tools. A publisher credential is not a tool
grant. An unavailable library returns an explicit unavailable result; the
workspace never adopts another device's execution or turns its replica into a
replacement library.

Ordinary Linux-owned sessions retain local goals and session coordination.
Independent scheduled runs keep their scheduler as execution owner and expose
content, data, automation and metadata tools; they omit goal, timer and session
lifecycle mutations that would create a competing execution owner.

Device-owned Pi Durable on iPhone and iPad uses the canonical tool definitions
with native local dispatch for its downloaded/offline content and device
workspace. Central-library and explicit remote operations use its authenticated
paired connection. The phone does not need a persistent background HTTP listener.

To connect an outside agent, open **Settings → General → Woven MCP access**,
expand **Add outside agent**, choose an existing chat and tool groups, and keep
**Read only** enabled unless writes are needed. Choose **Create access**, then
**Copy MCP configuration**. Paste that configuration into the outside agent's
MCP settings; Woven shows the raw token only through that one-time copy action.
The grant's **Revoke** button removes access. Copying a configuration does not
perform provider sign-in or account authorization.

An outside agent can connect to a Woven MCP endpoint using a separately issued
access grant. The user chooses the bound conversation, enabled groups, and access
mode. Its authority is intersected with the conversation's current policy;
revocation stops subsequent requests. Creating or steering sessions does not
permit the outside agent to raise their permissions. Treat the bearer as a secret;
use loopback on the same machine or the private HTTPS endpoint on another host.

The Mac preserves its loopback port while outside-agent grants exist. If that
port is unavailable, startup reports the error instead of moving those clients.
Without outside-agent grants, startup may choose a free port when the saved port
is still occupied after shutdown; native sessions receive the current endpoint
and newly issued session credentials.

## Open asset context

`woven_context` returns the asset ID captured when the human sent the consumed
message, or a null ID when no asset was open. Notes permission applies at capture
and query time. Automatic and agent-authored messages have empty captures.
Opening another asset or queueing a later message cannot retarget earlier work.

The native input binding travels outside model arguments. Pi Durable snapshots
it for each tool call and child conversation. External native consumption hooks
bind a context request to the correct generation; the HTTP bridge forwards that
opaque binding as transport metadata. Reconnection can update the endpoint while
retaining the originating capture. Use the returned explicit `noteID` for later
note operations.

## Tools and access

The composer has a Tools menu with independent groups:

| Group | MCP tools and contract |
| --- | --- |
| Notes and managed data | `woven_notes_*`, `woven_databases_*`: discover, read, create and edit notes, spreadsheets, HTML and workspace-owned SQLite datasets; retained note versions |
| Conversation history | `woven_history_*`: search and selectively read conversations and full observed traces |
| Session management | `woven_sessions_*`: discover metadata, create sessions, send messages and manage coordination |
| Goals | `woven_goals_*`: inspect and maintain the calling conversation's explicitly requested objective |
| Timers | `woven_timers_*`: persistent session follow-ups |
| Usage data | `woven_usage_read`: recorded analytics and cached limits; no credential access or mutation |
| Calendar | `woven_calendar_*`: events and scheduled tasks, subject to the configured access mode |
| Library | `woven_library_list`, `woven_library_read`: exchanged-item metadata, original links and retention/source references |
| Browser Use | `woven_browser_use`: control the execution owner's shared Chromium browser, including inline screenshots |
| Computer Use | `woven_computer_use`: control that Mac's desktop through bundled Cua; off by default |
| Executor | `woven_executor_*`: scoped connected-app search and execution; off by default |

Browser Use initially defaults to enabled, including existing chats. Computer Use
and Executor initially default to disabled; the other selectable groups default
to enabled. General settings defines defaults for new conversations. Session
controls change only that conversation. Calendar defaults to Full access, with
Read only configurable in General. Usage is always read-only.

## Visual replies

Use `woven_html_preview` to inspect a screenshot, content height and console output,
then `woven_html_render` to publish an interactive page directly in the thread.
All supported harnesses discover the same focused Woven MCP tools.
Pages persist with the chat, stay visible when work history folds, and support
automatic sizing, themes, zoom and expansion. The tools are always available.

Pages support inline and external CSS/JavaScript, images, media, and data fetches
in an isolated sandbox. Absolute image paths are embedded on the invoking machine
(up to 10 MiB/image and 25 MiB/prepared page); external resources follow platform
transport policy. The page has no app/session or direct local-file access. Preview needs the Woven Matter app open;
publishing does not. See [the implementation and T3 analysis](architecture/CHAT_HTML_RENDERING.md)
for the complete contract and differences from upstream.

## Browser and computer automation

`woven_browser_use` and `woven_computer_use` accept structured action fields directly.
Their MCP results contain native text and image blocks, so supported harnesses
receive screenshots inline without saving a file through a shell command.

Browser Use controls the execution owner's shared browser. On a Mac, this is
Woven Matter's embedded browser with the user's visible tabs, profile, and
existing signed-in sessions. Secondary Mac agents use their own browser. Linux
agents use their workspace's shared Chromium browser; the Mac's **View browser**
window can interact with those same pages. An iPhone agent's explicit browser and
computer calls route to its paired central Mac. Computer Use requires a reachable
authorized Mac and does not control the Linux desktop or the iPhone UI. Normal
Device execution access and conversation tool policy apply between input steps.

For example, a browser call uses these MCP arguments:

```json
{"action":"snapshot","tabId":"TAB_ID"}
```

Start with `tabs` or `open` to obtain a `tabId`, then inspect a fresh snapshot before
interacting. `click` and `hover` accept a CSS/Playwright selector or viewport `x`/`y`
coordinates. Coordinate actions omit `frame`; selectors can use an optional iframe
selector in `frame`. `evaluate` runs page JavaScript from `code`. Page content is
untrusted, including instructions embedded in snapshots.

Uploads use `upload`, `selector`, `name`, `mimeType`, and base64 `data`, with a
2 MiB file ceiling. `download` returns a native receipt; `downloads` lists receipts,
and `read-download` reads a completed opaque `id` at a byte `offset`, at most
384 KiB per response. Agent downloads remain temporary and never execute. They
are limited to 16 files of 64 MiB per tab on Mac. Linux retains at most 16 downloads
and 64 MiB across the workspace, evicting older receipts when needed. Downloads
are removed with their tab. Ordinary
user downloads retain the save dialog. Dialog handling uses `accept` on the
triggering action or a separate `dialog` action.

Computer Use remains off by default. The user must enable it in Tools and grant
Woven Matter macOS Screen Recording and Accessibility; agents cannot grant them.
`woven_computer_use` uses only the app-bundled Cua Driver. `status` checks the
macOS grants without starting a helper. No installer, cloud account, separate Cua
app, or globally configured MCP server is needed.

Start with `apps`, then `windows` with a `pid`. `snapshot` takes `pid` and
`windowID`, returning that window's accessibility tree, element tokens and inline
image. Window input defaults to `deliveryMode: background`, preserving the
user's frontmost application and real pointer where the application supports it.
Use an `elementToken` from the latest snapshot; pixel clicks instead require
`x`, `y` and `captureID` from that snapshot's `capture_id`. Coordinates belong to
the returned window image. Cua refuses stale captures and tokens. Snapshot again
after input (`since: latest` gives a compact diff; `includeScreenshot: false`
returns only the tree). An accepted input is not proof of a completed task.

```json
{"action":"snapshot","pid":123,"windowID":456}
{"action":"click","pid":123,"windowID":456,"elementToken":"s00000001:7"}
{"action":"type","pid":123,"windowID":456,"elementToken":"s00000002:8","text":"Example"}
```

`press` takes a key such as `Return` or a shortcut such as `cmd+a`; `scroll`
takes `x`, `y`, `direction` and integer `amount` from 1 to 50. `drag` takes
`x`, `y`, `toX`, `toY`; `move` moves the agent cursor over the named window.
`launch` takes an installed app bundle ID in `app`. Type requests accept at most
4096 UTF-8 bytes; split longer text and verify it. Foreground delivery must be
explicit, used only after background input did not land, and verified before a
retry. `screenshot` captures the primary desktop; desktop input additionally
requires `scope: desktop` and `deliveryMode: foreground`. Other displays remain
accessible through exact window snapshots; full-display input supports the primary
display only. Cua reports unsupported application routes explicitly.

Every conversation gets a separate private Cua MCP lifecycle session. Caller
identity and endpoints are never model arguments. Stop/revocation retires its
connection, while GUI shutdown also stops the embedded driver. The driver's
state is ephemeral; recording, history, product telemetry, and self-updates are
not exposed. It retains no independent user configuration. Existing Woven
request admission and cancellation prevent silent replay after interruptions.

The visible Mac app owns its embedded browser and desktop automation; the Linux
workspace service owns its shared Chromium browser. Cancellation uses the
matching `woven_browser_use_cancel` or `woven_computer_use_cancel` operation identity.
Cleanup remains scoped to the caller even after the tool is disabled. Interrupted
actions are never automatically replayed. Persistent activity metadata omits page
content, screenshots, and typed text; model results follow the chat's existing
history and provider behavior.

History enabled permits relevant retrieval at the agent's discretion or at the
user's instruction. Nothing preloads the complete database or entire transcripts.
Search starts in the current folder, then broadens when no match is found; All
Workspace searches globally. Results include stable IDs, locations, harnesses,
activity/status and bounded excerpts so the agent can resolve ambiguous names.

The plus-button conversation attachment sends a session reference, never a full
transcript. It grants read-only access to that specific session even if history
is disabled, and the UI explains that exception. A plain pasted ID does not
create an attachment grant. With Session management enabled, metadata/status and
messaging are available independently of history. An active coordinator may
read its managed sessions. With history disabled, managing an existing,
unattached session requires an actual user confirmation in Woven Matter before
the grant is created. The tool returns a durable pending request immediately; retries
with the same request ID inspect that request instead of opening another sheet.
Approval rechecks ownership, fanout and current capability. App shutdown cancels
unanswered approvals. Creating and managing a new session needs no extra grant.
Revocation blocks future reads; it cannot erase content already retrieved.

## Sessions and coordination

New sessions inherit the source harness, working location, and folder unless
explicitly overridden. Model and thinking accept
the existing explicit creation arguments. Remaining selections resolve from the
user's destination workspace/harness defaults, harness defaults, and native
defaults, in that order. The source chat's selections do not become defaults for
the new chat. General Agent tools settings supply the native tool fallback.

Permissions and tools come from user controls and cannot be overridden by agent
tool calls. A user-saved empty Tools default disables every tool group for new chats
in that scope. Creation binds the working location before resolving defaults and
freezes every choice with the request, so retries survive changed defaults.
Native settings must be accepted before the initial instruction is sent. Provider
native subagents are not redefined.

An agent-created work session is coordinated by its creator unless explicitly
requested as independent. Existing sessions become managed only on an explicit
manage/monitor action. One-off status checks or conditional messages do not
establish coordination. Exactly one session may coordinate a destination at a
time. A competing request fails with a structured tool error identifying the coordinator.
Coordination can end explicitly, when the coordinator declares the assignment
complete, or from a user control; creation provenance is permanent.

Messages use normal session dispatch, with durable backend-bound source identity,
retry protection, and agent-authored context. Steering is used when supported;
otherwise messages queue for the next turn. Never kill a run to deliver a message.
Agent-authored incoming messages show a clickable sender session/harness. A
creation action produces a larger outgoing card with purpose, destination,
harness/model/status and coordination intent. Later sends have compact outgoing
receipts with destination details and a link. Both directions remain inspectable.

Managed-session completion, failure and needs-input events notify the coordinator
by default, with notification controls. A notification steers an active session
or wakes an idle one. A finished turn is not automatically a completed assignment.
A delivered explicit reply replaces the completion fallback. Pending replies defer
the fallback; failed replies still need one. Deliver notifications once, preserve
attribution, and prevent notification-only reply loops. The user retains ownership of permission approvals.

The conversation hover pop-out shows Created by only for agent-created sessions
and Managed by only while coordination is active. Creation has no sidebar icon.
Minimal sidebar indicators show active coordination and active timers only.
Scheduled chats start with `Scheduled: <task title>`. Renames survive recurring
runs, and `Scheduled Task` remains below the workspace information in the hover
pop-out. All existing folder organization/moving behavior remains intact.

## Timers and concurrency

Timers return to a session with a saved instruction, supporting one-time and
recurring follow-ups. Definitions persist and execute while the Woven Matter server is running. Pausing, disabling or deleting removes active timer indicators.
Disabling the Timers group with active timers asks the user to confirm pausing
them. Ordinary in-session timers remain distinct from provider Cron Jobs and
Calendar tasks that create or reuse a configured session.

General settings provides these independent limits:

| Setting | Default | Range |
| --- | --- | --- |
| Sessions managed by one coordinator | 4 | 1–16 |
| Simultaneously running Woven Matter sessions | 16 | 1–48 |

The running-session count covers Woven Matter sessions, not provider-internal
subagents. There is no configurable per-destination coordinator count: the fixed rule is one.
At the active-session limit, a user send in another idle session is blocked with
a pop-up before dispatch. No limit message is sent to a harness. Existing work
and supported steering continue. Calendar tasks wait for capacity and an idle
destination; ordinary user sends do not enter an automatic capacity queue.

## Calendar events and scheduled tasks

`woven_calendar_create` and `woven_calendar_update` take structured `title`,
`description`, `startsAt`, `endsAt`, `allDay`/`timed`, and `timeZone` fields.
Recurrence uses `repeatUnit` (`day`, `week`, or `month`) and `repeatInterval`.
Add `prompt` to schedule an ordinary agent conversation. Task settings include
`harness`, `model`, `thinking`, `workspace`, `directory`, `folder`, and
`sessionMode` (`same` or `new`). Creating a task requires Calendar write access
and Session management. User-owned destination defaults supply permissions and
tool selections; a tool call cannot raise them.

Updates preserve unspecified fields and affect the whole series. `regularEvent`
removes execution and `noRepeat` removes recurrence. `woven_calendar_detach` with
an `occurrence` index makes that occurrence an independent event, preserving
settings and attribution. `woven_calendar_copy` makes a new one-time event.
`woven_calendar_remove` deletes the series or the specified occurrence.

Read the current event with `woven_calendar_read`; use its `revision` for
conditional edits and deletion. `woven_calendar_list` pages definitions;
`woven_calendar_occurrences` returns occurrence indices between `since` and
`until`, in a window of at most one year.

Calendar tasks survive restarts. Every overdue independent task runs; each
recurring series catches up once. The default recurring mode reuses one session.
Durable receipts prevent duplicate submissions. A lost native acknowledgement
remains uncertain and is never blindly retried. Edits and deletion cancel pending
sends before transport starts, and completed chats remain accessible afterward.

## Capture, recovery and compatibility

Preserve observed protocol data for the supported harnesses, including native
OpenCode, imports, steering, reconnects, and scheduled results. Retired harness
history remains readable without reintroducing its execution integration. Exclude authentication material. Retain provenance and honest partial
coverage for older data; never invent unobserved historical frames.

Use the existing workspace database with transactional migrations and bounded
reads. Note versions cover notes, spreadsheets and HTML, with before/after agent
edits, coalesced editor checkpoints, conflict-safe restore and count/byte budgets.
Do not version externally linked data files. Reference retention remains separate
from event journal retention and should be described honestly.

## Retry behavior

Note create/edit/restore, timer mutations and Calendar mutations commit a
caller-bound request receipt with the write. The optional `requestID` is a stable
UUID distinct from MCP's JSON-RPC request ID; results return the operation identity.
Reusing the same request ID and
payload acknowledges the original operation across restarts without repeating
it, resetting a schedule, resurrecting a removed item or overwriting later user
edits. Reusing the ID with a different payload fails. Current capabilities and
Calendar mode are still enforced on replay. Note edit/restore replay responses
contain `replayed: true` and the original revision, without an old document that
could be adopted into the editor. Use `woven_notes_read` for the current document.
Receipts retain hashes and acknowledgements, not extra note snapshots.

## Reference implementation

The transport and invocation design was compared with T3 Code at
[`3f944874`](https://github.com/pingdotgg/t3code/tree/3f9448747bb8848050dc2cacf83affa6f94a66a1/apps/server/src/mcp):
`McpHttpServer.ts` authenticates HTTP requests before dispatch;
`McpSessionRegistry.ts` binds credentials to an execution scope and supports
expiry and revocation; the orchestrator toolkit exposes typed operations with
descriptions and access annotations. Woven MCP follows those patterns using
Woven's existing ownership, permission, scheduling, and coordination services.
Its catalog covers Woven capabilities; it does not reproduce T3-specific tools.

## Validation boundaries

For provider-free acceptance through a running signed snapshot Dev app, prepare
the disposable target with `scripts/test-cua-desktop.sh --target-only`, then run
`python3 scripts/test-cua-snapshot.py --app "/path/to/snapshot Dev.app"`.
The check creates a temporary chat and a Computer Use-only MCP connection,
confirms default-off denial, and then checks capture, accessibility click,
background typing, hotkeys, stale-token rejection, and revocation against the
target's independent state. It disables the chat's Computer Use, revokes the
credential, and trashes its disposable chat on exit without changing global
defaults. Missing user-controlled Accessibility or Screen Recording returns 77;
only a completed successful live run returns zero. The report contains outcomes,
never the MCP credential or captured images. The separate signed-host fixture
`scripts/test-cua-desktop.sh` checks caller isolation and foreground preservation.

`scripts/test-changes.sh --all` exercises provider-free transport fixtures,
access policies, migrations, mutation retries, timer recovery, note retention,
authenticated HTTP MCP, native input bindings, and remote relay behavior. It also builds and validates
an unsigned native app. The interactive hover fixture runs separately through
`scripts/test-conversation-popover.sh`.

Fixtures do not establish live provider compatibility or rendered UI behavior.
Before release, check the session settings and local/remote workflows you use,
including attachments, timer delivery, permission requests, and note recovery.
Older imported history remains partial. Library collects newly exchanged items
after activation; it does not backfill existing conversations or imported history.

With Library enabled, `woven_library_list` accepts `workspace`, `harness`,
`sender` (`me` or `agent`), `kind` (`file`, `link`, or `photo`), `since`, `until`,
`search`, `limit`, and `offset`. Workspace and harness filters accept
comma-separated values. `woven_library_read` takes an item `id` and returns its
metadata and original source. It does not grant conversation-history access or
implicitly return file bytes.
