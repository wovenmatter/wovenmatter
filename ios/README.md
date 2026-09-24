# Woven Matter iPhone companion

This native SwiftUI app uses the running Mac as the canonical workspace and execution owner. It lives in the same repository and consumes the portable `WovenMatterCompanion` package from `../shared`. `CompanionClient` has no UI or provider execution dependency.

Open `WovenMatterCompanion.xcodeproj`, select the **WovenMatterCompanion** scheme and an iPhone. The development bundle is `com.wovenmatter.companion.dev`, using the existing Woven Matter Apple team `3M84Q9NAMN`. A signed device build requires the registered test device and that team's Xcode account. `project.yml` is the XcodeGen source; the generated project is checked in. Regenerate with `xcodegen generate --spec ios/project.yml` from the repository root.

```sh
scripts/test-ios.sh
scripts/test-ios.sh --simulator
scripts/test-ios.sh --ui
scripts/build-ios.sh
WOVENMATTER_IOS_DEVICE_ID=<registered-device-id> scripts/build-ios.sh --device
```

`--package` (the default) runs portable client/store tests. `--simulator` adds an unsigned simulator build and app-hosted model tests; `--ui` also runs the native interaction suite. Simulator test modes create and remove a disposable device by default. `WOVENMATTER_IOS_SIMULATOR_DESTINATION` explicitly selects an existing test device; `WOVENMATTER_IOS_SIMULATOR_DEVICE_TYPE` and `WOVENMATTER_IOS_SIMULATOR_RUNTIME` customize disposable creation. These commands use isolated temporary build caches. The app-hosted XCTest process detects its test bundle before opening any store or Keychain, creates a unique temporary library, and suppresses automatic connection. Package and UI tests use temporary stores and fake adapters; they never consume provider services. UI tests seed an isolated local fixture library in Debug builds using `WOVENMATTER_UI_FIXTURE=1`. `WOVENMATTER_UI_TAB=Home|Folders|Content|Chat|Note` chooses the initial fixture screen. Fixture mode does not pair or run agents.

## Pairing and test workflow

1. Run the development Mac app with its isolated workspace. Open Settings → iPhone Companion, enable sharing, and create a pairing code.
2. Connect both devices to the same tailnet. In the iPhone Home screen, select Pair your Mac and scan the code or paste the pairing link. Its endpoint is the Tailscale HTTPS URL; the short-lived code is exchanged for a per-device credential stored only in Keychain.
3. Create a folder and an ordinary note while the Mac is unavailable. The note reports **Saved on iPhone** only after durable local storage commits. Terminate and reopen the app to check that writing persists.
4. Reconnect and wait for **Saved · synced with Mac**. The note's client-created ID is preserved. Reference it in a new chat; the app flushes the note before binding its canonical revision to the run.
5. Open the same conversation on the Mac, respond to a pending approval/question on either device, and verify the other sees the first accepted response. Disconnecting the phone never stops a Mac-owned run.

## Persistence and recovery

The store actor commits a small atomic JSON index and immutable SHA-256 body blobs. Bodies are fsynced before index replacement. A failed write does not advance in-memory committed state; garbage collection runs only after an index commit and retains every referenced body. An unchanged snapshot, cursor, receipt or transcript performs no durable write.

Every mutation has a stable operation ID and conditional base revision. Submitted payloads never change during retries. Edits made while a mutation is in flight become a successor operation after acknowledgement. A delayed UI save carries the displayed base version; concurrent Mac changes become a visible conflict containing base, local and remote writing. Only revisions proven to descend from this phone's own acknowledgements can advance that base automatically. Deleted conflicting notes can be preserved as a new explicitly named copy; the deleted canonical ID is never silently resurrected.

The default note-body budget is 64 MB, counting bases, conflict variants and outbox bodies. Clean body eviction keeps IDs, titles, folders and revisions discoverable; an online open downloads the original document. Pending writing is never evicted. The durable transcript cache retains about 20 recent conversations under 16 MB. It is read only while disconnected. Media is not downloaded into this cache.

New-chat creation and its first send are separate durable commands with separate stable IDs. Receipt recovery never automatically executes an unsent continuation. Home offers an explicit Continue action after an interrupted request. Existing-session drafts and capabilities are scoped by conversation, and a send captures its target before any asynchronous save or network work.

## Editing and online assets

Native text views edit individual rich text blocks in the original JSON tree. Block IDs, links, run styling, table structures and untouched extension fields remain intact. The smaller toolbar offers paragraphs, headings, bullets and paragraph bold. Tables are displayed without editing. Unknown document versions or unsupported blocks remain read only, with original-document export. HTML assets use an ephemeral read-only WebKit view. Inline scripts can render the desktop-compatible `window.wovenMatterData` value; remote resources, network requests, forms, navigation and native bridges remain unavailable. Linked spreadsheets and HTML request only the canonical registered database link from the Mac, verify the note revision, and show the desktop unavailable-data reason when the source cannot be read. Preview rows are never persisted into the note. Oversized text pastes or paragraph additions are rejected before the native editor adopts them.

Agent routes and controls come from the Mac's provider catalog and live per-session capability negotiation. The phone does not install, authenticate or execute providers. Offline agent execution, push notifications, hosted accounts, provider setup, billing, voice and multi-Mac switching are outside this companion MVP.
