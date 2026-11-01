# Woven Matter for iPhone and iPad

Use the phone to create and control conversations on Mac and Linux workspaces.
On iPhone, open Settings → Device Connections and pair with the QR code or link
from Settings → Apple Devices on the central Mac. All library/workspace endpoints use authenticated HTTPS over
Tailscale; the iPhone must be on the user's Tailnet. After grants are provisioned,
Linux agents, folders and conversations remain directly controllable while the
Mac is offline. Accepted work keeps running when the phone closes.

Quick Chat is powered by the bundled Pi Durable SDK and retains existing
on-device provider sign-ins, streaming, history, dictation and note references.
Its tools are limited to notes and public web search/reading. Add an optional
Exa API key in Settings → Quick Chat → Web search. Keys remain in the device-only
Keychain. Quick Chat has no shell, repository tools, Python, code mode, subagents,
goals or local scheduling. Previous device-agent chats remain retained history;
files those agents saved stay on the device and can be exported from the chat's
title menu → Saved files without reopening a runtime or tool.

Quick Chat asks before it first sends content to each model endpoint, and before
its first web search or page read through Exa. The sheet names the recipient,
its address and what is sent: messages, chat history, referenced or read notes,
web results and other tool output, and the chat's instructions. Declining sends
nothing and keeps the draft. Before resuming an interrupted run it asks the same
way; declining keeps that run saved, and allowing resumes the same run identity.
An answer applies only to the chat that asked. Each permission covers one provider and endpoint
origin, so a changed endpoint asks again; existing accounts from earlier builds
start without permission. Settings → Data sharing lists and withdraws them, taking
effect at the next request. The inference and Exa clients refuse to send without
a saved permission, including for resumed runs. Don’t Allow on the first Exa
question holds for that chat until relaunch; stopping or interrupting the run
while it is open is not an answer, so Resume asks again. The permission modes are
Ask Before Edits and Web Reads (the default) and Allow Edits and Web Reads. In Ask
mode, Quick Chat asks before saving note edits and before reading a webpage
address that neither the user nor a search in that chat supplied. These prompts
show the exact action; they do not make content read from notes or the web safe
to share, and web search itself is not limited.

Earlier builds could assign scheduled tasks to the phone, which no longer runs
schedules. Choosing a Mac or Linux agent for such a task retires it and creates a
replacement with a new identity. The replacement uploads only after central
accepts the retirement, and occurrences that already ran on the phone are
excluded, so exactly one runnable copy exists.

Backups include writing that exists only on the device: offline and unsynced
notes and their bases, conflicts, pending sends and chat drafts, phone Quick Chat
history, local calendar changes and files saved on the device. Unchanged notes,
transcripts and downloads that central can supply again are excluded; after a
restore their metadata stays visible and the bodies are fetched again. Pairing and
provider credentials are device-only Keychain items and are never restored, so a
restored device pairs and signs in again.

Notes keep their existing local-first editor and moderate coalesced sync, including
offline creation and editing. Workspace folder creation is performed by its owning
Mac/Linux service. Linux publishes its new folder metadata before its conversation
history after reconnecting with the central library. Update workspace services to
the same revision for the new folder APIs. Creating a remote folder or chat
requires a live connection to its owner. Interrupted replies recover in place
using the original request identity. A new chat with different text never waits
on an earlier unconfirmed one; that request stays saved and reconciles from its
receipt. The new-chat screen lists each unconfirmed one with Retry, which resends
it with its original IDs, and Show in composer. Within a chat, later input waits,
and Retry previous message resends the saved message with its original identity.
A library change with an unknown outcome orders only later changes to the same
item; repeating it resends the original command, and other items are unaffected.

A direct host proves only that it answers for its workspace ID. Its owner,
execution device, endpoint, content identity, journal devices, central-history
attestation and revision come from central's registry; a host's self-report can
refresh only its display name and descriptive capabilities. A Linux service
publishes its own folders independently: a folder central refuses as deleted or
foreign is kept with that reason, and a revoked or unexplained refusal or a receipt
for a different folder or root leaves the folder pending to retry with backoff.
Neither stops that workspace's history from publishing.

## Build and development validation

```sh
scripts/build-ios.sh
scripts/build-ios.sh --device-compile
scripts/test-ios.sh --package
scripts/test-ios.sh --ui
scripts/test-ios.sh --all-devices
scripts/verify-ios-app.sh /absolute/path/to/WovenMatterCompanion.app dev
```

Simulator builds and tests use Xcode ad-hoc signing so it embeds the simulated
application entitlement required by Keychain, including on first launch. No
signing certificate or account login is needed. `--device-compile` stays unsigned.

Open `WovenMatterCompanion.xcodeproj`, scheme `WovenMatterCompanion`, to run from
Xcode. Device installation uses existing local signing assets. Dev builds keep
`Woven Matter Dev` and `com.wovenmatter.companion.dev`; they support simulator and
direct-to-phone iteration independently of the distribution app.

UI fixtures use `WOVENMATTER_UI_FIXTURE=1` with a separate namespace. They disable
real pairing/execution. The dedicated Quick Chat smoke uses synthetic inference
and an isolated note store. Tests never consume provider services or sign in.

## TestFlight preparation

Release uses `Woven Matter` and `com.wovenmatter.companion`, preserving Dev builds.
The app bundles a privacy manifest declaring app preferences, private file timing,
and elapsed-time APIs. It declares user content and searches for the selected providers’ app functionality.
Its analytics declarations cover the independent random
library analytics ID and generic product interaction events, with no tracking or
personal-identity linkage; see [analytics](../docs/analytics/README.md).

The helper never signs in, requests provisioning updates, uploads or publishes.
Run it on the Mac that holds the signing assets:

```sh
scripts/prepare-ios-testflight.sh --plan
scripts/prepare-ios-testflight.sh --unsigned-build /absolute/path/to/new-directory
scripts/prepare-ios-testflight.sh --archive /absolute/path/to/new-directory --build-number 19
scripts/prepare-ios-testflight.sh --verify-export /absolute/path/to/WovenMatterCompanion.ipa
```

- `--plan` prints the version, the committed build number and how many Apple
  Distribution identities for team `3M84Q9NAMN` are in the keychain. It builds
  nothing.
- `--unsigned-build` compiles an unsigned device Release build and verifies the
  bundle. This proves compilation and the packaged resource boundary only.
- `--archive` stops before building when no distribution identity is installed.
  It archives with the given build number, verifies the archived app, exports
  with [ExportOptions.plist](Config/ExportOptions.plist) (`app-store-connect`,
  local export, Xcode does not change version or build numbers), and verifies
  the exported IPA. Output directories must be new.
- `scripts/verify-ios-app.sh --ipa` checks that IPA itself, without reading any
  intermediate products:
  - safe archive layout with exactly one app;
  - product name and identifier, numeric version and build, and expanded
    settings;
  - the AppIcon catalog, camera and microphone purpose strings, and the privacy
    manifest;
  - no Python/WASM, embedded execution or background processing resources, and
    no Debug UI fixtures;
  - a valid Apple Distribution signature for the team, App Store provisioning
    (not development, ad hoc or enterprise; not expired), and only the expected
    entitlements, with no debugging allowed.

  Checks fail closed under Python optimization; see
  `scripts/test-support/test_verify_ios_app.py`.

### Prerequisites only Trey can complete

These require an Apple account and are never performed by tooling here:

1. **Membership and roles.** Membership in Apple Developer Program team
   `3M84Q9NAMN` with permission to create App Store Connect apps and manage
   TestFlight.
2. **App record.** An App Store Connect app record for bundle ID
   `com.wovenmatter.companion`, with name, primary language and SKU
   ([Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)).
3. **Signing.** An Apple Distribution certificate with its private key in this
   Mac's login keychain. An App Store provisioning profile for the bundle ID must
   be available to Xcode's automatic signing on this Mac
   ([Distributing your app](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)).
   `--plan` reports whether one is installed; `--archive` refuses to run
   without it.
4. **Build number.** Choose a build number greater than every build already
   uploaded for the version. The version is `MARKETING_VERSION` in
   [project.yml](project.yml); the committed build number is only the Dev
   default. To record a new baseline, change `project.yml` and regenerate with
   `xcodegen` in `ios/`. The helper refuses to run if `project.yml` and the
   Xcode project disagree.
5. **Upload.** Upload the verified IPA yourself with Xcode Organizer or
   Transporter
   ([Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)).
6. **Export compliance.** Answer the export-compliance questions for each build,
   or add `ITSAppUsesNonExemptEncryption` once you have decided
   ([Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance),
   [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)).
   The source inventory, which is not a legal determination:
   - HTTPS through Apple's URLSession;
   - SHA-256 hashing (CryptoKit) for content digests, request identities and
     OAuth PKCE;
   - random identifiers from `SecRandomCopyBytes` and JavaScript
     `crypto.getRandomValues`;
   - no app-implemented encryption or decryption.

   The Info.plist key is deliberately not set, so the verifier reports it as
   undeclared.
7. **App privacy and AI data sharing.** Complete App Privacy so it matches the
   privacy manifest and actual behavior
   ([App privacy details](https://developer.apple.com/app-store/app-privacy-details/)).
   Quick Chat sends user-chosen content to the provider and Exa endpoints the
   user configures, after the in-app permission described above
   ([guideline 5.1.2](https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing)).
   Provide a privacy policy URL.
8. **TestFlight test information.** Provide test information: beta app
   description, feedback email, and for external testing a privacy policy URL
   and Beta App Review contact details
   ([Provide test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)).
   Internal testers on the team do not need Beta App Review; external groups do.
9. **Reviewer access.** Beta App Review needs a way to use the app. Without
   pairing, notes, calendar and dictation work offline. Pairing requires a Mac
   running Woven Matter on the reviewer's Tailnet. Quick Chat requires a model
   provider sign-in or API key. Decide what access and instructions reviewers
   receive. Enter any credentials only in App Store Connect, never in this
   repository.
10. **Physical acceptance.** Complete the
    [physical iPhone pass](../docs/DISTRIBUTED_CLIENT_TESTING.md#short-physical-iphone-pass)
    on a registered device with the Dev app, then install the TestFlight build
    and repeat the data-sharing and pairing steps.

App-hosted XCTest and UI tests must also run on a compatible Xcode. Development
validation does not establish release-candidate validation. The release draft
and its description still need Trey's explicit approval before publication.

See [architecture](../docs/DISTRIBUTED_CLIENT_ARCHITECTURE.md),
[acceptance](../docs/DISTRIBUTED_CLIENT_TESTING.md), and
[lifecycle](../docs/IOS_CONTINUED_EXECUTION.md).

### Note editing on iPhone

Notes keep the existing offline store and coalesced synchronization. The toolbar sits above the full-width title, followed directly by the note body. It provides undo/redo, selection formatting (bold, italic, underline, highlight, fonts and links), headings and lists, and dictation. A bottom-right word count toggles to characters, matching the desktop count semantics. Save/sync status is a compact bottom-left control; tap for details. Return starts a new paragraph block. After a heading it starts body text, inside a list it continues the list, and on an empty list item it leaves the list. Numbered items count within their list as on the Mac (1, 2, 3); body text, a table or another list restarts the count. Pasted lines become paragraphs in one bounded edit; a paste beyond the note's size or 10,000-block limit is refused without changing the note. Dictated line breaks become paragraphs the same way and insert once. Delete at the start of a list item or heading first turns it into body text; at the start of body text it joins the previous paragraph. Each break or join is one undo step, and undo or redo returns the caret to the restored paragraph so typing and formatting continue without a tap. A note that ends in a table offers an empty paragraph after it, which joins the note only once written in. There is no Add paragraph action. Existing spreadsheet, table and linked-artifact previews retain their current read-only behavior on mobile.
