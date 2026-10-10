# Woven Matter iPhone and iPad companion

This native SwiftUI app is a client of one designated Mac's central library. It can control authorized Mac/Linux execution workspaces directly over Tailscale and run Pi Durable on the iPhone or iPad itself. The central Mac stores synchronized app data and saved artifacts; working files and runtime checkpoints remain in their execution workspace. Inference runs in the cloud or on another Tailscale device. On-device inference is outside scope for all versions.

The app consumes `WovenMatterCompanion` from `../shared`. `CompanionClient` is the portable replica and transport layer, `PiDurableRuntime` hosts the reviewed SDK through JavaScriptCore, and `CompanionInference` keeps provider connections and credentials outside the agent's persisted JavaScript history. See [the distributed architecture contract](../docs/DISTRIBUTED_CLIENT_ARCHITECTURE.md).

Open `WovenMatterCompanion.xcodeproj`, select the **WovenMatterCompanion** scheme and an iPhone or iPad simulator. The development bundle is `com.wovenmatter.companion.dev`, using the existing Woven Matter Apple team `3M84Q9NAMN`. A signed device build requires the registered test device and that team's Xcode account. `project.yml` is the XcodeGen source; the generated project is checked in. Regenerate with `xcodegen generate --spec ios/project.yml` from the repository root.

```sh
scripts/test-ios.sh
scripts/test-ios.sh --simulator
scripts/test-ios.sh --ui
scripts/test-ios.sh --all-devices
scripts/build-ios.sh
scripts/build-ios.sh --device-compile
WOVENMATTER_IOS_DEVICE_ID=<registered-device-id> scripts/build-ios.sh --device
```

`--package` (the default) runs client/store, inference, and actual JavaScriptCore SDK tests on macOS. `--simulator` adds an unsigned simulator build and app-hosted model tests; `--ui` also runs the native interaction suite. `--all-devices` runs it on both disposable iPhone and iPad simulators, including rotation. `--device-compile` verifies the physical-device architecture without signing. Device builds use existing local signing assets; they do not initiate account setup. Simulator test modes create and remove a disposable device by default. `WOVENMATTER_IOS_SIMULATOR_DESTINATION` explicitly selects an existing test device; `WOVENMATTER_IOS_SIMULATOR_DEVICE_TYPE` and `WOVENMATTER_IOS_SIMULATOR_RUNTIME` customize disposable creation. These commands use isolated temporary build caches. The app-hosted XCTest process detects its test bundle before opening any store or Keychain, creates a unique temporary library, and suppresses automatic connection. Package and UI tests use temporary stores and fake adapters; they never consume provider services. UI tests seed an isolated local fixture library in Debug builds using `WOVENMATTER_UI_FIXTURE=1`. `WOVENMATTER_UI_TAB=Home|Folders|Chats|Notes|Settings|Library|Calendar|Trash` chooses the initial fixture screen. Fixture mode does not pair or run agents.

## Pairing and test workflow

1. Run the development Mac app with its isolated workspace. Open Settings → Devices, enable sharing, and create a pairing code.
2. Connect both devices to the same tailnet. In the iPhone or iPad Home screen, select Pair your Mac and scan the code or paste the pairing link. Its endpoint is the Tailscale HTTPS URL; the short-lived code is exchanged for a per-device credential stored only in Keychain.
3. Create a folder and an ordinary note while the Mac is unavailable. The note reports **Saved on this device** only after durable local storage commits. Terminate and reopen the app to check that writing persists.
4. Reconnect and wait for **Saved · synced with Mac**. The note's client-created ID is preserved. Reference it in a new chat; the app flushes the note before binding its canonical revision to the run.
5. Open the same conversation on the Mac, respond to a pending approval/question on either device, and verify the other sees the first accepted response. Disconnecting the phone never stops a Mac-owned run.

## Persistence and recovery

The store actor commits a small atomic JSON index and immutable SHA-256 body blobs. Bodies are fsynced before index replacement. A failed write does not advance in-memory committed state; garbage collection runs only after an index commit and retains every referenced body. An unchanged snapshot, cursor, receipt or transcript performs no durable write.

Every mutation has a stable operation ID and conditional base revision. Submitted payloads never change during retries. Edits made while a mutation is in flight become a successor operation after acknowledgement. A delayed UI save carries the displayed base version; concurrent Mac changes become a visible conflict containing base, local and remote writing. Only revisions proven to descend from this phone's own acknowledgements can advance that base automatically. Deleted conflicting notes can be preserved as a new explicitly named copy; the deleted canonical ID is never silently resurrected.

The default note-body budget is 64 MB, counting bases, conflict variants and outbox bodies. Clean body eviction keeps IDs, titles, folders and revisions discoverable; an online open downloads the original document. Pending writing is never evicted. The durable transcript cache retains about 20 recent conversations under 16 MB. It is read only while disconnected. Media is not downloaded into this cache.

New-chat creation and its first send are separate durable commands with separate stable IDs. Receipt recovery never automatically executes an unsent continuation. Home offers an explicit Continue action after an interrupted request. Existing-session drafts and capabilities are scoped by conversation, and a send captures its target before any asynchronous save or network work.

## Editing and online assets

Native text views edit individual rich text blocks in the original JSON tree. Block IDs, links, run styling, table structures and untouched extension fields remain intact. The smaller toolbar offers paragraphs, headings, bullets and paragraph bold. Tables are displayed without editing. Unknown document versions or unsupported blocks remain read only, with original-document export. HTML assets use an ephemeral read-only WebKit view. Inline scripts can render the desktop-compatible `window.wovenMatterData` value; remote resources, network requests, forms, navigation and native bridges remain unavailable. Linked spreadsheets and HTML request only the canonical registered database link from the Mac, verify the note revision, and show the desktop unavailable-data reason when the source cannot be read. Preview rows are never persisted into the note. Oversized text pastes or paragraph additions are rejected before the native editor adopts them.

Agent routes and controls come from the selected execution workspace. Settings exposes device inference connections and authorized inference hosts. API-key connections can call supported providers directly; subscription integrations that need a desktop SDK use an inference-only host. The phone still owns its Pi Durable loop, tools, checkpoints, subagents and isolated code execution. Losing the central library does not stop a device run or direct control of a reachable workspace. Losing the selected inference connection can pause/fail model work; accepted work is retained for recovery.

A device workspace uses a confined app directory, imported files, supported native tools and explicit approvals. iOS may suspend the app; durable recovery preserves work without promising unlimited background execution or replaying ambiguous tool effects. Push notifications, billing, hosted accounts and on-device inference are not part of this work.

## Current workspace features

Library searches files, links and photos from the Mac, opens retained files with native preview/share, and links back to their conversation. File downloads and exports are capped at 32 MB. Calendar supports events, recurring series, scheduled prompts, occurrence/series deletion, and task conversations. Device inference credentials remain in device-only Keychain. Workspace provider credentials remain with their configured inference host. Conversation and note detail sheets expose rename, pin/unpin, move, trash, restore and export. Session settings use negotiated model, thinking, permission and workspace-tool choices, including timer-pause confirmation.

On iPad, a persistent sidebar replaces the phone tab bar and remains available while editing; compact windows use the phone layout. The first phone UI pass is in place; further styling follows simulator feedback. Central-only operations explain their connection requirement. Notes, device execution, and previously authorized direct workspaces remain usable independently; sheets retain entered values when a request fails.

Pair each phone/tablet with a fresh code. Up to 16 devices can use one canonical Mac, each with independent revocation. Protocol 3 requires compatible Mac and mobile builds; existing local notes and stored pairing credentials are retained on upgrade. When background execution is enabled, the service owns sharing and the Settings window controls it over the existing local RPC connection. When disabled, keep the Mac app running.

For targeted simulator diagnosis, set `WOVENMATTER_IOS_TEST_ONLY=CompanionUITests/CompanionUITests/testWorkspaceSurfacesAndRotation`. Test results retain screenshots and logs; set `WOVENMATTER_IOS_TEST_DIAGNOSTICS=on-failure` to also collect a system diagnostic.

## Distributed execution testing

Use a separate non-fixture simulator for connected testing; keep the existing fixture namespace for UI refinement. Pairing and provider account setup use the user's existing authenticated sessions. Test scripts do not sign in or consume provider services.

1. Pair with the central Mac, then choose a reachable execution workspace. Provisioning gives this device a scoped credential; it does not copy administrator credentials or working files.
2. In Settings, configure a supported API-key connection or select an authorized inference host, provider account and model. Select this iPhone/iPad as the execution workspace. Run a small task that reads an imported file and creates an output locally.
3. Stop central sharing while leaving the selected inference endpoint reachable. Continue the device conversation and a direct Linux conversation. Reopen the app and confirm retained notes, drafts, command receipts and history.
4. Reconnect the library and inspect the same history from another client. Save a workspace output to the shared library, interrupt a transfer, and verify the resumed file opens with the same contents. Unsaved workspace files stay in their workspace.
5. Test Stop, approvals, subagent cancellation and foreground/background transitions. Explicit cancellation must remain cancelled after relaunch. A pending or unknown receipt must be reconciled, never replaced by a new send automatically.
6. Revoke a device on the central Mac. Direct access revocation is queued durably for unreachable workspaces and remains visibly pending until those workspaces reconnect. After a reachable workspace restart, approved encrypted device grants can unlock its configured provider vault without the central Mac; expired borrowed subscription credentials may still require their original account owner to reconnect.
7. Pair a secondary Mac and switch it to client mode. Its prior library remains on disk. Optionally enable a separate local execution workspace; changing roles or quitting requires pending local work to finish safely.

Image-reading tools can send their results to the image-capable model selected for that agent, using its existing connection and account. Responses and Chat Completions preserve tool images in their provider-specific formats. Direct connections reject a text-only model explicitly without sending a partial request or selecting a fallback. Manually configured custom Tailscale servers currently declare text-only capability; authorized host catalogs can advertise image-capable models.

Portable tests cover controlled provider streams and real SDK/tool persistence. Live provider accounts, Tailscale ACLs, physical-device suspension, and human UI acceptance are separate checks.

## First testing session

1. Build the Mac host from the same PR revision with `scripts/build-companion-desktop.sh build`. When ready to test, `scripts/build-companion-desktop.sh run` opens its separate workspace. Keep an existing signed-in Tailscale connection available on the Mac. Provider setup stays in the Mac app.
2. Open `ios/WovenMatterCompanion.xcodeproj`, select the WovenMatterCompanion scheme, and run on an iPhone simulator. Repeat on an iPad simulator. Pair each with its own fresh URL from Mac Settings → Devices; the simulator can use the pasted pairing URL.
3. Exercise a note in both directions, then edit the same note while disconnected, terminate/reopen the mobile app, reconnect, and review its conflict/recovery UI. Check that deleting a note on the Mac preserves unsynced mobile writing as a recovery copy.
4. Try each configured agent route: create, send, continue, respond to approvals/questions, and Stop. Switch conversations while a request is pending. Check that the Mac keeps accepted work running when the mobile app closes.
5. Browse Library files/links/photos; open exports and linked documents. Rename, move, pin, trash and restore notes/conversations. Adjust session model, thinking, permissions and tools. Create/edit recurring Calendar events and scheduled prompts in local and remote workspaces.
6. On iPad, repeat navigation and editing in portrait, landscape, and a compact window. With Mac background execution enabled, quit/reopen its frontend and confirm sharing remains owned by the background service.
7. Move to physical devices after simulator refinement. `scripts/build-ios.sh --device-compile` checks the hardware target without signing or installation; `--device` uses existing local signing assets for the selected registered device. Physical pairing, real provider behavior and OS/network transitions are acceptance checks for that session.

Automated fixtures do not use provider services or a personal workspace. A successful build is separate from live Tailscale/provider acceptance. UI appearance and editing ergonomics are ready for the next simulator feedback pass.

## October UI iteration baseline

The companion is integrated with main's structured per-input CLI context and native
OpenCode permission policies. Mobile Executor enablement follows the Mac's broker
acknowledgement path and retains its selected profiles. The native browser stays
on the Mac; provider-free facade tests compile against its production Objective-C
interface with an unavailable browser implementation, while the Xcode build and
browser lifecycle suite validate the actual bridge.

The first UI pass focuses on phone navigation, Home actions, chat controls, and
note editing. Tablets retain a separate sidebar, visible selection, and bounded
content width; compact windows use phone navigation. Persistence labels refer to
this device on both iPhone and iPad. The keyboard's Done button returns to navigation
without losing writing. Preview mode uses sample content and never sends agent work.

For visual iteration, build with `scripts/build-ios.sh`, then install its
`WovenMatterCompanion.app` in a dedicated simulator. Launch with
`SIMCTL_CHILD_WOVENMATTER_UI_FIXTURE=1`, a stable
`SIMCTL_CHILD_WOVENMATTER_UI_FIXTURE_NAMESPACE`, and
`SIMCTL_CHILD_WOVENMATTER_UI_TAB=Home` (or `Chats` / `Notes`). Retaining the namespace
preserves preview writing between builds. Xcode 27 uses Device Hub to show the
simulator. Use a separate simulator without fixture variables for real pairing.

The primary tabs are Home, Folders, Chats, Notes, and Settings. Opening a folder
shows its searchable notes and chats within Folders; Back to Folders returns to
the folder list. Settings contains Mac connection, sync controls, and the Green/Cognac appearance choice.

## Styling parity

The companion uses the desktop's actual Lucide assets and harness logos, compiled
from the same `DashboardStyle.swift` and `SharedAssets.xcassets`; it does not maintain
copies. Library uses `library-big`, chats `message-square`, notes `file-text`, and
settings `settings`. Navigation, new-item actions, search, calendar navigation,
send, warnings and database references follow the same glyph/stroke definitions.
Home is the upstream Lucide 0.563.0 house with the matching 1.5 stroke.

The audit covered Home, folder navigation and contents, chat/composer and agent
selection, note editing/conflicts/read-only assets, Library, Calendar/event forms,
Trash, Settings, pairing, item management and session settings. Palettes, muted
text, links, radii, search, segmented selectors, and primary/quiet buttons now use the shared definitions.
System typography remains Dynamic Type; touch targets and native iOS sheets,
pickers, switches, share/camera controls are intentionally adapted for mobile.
Desktop SF document-kind and formatting symbols remain consistent exceptions.
