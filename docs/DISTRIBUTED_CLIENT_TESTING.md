# Distributed client testing

Use the Mac, mobile and Linux workspace service builds from the same PR revision.
Existing Linux services need this revision before they can publish their own
history; rebuilding the phone does not update a remote service. Start with the iPhone
simulator, then iPad layout, then physical devices and network transitions.
Keep UI fixtures separate from the devices used for real pairing.

## Isolated builds

```sh
scripts/build-companion-desktop.sh build
scripts/build-ios.sh
scripts/build-ios.sh --device-compile
```

For the standard development launcher with an isolated database, use:

```sh
WOVENMATTER_DEV_VARIANT=Companion WOVENMATTER_DEV_CACHE_DIR=/private/tmp/wm-pr37-desktop scripts/build_and_run.sh
```

That variant is **Woven Matter Companion Dev.app**, with its own development
library. Do not use the plain Dev variant for isolated library testing because
its default workspace path is shared with the regular desktop app.

The desktop helper builds a distinct signed **Woven Matter Companion Test.app**.
Its `run` mode opens a separate test workspace and leaves production data alone.
An already installed CMake can be selected with `WOVENMATTER_CMAKE`. Existing
Apple signing assets are required; these commands do not sign in to accounts.

For visual iteration, launch the iOS development app with
`WOVENMATTER_UI_FIXTURE=1` and a stable `WOVENMATTER_UI_FIXTURE_NAMESPACE`. Fixture
writing persists across rebuilds, but pairing and agent execution are disabled.
Use another simulator without these variables for connected acceptance.

## Phone UI, then iPad

- Home, Folders, Chats, Notes, Settings appear in that order on the phone.
  Open a folder, inspect its contents, then return to the folder list.
- Create and edit a note, dismiss its keyboard, change tabs, and reopen it.
  Check rich text, existing tables, linked documents, conflict recovery, and
  export. Unsupported document structures must retain their original data.
- Use New Chat on Home and Folders: each opens the agent/workspace popup; cancelling
  retains the current chat and draft. Selecting an agent binds the new session to
  that workspace. The header pencil starts another chat with the same agent.
- Tap the message field to open the keyboard, then tap outside to dismiss it.
  Confirm there is no Done strip, Refresh action, workspace selector, agent
  selector, or Add Connection button in the composer.
- Check chat scrolling, drafts, note references, model/thinking/tool popovers,
  pending approvals/questions, and Stop. Available choices must belong to the
  selected workspace; device changes must not alter another chat or agent defaults.
  Long-press the chat title for details/export and advanced session settings.
- Home lists on-device Pi Durable and agents from reachable workspaces, followed
  by Calendar, Scheduled tasks, Library, Databases, and Usage. Open these pages
  and Settings details; each uses full-page navigation with Back. Home has no
  setup or connection-status cards.
- Check **Settings → Pi Durable** defaults for connection, model, instructions,
  and native tools. New chats use these settings; existing chats stay pinned.
- Open Library, saved artifacts, Calendar, and Trash. Exercise rename, move,
  pin, trash, and restore on test content.
- Repeat on iPad in portrait, landscape, and a compact window. Confirm sidebar
  selection and editing survive layout changes. Both apps use the green cube.

## Standalone phone connections first

Use the regular development app without fixture launch variables. No Mac pairing
or Tailscale device is required for a direct cloud connection.

1. Open **Settings → iPhone Connections** (or **iPad Connections**) and choose a provider.
2. Select ChatGPT or Grok, tap sign in, and complete the displayed device-code
   flow yourself. For Claude, complete browser sign-in and paste the provider’s
   returned code into the app. Cancelling or changing providers must discard the
   previous sign-in attempt; no credentials should appear in app logs or history.
3. For API access, select the provider (including the appropriate OpenCode Zen or
   Go option), paste its key, and save. Choose the connection and model in
   **Settings → Pi Durable**. Reopen both pages and relaunch the app to confirm
   the selection persists without exposing the key.
4. Select **This iPhone** or **This iPad**, send a small prompt, and exercise a
   local file tool. Keep all other Woven Matter devices disconnected. Repeat after
   relaunch; token refresh must happen on this device without a host dependency.
5. Check provider denial, cancellation, expired sign-in, and invalid API keys.
   Provider errors must be visible without substituting another account or route.

Automated tests use fake token endpoints and in-memory credentials. They do not
sign into accounts or consume provider services. Actual sign-in, plan eligibility,
and inference acceptance remain a human test for each provider.

## Central library and direct execution

1. In the isolated central Mac app, open **Settings → Device Connections**, start sharing,
   and create a pairing QR code/link. Pair iPhone/iPad through **Settings → Pair
   to Mac**. On a second Mac, test discovery and approval in both directions,
   then the link fallback. All devices must be on the same Tailscale network.
   Mere discovery must never authorize library reads. Verify device type and
   each device’s own last contact; activity on one device must not update another.
2. Synchronize a note in both directions. Disconnect, edit on both sides, reopen
   the client, and reconnect. Resolve the visible conflict; no writing should
   disappear. Delete a central note that has unsynced client writing and verify
   recovery preserves that writing.
3. Authorize a Linux or secondary Mac workspace while the central Mac is online.
   Start and control a test conversation directly. Stop central sharing and
   continue controlling that workspace. Reconnect and compare the resulting
   transcript and activity from a second client. Close all viewing clients
   before reconnecting the Linux workspace to central: its own publisher must
   consolidate the complete run without a phone acting as a relay. Repeat after
   restarting the workspace service and after losing an upload acknowledgement.
   A client attempting to publish another workspace’s journal must be rejected.
4. Interrupt the response to a send, then reopen. Recover its existing receipt;
   do not create a second send to guess whether the first was accepted. Test
   Stop and approvals after switching the selected conversation. Delay owner
   publication while keeping direct control reachable: the central Mac must
   still recognize the live run, reject a second idle-only send, steer that run,
   and stop it. Its observer cache must not advance the central history cursor.
5. Open an idle pre-existing remote conversation on the central Mac. Its native
   session is adopted by the direct workspace service. Existing active native
   work must finish before ownership transfers; a failed transfer stays fenced
   and retries the same adoption instead of starting another owner.
6. Save a workspace output to the shared library. Interrupt and resume its
   transfer, open it on another client, and compare contents. Repositories,
   ordinary workspace files, and runtime checkpoints remain on their owner.
7. Revoke a test device, including while a workspace is unreachable. Central
   access ends immediately; remote revocation remains visibly pending until
   acknowledged. Re-pair that same device and verify the old bearer remains
   rejected while the replacement works.

## Pi Durable on iPhone and iPad

Configure a direct provider sign-in or API-key connection on the device. An
authorized inference host remains an explicitly selected alternative. Select **This iPhone** or
**This iPad** for execution. A subscription adapter performs inference only;
the agent loop, native tools, code execution, and checkpoints remain on iOS.

- Import a small text file; ask the agent to read it and create a local output.
  Exercise native note tools and save an output to the shared library.
- Select an image-capable model, import a disposable test image, and ask the
  on-device agent to describe it. The image-reading tool result goes only to
  that run’s selected cloud or Tailscale inference connection.
- Check permission prompts, a subagent, and code mode using only disposable test
  content. Stop while a tool is waiting for approval; cancelled work must not
  perform a later mutation.
- Background and reopen the app. Resume retained work explicitly. Repeat after
  terminating the app while a response is arriving. A stopped run must stay
  stopped after relaunch, including a Stop interrupted before acknowledgement.
- Stop central sharing while the chosen inference endpoint remains reachable.
  Continue locally, then reconnect and inspect the complete history elsewhere.
- Test the selected real provider account separately. Automated fixtures do not
  establish provider billing, subscription eligibility, or tailnet reachability.

The Debug-only `WOVENMATTER_DEVICE_RUNTIME_SMOKE=1` launch mode exercises the
actual bundled SDK, a controlled native inference stream, local file read/write,
checkpoint reopening, duplicate submission recovery, and isolated WebKit code
execution with persisted code state. It writes `Documents/runtime-smoke.json`
and uses neither network nor Keychain. Relaunch without that variable afterward.

## Expanded on-device tools and calendar

Use disposable test content and an already configured phone inference connection.
The first checks work without pairing; keep the central Mac unavailable.

1. Ask Pi Durable to list local notes and sessions through the Woven Matter CLI,
   create a calendar event, and read it back. Open Calendar directly, edit the
   same event, relaunch, and verify the agent reads the saved edit. Check note
   revision conflicts rather than allowing an older agent edit to overwrite UI
   writing.
2. Create a one-time phone task, leave the app unavailable past its due time,
   then reopen. It should run once on this phone. Repeat with a recurring task
   across several missed occurrences: one catch-up run, not a burst. Editing or
   removing an unstarted task must invalidate its older claimed prompt.
3. Use `execute_command` to run `python -c` with a calculation, write a CSV,
   create a SQLite database, and read that database in a second command. Use
   `await wovenmatter([...])` from Python to inspect the same local calendar.
   Check the output paths when the inline preview is abbreviated. Stop an
   infinite program and verify the UI remains usable; its uncommitted file
   changes must not replace workspace files.
4. In code mode, await a native tool, save state with `store`, and use
   `await checkpoint()`. Interrupt, reopen, and inspect the saved state. Unsafe
   tool effects and accepted Python commands must never automatically replay.
5. Check child agents and Executor jobs. A managed session's completion should
   reach its managing session once, including after restart. Disabled tools
   must remain disabled inside code, Python CLI calls, scheduled tasks, and
   child sessions.
6. With both apps updated, reconnect. The phone-created event and task history
   should appear on the central Mac. Make conflicting offline edits and resolve
   them in Calendar. A task assigned to the phone must not run on the Mac.
7. Ask the phone agent to inspect central data using explicit `target=central`.
   Its first call should synchronize the bound phone conversation before the
   Mac authorizes it. Revoking the device or disabling the central tool group
   must reject the request without falling back to a different target.
8. Open an older chat such as a pre-upgrade tool conversation. Check headings,
   lists, tables, code blocks, links, selection/copy, chronological commentary,
   collapsed tool arguments/results and nested child work. Expanding a large
   result offline should load its retained full detail, without duplicate
   legacy tool messages.

The embedded runtime has a separate offline simulator smoke harness:
`scripts/test-ios-embedded-runtime.sh <booted-test-simulator-uuid>`.
It uses a distinct test app and fake CLI, with no provider or user-library access.
Background continuation still needs physical-device checks: admission, lock,
expiration, Stop and explicit Resume. It cannot promise execution at an exact
scheduled time while iOS has suspended the app.

## Secondary Mac

Pair from **Settings → Devices → Use another Mac’s central library**, then choose
**Use as client and restart**. Check offline notes and drafts, the same library
views, and direct execution. Optionally enable **Execution on this Mac** in client
Settings and configure its agents and connections. Sharing this execution
workspace is a separate explicit action.

With the central Mac unavailable, create and edit calendar events from both the
client Calendar page and this Mac's local agent CLI. Each should see the other's
saved edits. Reconnect and verify synchronization, including an explicit conflict
when both sides changed the same event. A task assigned to another device must
not execute here; an unresolved calendar conflict must not execute either prompt.

Ask the local agent to discover cached conversations and history from another
device, read a retained artifact, and inspect cached usage. These reads must not
import foreign sessions as locally controllable agents. Lifecycle commands,
timers and Executor jobs remain owned by their execution workspace.

Try returning to this Mac’s previous library and quitting with active work.
Unsafe transitions must be refused; failed transitions must restore access.
The original library and the paired replica remain separate throughout.

## Automated gates and remaining acceptance

`scripts/test-changes.sh --all` covers source checks, runtime and remote fixtures,
Swift packages, native builds, shared contracts, and mobile integration suites.
The fixtures exercise durable receipts, complete history/chunk replay, scoped
authorization, restart recovery, conflicts, cancellation, and artifact integrity.
They never consume provider services or modify a personal library.

Successful compilation, portable tests, and the runtime smoke are distinct from
app-hosted XCTest, real provider acceptance, and physical-device acceptance.
Record any toolchain test-runner failure explicitly. Do not infer unlimited iOS
background execution or working real network access from a simulator build.

## Provider catalog checks

`ios/Tests/CompanionInferenceTests/ProviderModelCatalogTests.swift` and
`default-agent/test/provider-catalog.test.mjs` use tiny synthetic descriptors and
controlled HTTP responses. They cover cold/warm/restarted/stale/304 caches,
first-load retry, offline retention, cancellation/provider isolation, complete
metadata round trips, xAI identity mapping, unsupported model filtering, bounded
responses, and rejection of foreign endpoints before credential access. Shared
engine checks also cover credential-free Browse, no startup catalog network,
pinned selections across refresh and restart, and empty/valid/offline Claude
SDK discovery. Existing inference, native-context, attached-child and durable
recovery tests remain provider-free.

Manual acceptance still needs a device/provider session: rapidly switch providers
and dismiss the picker while loading; reopen a configured conversation with the
catalog and central Mac unavailable; verify cached names and explicit retry; then
refresh metadata during an active run and confirm its original route is retained.
Live subscription discovery can fail independently of its last saved inventory.
No fixture test establishes live account access, provider inference, physical
suspension behavior, or Tailscale availability.

## Connection and offline-sync acceptance

- Each secondary Mac has a local agent workspace without enabling a separate
  execution mode. Its local runs sync directly under that Mac’s own identity.
  Linux provisioning controls remain on the central Mac.
- Pairing a client retrieves the enabled workspace directory and direct access;
  no per-workspace pairing ceremony is required. Test the first connection with
  one workspace temporarily unavailable, then let it return and acquire access.
- Save notes and calendar events, terminate/reopen offline, and reconnect. The
  pending count must clear only after durable central acceptance. A conflict in
  one folder or a failed artifact transfer must not block unrelated calendar or
  execution history synchronization.
- Keep an older chat and a saved artifact offline, complete their download, then
  disconnect and reopen them. Verify pinned content survives ordinary cache
  cleanup. Never show a partial download as complete.
- Disconnect and re-pair with the same central library without discarding local
  writing or device credentials for inference. A different library must not
  receive the old library’s pending writes.
- Leave central offline while two clients edit different notes: they converge
  through central after reconnection. Edit the same note on both: both versions
  remain recoverable. Deletion plus an offline edit must preserve recovery
  without restoring the deleted canonical identity.
- Verify status distinguishes central reachability, local pending writing and
  completed synchronization. Ordinary disconnects remain quiet outside Settings
  and the affected item. Test iPhone, iPad portrait/landscape, and secondary Mac.
