# Distributed client acceptance

Use Mac, iOS and Linux service builds from the same revision. Updating the phone
does not update remote workspace services. Start with iPhone, then iPad layout,
then physical devices and real network transitions.

## Build and automation

See [iOS setup](../ios/README.md) for build commands. User acceptance uses the
normal Dev app and the user's existing data; disposable tests use a distinct
`WOVENMATTER_DEV_VARIANT` with a separate cache. Never pair or unpair a user's
device as part of a build/install. Users complete provider sign-in themselves.

`scripts/test-changes.sh --all` runs source checks, native/runtime/remote fixtures,
Swift packages, builds, integration tests, and iPhone/iPad app-hosted UI tests.
Fixtures use synthetic libraries and providers. Record toolchain failures
separately; compilation does not prove UI, Tailscale or real-account acceptance.

## Mobile navigation and standalone execution

- Confirm Home, Folders, Chats, Notes, Settings; opening a folder stays inside
  Folders with Back. Trash belongs at the bottom of Folders.
- Home has New Chat/New Note, device and workspace agents, then Calendar,
  Scheduled tasks, Library, Databases and Usage. Ordinary offline states remain
  quiet. Settings details use pages with Back; New Chat uses an agent chooser.
- Exercise Green/Cognac, shared icons, notes, Markdown, collapsed tools, rotation,
  iPad sidebar and compact windows. Keyboard opens on field tap and dismisses on
  outside tap without discarding writing. There is no Done strip or Refresh menu.
- Add a device provider connection in Settings. Test sign-in cancellation,
  invalid/expired credentials, persistence and provider token refresh. Keys and
  tokens stay on the device and never appear in logs or synchronized data.
- Set Pi Durable's default connection/model/think level and Woven MCP
  tools; new chats inherit these, while per-session changes remain independent.
- Run on-device Pi Durable with other devices disconnected. Exercise files,
  notes, calendar, timers, history, usage, tools, Stop, children and explicit
  Resume. Model/account selection must survive catalog outages and refreshes.
- Verify embedded Python/SQLite and native MCP effects, completed-command replay,
  cancellation and interruption. See [embedded execution](IOS_EMBEDDED_EXECUTION.md)
  for the real WebKit smoke and [continued execution](IOS_CONTINUED_EXECUTION.md)
  for physical background admission, expiration and cancellation checks.

## Pairing and workspace control

1. On the central database, open Settings → Devices. Tailscale sharing
   starts automatically; QR/link controls remain visible when unavailable.
   Pair a phone/tablet with a fresh QR/link. Repeat lost confirmation, restart
   during setup, expired code, duplicate scan and pairing to a different database.
   Pending enrollment must not appear paired or grant data access. Local writing
   and device provider connections must survive interrupted setup and re-pairing.
2. On a second Mac, choose Database role → Node, restart and test discovery,
   approval and link fallback. Discovery alone grants no access. The previous
   database remains preserved; the Mac has its own local execution workspace.
   Refuse role changes with active work and restore access after a failed change.
3. Paired clients automatically receive all available workspace routes. Empty workspaces have no
   invented agents; central/direct routes to the same Mac appear once with its
   device name. Temporarily unavailable workspaces acquire access on reconnect.
   Linux provisioning stays on the central database.
4. For each retained harness, create/send/reopen, change model/effort/tools,
   answer approvals/questions and Stop. Verify new chats retain the correct
   workspace root, independent scratch directories and fixed owner after send.
   Archived chats from retired harnesses remain readable and cannot execute.
5. Disconnect the central Mac, keeping a Linux or secondary Mac workspace online.
   Start/control work directly. Closing the viewing phone must not stop it.
   Reconnect central and verify that workspace publishes its own history even
   with the phone closed. The phone publishes only its own workspace history.
6. Interrupt an accepted command's reply and restart either side. Recover the
   original receipt without duplicate execution. A stale Stop or approval must
   never affect a newer run. Test provider cancellation and prompt uncertainty.
7. Unpair a device centrally. Check immediate denial on reachable services and
   queued revocation after an offline service returns.
   Ordinary network loss preserves direct grants; explicit Unpair removes them.
   Restart an authorized Linux service while central is offline and verify its
   device-scoped provider grant still works without exposing administrator keys.

## Offline data and ownership

- Create notes, folders and calendar events offline; terminate/reopen, reconnect
  and verify durable convergence. Edit while an earlier mutation is in flight.
  Conflicts keep both versions; deleting an item never resurrects its identity.
- Edit separate notes on two clients while central is offline, then reconnect.
  One conflict or interrupted artifact must not block other sync streams.
- Read recent cached conversations and fetch older pages. Save an artifact,
  interrupt its transfer, reconnect and verify exact bytes. Ordinary workspace
  files and runtime checkpoints stay at their owner. Cache cleanup must preserve
  pending writing, conflicts and locally originated execution history.
- Create an offline phone calendar task, then sync it. Missed one-time phone
  tasks run when iOS next permits; recurring misses coalesce. They never move
  silently to another device. Calendar/task claims must not duplicate runs.
- Exercise managed datasets, linked tables/inline values and copies according to
  [the workspace data model](WORKSPACE_DATA_MODEL.md). A client must not interpret
  an owner-local file path as a path on its own device. Unsupported note features
  remain preserved when read or edited on a smaller client.

## Acceptance boundary

Automated tests cover persistence, receipts, scoped authorization, history replay,
conflicts, cancellation and artifact integrity. Real provider plans/sign-in,
Tailscale ACLs, second-Mac behavior, physical iPad layout and iOS background
scheduling require the corresponding devices and accounts. Keep those results
separate from build/fixture success in the PR handoff.
