# Woven Matter for iPhone and iPad

The iPhone and iPad app is a Woven Matter device: the same thin UI as the Mac,
the device's own library, and the server's portable core running inside the
app, listening on nothing. The core is the only writer of the device's
library, syncs it with the person's machines and runs Quick Chat, a Pi Durable
session owned by the device. Everything else runs on the Macs and Linux
machines, and the app reaches their servers directly. See
[the architecture](../docs/ARCHITECTURE.md), "Devices", for the contract.

The app is a TestFlight beta and is not generally available; to request
access, email [trey@wovenmatter.com](mailto:trey@wovenmatter.com).

The app is complete without a Mac. Quick Chat uses only sign-ins made on the
device (Settings → Quick Chat → Subscriptions & API Keys), kept in its
Keychain: ChatGPT, Claude and Grok subscriptions, API keys, a web search key
(Exa, Brave Search or Firecrawl), or a model server on the tailnet.

## Connecting

One of the person's Macs shows a QR code and a short code in Settings → Apple
Devices. Both carry only that Mac's tailnet address and port; there is no
secret, nothing to approve and no pairing, and Tailscale decides who may
connect. The phone must be on the same tailnet, with the Tailscale app running.
In Settings → Machines the person scans the code or types it (any case, dashes
optional, or the link). The core dials that Mac, learns every machine's
address from it and remembers them, so it works with whichever machines are
online. Disconnect forgets the machines; the device keeps its library.

A link opened outside the app, `wovenmatter://connect/<code>`, opens Settings →
Machines and connects.

The app's version must match the Mac's: two machines on different releases do
not sync, and Machines names the one that needs updating. Both apps take their
version from [app/Version.xcconfig](../app/Version.xcconfig).

## Source layout

- `Sources/MobileApp`: the SwiftUI app. `App/` (the entry point, `MobileModel`,
  and `DeviceCore`, the one place the UI touches the core), `Shell/` (the tabs,
  the bottom bar and the iPad rail), `Chat/`, `Bots/`, `Folders/`, `Artifacts/`
  and `Settings/`.
- `Sources/WovenDevice`: the in-app host. It runs `WovenServerCore` over the
  device's library, keeps the machines' addresses and links, hands the device's
  rows and content to the servers, and answers sign-in requests from the
  device's Keychain. Only it imports the library and the core.
- `Sources/PiDurableRuntime`: Quick Chat's Pi Durable SDK, bundled and hosted by
  JavaScriptCore; built from `Runtime/` (see [its README](Runtime/README.md)).
- `Sources/MobileInference`: provider sign-ins, credentials, model catalogs,
  web search and streaming inference.

The UI shares the Mac's client layer: [project.yml](project.yml) compiles
`app/App/Client` (the stores, connections and types) and the shared views and
styles (`WovenStyle.swift`, the conversation views, the artifact editors) into
the app, and bundles `app/App/SharedAssets.xcassets`. Follow
[the style guide](../docs/STYLE_GUIDE.md). The Xcode project is generated from
`project.yml`: run `xcodegen` in `ios/` after adding or moving files, and never
edit `project.pbxproj` by hand.

## Build and validate

```sh
scripts/build-ios.sh                    # the Debug app for the simulator
scripts/build-ios.sh --device-compile   # the same for devices, unsigned
scripts/test-ios.sh --package           # the ios/ package's tests
scripts/test-ios.sh                     # those, then the UI tests on a throwaway simulator
```

`scripts/test-changes.sh` also runs the package's tests and builds the server's
core for the iOS Simulator. Tests use stand-ins and never call a provider.

Debug builds are **Woven Matter Dev** (`com.wovenmatter.wovenmatter.dev`, links
`wovenmatter-dev://`), for the simulator and local device builds. Release builds
are **Woven Matter** (`com.wovenmatter.wovenmatter`, links `wovenmatter://`),
the TestFlight app. The two install side by side, and a development Mac
instance's code opens the Dev app.

In Debug builds, `WOVENMATTER_CONNECT_CODE` set to a code or link in the launch
environment connects to that Mac at launch. For a Mac to connect to, start a
development instance on the tailnet: `scripts/build_and_run.sh --instance NAME
--port PORT`.

## TestFlight

`scripts/prepare-ios-testflight.sh` builds, checks and uploads the Release app.
It never signs in interactively, never creates certificates, accounts or app
records, and sends nothing to Apple unless you pass `--upload` or
`--ios-only-groups`.

```sh
scripts/prepare-ios-testflight.sh --plan                 # what is ready; builds nothing
scripts/prepare-ios-testflight.sh --unsigned-build DIR   # compile and check Release, no signing
scripts/prepare-ios-testflight.sh --archive DIR          # signed IPA, checked; uploads nothing
scripts/prepare-ios-testflight.sh --upload DIR           # the same, then uploads it
scripts/prepare-ios-testflight.sh --ios-only-groups      # TestFlight groups: iPhone and iPad only
scripts/prepare-ios-testflight.sh --verify-export IPA    # check an exported IPA
```

`DIR` must not exist yet; the script never overwrites earlier output. Each run
keeps its Xcode logs there. `--archive` and `--upload` stop before building if
the Apple Distribution certificate is missing, and `--upload` also stops if the
App Store Connect API key is missing.

### Setup

The bundle ID `com.wovenmatter.wovenmatter` is registered and its App Store
Connect app record exists. Two things live on the Mac that builds:

<a id="apple-distribution-certificate"></a>**Apple Distribution certificate.**
Only the Account Holder or an Admin can create one. In Xcode, Settings →
Accounts, select team `3M84Q9NAMN`, **Manage Certificates…**, **+**, **Apple
Distribution**. Xcode puts the certificate and its private key in the login
keychain; export it from Keychain Access as a `.p12` to build on another Mac.
`--plan` then reports one distribution identity.

<a id="app-store-connect-api-key"></a>**App Store Connect API key.** In App
Store Connect, Users and Access → Integrations → App Store Connect API → Team
Keys, create a key with the **Admin** role (it lets Xcode create the App Store
signing profile, upload builds and change TestFlight groups) and download its
`.p8` once. Put it at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`
(mode 600), and its key ID and issuer ID in
`~/.appstoreconnect/woven-matter.env` (mode 600) as `ASC_KEY_ID=…` and
`ASC_ISSUER_ID=…`. The script parses that file and never runs it;
`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` in the environment take
precedence, and `ASC_CONFIG` names another file. The `.p8` is the secret: never
commit it or paste it anywhere, and revoke it on the same page if it leaks.

### Each build

**Version and build number.** The version is `MARKETING_VERSION` in
`app/Version.xcconfig`, shared with the Mac app. You never set a build number:
every `--archive` and `--upload` stamps one from the UTC clock, `YYYYMMDD.T`
with `T` = hour × 10000 + minute × 100 + second (18:34:02 UTC on 11 November
2026 is `20261111.183402`), so every build is unique and higher than the last.

**iPhone and iPad only.** TestFlight offers iPhone apps on Apple silicon Macs
and Apple Vision Pro per group, and new groups start with both on. After every
upload, and whenever you run `--ios-only-groups`, the script turns both off for
every group with the API key and lists each group; if that fails after an
upload, the build is uploaded and `--ios-only-groups` retries. The App Store has
its own two checkboxes, which Apple's API does not expose: in App Store Connect,
the app → Distribution → Pricing and Availability, keep **iPhone and iPad Apps on
Apple Silicon Macs** and **Apple Vision Pro** unchecked.

**What gets checked.** `scripts/verify-ios-app.sh` checks the Release app and
the exported IPA before anything is uploaded: the name, bundle ID, URL scheme,
version and build number, with no unexpanded build settings; iPhone and iPad
support, the AppIcon catalog, the bundled icon license, and the camera and
microphone purpose strings; no continued background processing; the privacy
manifest, exactly as below; `ITSAppUsesNonExemptEncryption` set to false; no
Debug-only fixture or development markers in any binary; and, in the IPA, one app with an
Apple Distribution signature for team `3M84Q9NAMN`, an unexpired App Store
provisioning profile that allows TestFlight, and only the expected
entitlements, with debugging off. Its tests,
`scripts/test-support/test_verify_ios_app.py`, use synthetic bundles and
stubbed Apple tools.

### Privacy manifest

[PrivacyInfo.xcprivacy](Config/PrivacyInfo.xcprivacy) is bundled in the app.
It declares no tracking and:

| Required-reason API | Reason | Where |
| --- | --- | --- |
| User defaults | `CA92.1`: this app's own preferences | `@AppStorage` settings, dictation preferences |
| File timestamps | `C617.1`: files inside the app container | Pi Durable checkpoints, saved files, images in rendered HTML |
| System boot time | `35F9.1`: elapsed time within the app | `systemUptime` behind `performance.now()` in the Pi Durable runtime |

| Data sent off the device | Linked | Purpose | What and where |
| --- | --- | --- | --- |
| Other user content | yes | App functionality | Quick Chat messages, history, notes and tool output, to the model provider the person connects |
| Search history | yes | App functionality | Quick Chat web searches, to the search provider the person connects |

Nothing else leaves the device for Woven Matter: there are no analytics. What
syncs with the person's own machines, and on-device dictation, is not
collected. Answer App Store Connect's **App Privacy** questions the same way.
If the code starts using another required-reason API or sends new data, update
the manifest and the lists in `scripts/verify-ios-app.py` together.

### Export compliance

The app uses only exempt encryption: HTTPS through URLSession, SHA-256 hashing,
iOS Data Protection and the Keychain. Its connections to the person's machines
are WebSocket over the tailnet, which Tailscale encrypts. It implements no
encryption of its own, so `Info.plist` sets `ITSAppUsesNonExemptEncryption` to
false and App Store Connect does not ask the export compliance questions for
each build. If that changes, change the key and answer them.

### Testers

Internal testers (people on the team in App Store Connect, up to 100) need no
review: create a group under TestFlight → Internal Testing with automatic
distribution, run `--ios-only-groups`, and add them. External testers (by email
or a public link) need Beta App Review for the first build of each version; the
review notes should say the app works without a Mac and how to try Quick Chat
with a test provider key entered only in App Store Connect. A build can be
tested for 90 days after upload.
