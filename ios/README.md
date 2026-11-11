# Woven Matter iOS app

The Woven Matter iOS app runs on iPhone and iPad; the Mac app is the Woven Matter
desktop app. Native clients share a central Woven Matter database. On the device,
Quick Chat runs Pi Durable for notes, web search, simple questions, timers and reminders; Mac
and Linux workspace agents handle everything else. Inference uses provider
connections signed in on that device or an explicitly selected Tailscale host.
See [Quick Chat](../docs/IOS_CONTINUED_EXECUTION.md).

The app is complete without a Mac. A fresh install signs in to a model provider
and adds a web search key in Settings → iPhone Connections, then uses Quick Chat,
notes and folders, calendar, timers and reminders, and dictation on the phone.
Nothing waits on a host: there are no connection banners or network retries,
and analytics are not sent. Home offers "Connect your Mac" for workspaces, agents on
your computers and sync; Mac-only pages (Scheduled tasks, Databases) appear once
paired. Pairing later uploads everything made on the phone once: notes and
folders, Quick Chat history, calendar events, timer reminders and dictations.

## Build and validate

```sh
scripts/build-ios.sh
scripts/build-ios.sh --device-compile
scripts/test-ios.sh --package
scripts/test-ios.sh --all-devices
```

Open `WovenMatter.xcodeproj`, scheme `WovenMatter` (app target `WovenMatter`),
to run from Xcode. Device installation uses existing local signing assets. The generated
project comes from `project.yml`; regenerate it with `xcodegen` in `ios/` and
never edit `project.pbxproj` by hand. Tests use synthetic stores and provider
fixtures, never personal accounts or inference services.

Debug builds are **Woven Matter Dev** (`com.wovenmatter.wovenmatter.dev`), for the
simulator and occasional local device builds. Release builds are **Woven Matter**
(`com.wovenmatter.wovenmatter`), the TestFlight app. The two install side by side.

For the user's Mac acceptance build, use `scripts/build_and_run.sh` with its
existing data. For a disposable Mac database, that same launcher accepts
a separate instance (`--instance iphone-test`) and `WOVENMATTER_DEV_CACHE_DIR`.
Do not substitute an empty variant for a requested personal dev build.
Build/install does not authorize pairing, unpairing, or account sign-in.

UI-only simulator fixtures use `WOVENMATTER_UI_FIXTURE=1` and a stable
`WOVENMATTER_UI_FIXTURE_NAMESPACE`. Pairing and agent execution are disabled in
that mode. Use a separate simulator without fixture variables for real pairing.
`WOVENMATTER_UI_SCENARIO=standalone` is a fresh install that was never paired
(`standalone-timer` adds a Quick Chat timer); `testFreshInstallWithoutPairingIsCompleteAndCalm`
covers it.

## Source layout

- `MobileApp`: SwiftUI/UIKit navigation, Quick Chat, timers and lifecycle.
- `LibraryClient`: durable local data, offline mutations and owner journal; the
  Woven Matter desktop app uses it too when it is a client of another library host.
- `MobileInference`: provider connections, credentials and streaming.
- `PiDurableRuntime`: bundled SDK hosted by JavaScriptCore; see [runtime](Runtime/README.md).
- `EmbeddedExecution`: confined Python/WASM test package, not linked in the app; see [execution](../docs/IOS_EMBEDDED_EXECUTION.md).
- `../shared`: portable note types and versioned wire contracts.

Both apps compile the desktop's `DashboardStyle.swift` and bundle the same
`SharedAssets.xcassets`. Follow [the style guide](../docs/STYLE_GUIDE.md).

See [distributed architecture](../docs/DISTRIBUTED_CLIENT_ARCHITECTURE.md),
[device acceptance](../docs/DISTRIBUTED_CLIENT_TESTING.md), and
[Quick Chat lifecycle](../docs/IOS_CONTINUED_EXECUTION.md) for the shared contracts
and remaining hardware/provider checks.

## TestFlight

`scripts/prepare-ios-testflight.sh` builds, checks and uploads the Release app.
It never signs in interactively, never creates certificates, accounts or app
records, and sends nothing to Apple unless you pass `--upload`.

```sh
scripts/prepare-ios-testflight.sh --plan                 # what is ready; builds nothing
scripts/prepare-ios-testflight.sh --unsigned-build DIR   # compile and check Release, no signing
scripts/prepare-ios-testflight.sh --archive DIR          # signed IPA, checked; uploads nothing
scripts/prepare-ios-testflight.sh --upload DIR           # the same, then uploads it
scripts/prepare-ios-testflight.sh --verify-export IPA    # check an exported IPA
```

`DIR` must not exist yet; the script never overwrites earlier output. Each run
keeps its Xcode logs (`build.log`, `archive.log`, `export.log`, `upload.log`)
there. `--archive` and `--upload` stop before building if the Apple Distribution
certificate is missing, and `--upload` also stops if the API key is missing.

**Version and build number.** The version is `MARKETING_VERSION` in
[project.yml](project.yml), now `0.0.1`. You never set a build number: every
`--archive` and `--upload` stamps one from the UTC clock and prints it. The form
is `YYYYMMDD.T`, where `T` is hour × 10000 + minute × 100 + second, so
18:34:02 UTC on 11 November 2026 is `20261111.183402` and 09:05:07 is
`20261111.90507`. Every build is unique and higher than the one before. To ship
a new version, change `MARKETING_VERSION`, run `xcodegen` in `ios/`, and commit.

**What gets checked.** `scripts/verify-ios-app.sh` checks the archived app and the
exported IPA before anything is uploaded:

- name, bundle ID, version and build number, with no unexpanded build settings;
- the AppIcon catalog, iPhone and iPad support, and the camera and microphone
  purpose strings;
- the privacy manifest, exactly as described below;
- `ITSAppUsesNonExemptEncryption` set to false;
- no Debug-only UI fixtures or development hooks in any binary, and no
  Python/WASM, embedded execution or background processing;
- in the IPA: one app only, an Apple Distribution signature for team
  `3M84Q9NAMN`, an App Store provisioning profile that allows TestFlight and has
  not expired, and only the expected entitlements, with debugging off.

The tests are `scripts/test-support/test_verify_ios_app.py`; they use synthetic
bundles and stubbed Apple tools, never a real build or Apple service.

### Privacy manifest

[PrivacyInfo.xcprivacy](Config/PrivacyInfo.xcprivacy) is bundled in the app. It
declares no tracking and the following, from an audit of the code linked into the
app and of the symbols in the Release binary:

| Required-reason API | Reason | Where |
| --- | --- | --- |
| User defaults | `CA92.1`: this app's own preferences | `@AppStorage` settings, dictation preferences |
| File timestamps | `C617.1`: files inside the app container | Pi Durable checkpoint listings, saved device files, images in rendered HTML |
| System boot time | `35F9.1`: elapsed time within the app | `systemUptime` behind `performance.now()` in the Pi Durable runtime |

Disk space and active keyboard APIs are not used.

| Data sent off the device | Linked | Purpose | What and where |
| --- | --- | --- | --- |
| Other user content | yes | App functionality | Quick Chat messages, history, notes and tool output, to the model provider the user connects |
| Search history | yes | App functionality | Quick Chat web searches, to the search provider the user connects (Exa, Brave Search or Firecrawl) |
| User ID | no | Analytics | The random library analytics ID ([analytics](../docs/analytics/README.md)) |
| Product interaction | no | Analytics | The six-hourly `app_opened` and `app_active` signals |

The phone sends analytics only to its paired Mac, which forwards them to
PostHog. Without a paired Mac nothing is sent, because the app first waits for
the Mac's analytics preference. Notes and chats synced to your own Mac or Linux
host, and on-device dictation, are not collected by Woven Matter and are not
declared. Answer App Store Connect's **App Privacy** questions the same way.

If the code starts using another required-reason API or sends new data, update
the manifest and the lists in `scripts/verify-ios-app.py` together.

### Export compliance

The app uses only exempt encryption: HTTPS through URLSession, Curve25519
signatures that authenticate its requests, SHA-256 hashing, iOS Data Protection
and the Keychain. It implements no encryption of its own. `Info.plist` therefore
sets `ITSAppUsesNonExemptEncryption` to false, so App Store Connect does not ask
the export compliance questions for each build. If the app ever adds other
encryption, change that key and answer the questions in App Store Connect.

### Setup and first upload

Do these once, in order. Steps 1 to 4 happen on Apple's websites or in Xcode;
the script cannot do them.

1. **Register the bundle ID.** (Done: `com.wovenmatter.wovenmatter` is registered.) At
   [developer.apple.com/account](https://developer.apple.com/account), open
   Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App.
   Description `Woven Matter`, explicit bundle ID `com.wovenmatter.wovenmatter`.
   No capabilities are needed. Register.

2. **Create the app record.** In [App Store Connect](https://appstoreconnect.apple.com),
   open Apps → **+** → New App:
   - Platform: iOS
   - Name: `Woven Matter` (it must be unused on the App Store; if it is taken,
     choose a variant here; the name under the home-screen icon stays Woven Matter)
   - Primary language: English (U.S.)
   - Bundle ID: `com.wovenmatter.wovenmatter`
   - SKU: `wovenmatter-ios` (any private label; testers never see it)
   - User access: Full Access

3. <a id="apple-distribution-certificate"></a>**Apple Distribution certificate.**
   Only the Account Holder or an Admin can create one. In Xcode, open
   Settings → Accounts, select team `3M84Q9NAMN`, click **Manage
   Certificates…**, click **+** and choose **Apple Distribution**. Xcode puts the
   certificate and its private key in this Mac's login keychain. To build on
   another Mac later, export it from Keychain Access (My Certificates) as a
   `.p12`. Then run `scripts/prepare-ios-testflight.sh --plan`; it should report
   one distribution identity.

4. <a id="app-store-connect-api-key"></a>**App Store Connect API key.** In App
   Store Connect, open Users and Access → Integrations → App Store Connect API →
   Team Keys. (The first time, the Account Holder must request access.) Click
   **+**, name it `Woven Matter TestFlight` and give it the **Admin** role. Admin
   lets Xcode create and update the App Store signing profile with the key, as
   well as upload builds; a narrower role may be enough just to upload, but that
   has not been tried. Download the `.p8` file; Apple allows this only once. Then,
   with your key ID in place of `KEYID`:

   ```sh
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_KEYID.p8 ~/.appstoreconnect/private_keys/
   chmod 600 ~/.appstoreconnect/private_keys/AuthKey_KEYID.p8
   ```

   Save the key ID and the issuer ID (shown above the list of keys) next to the
   key, in `~/.appstoreconnect/woven-matter.env`:

   ```sh
   printf 'ASC_KEY_ID=KEYID\nASC_ISSUER_ID=your-issuer-id\n' > ~/.appstoreconnect/woven-matter.env
   chmod 600 ~/.appstoreconnect/woven-matter.env
   ```

   The script reads these two values from that file (it never runs the file).
   `ASC_KEY_ID` and `ASC_ISSUER_ID` set in the environment take precedence, and
   `ASC_CONFIG` points the script at a different file.

   To keep the key somewhere else, also set `ASC_KEY_PATH` (in the environment or
   that file) to the `.p8` file.
   The `.p8` file is the secret: never commit it, paste it into a chat, or copy it
   into this repository. If it leaks, revoke it on the same page.

5. **First upload.** In a new terminal on this Mac:

   ```sh
   scripts/prepare-ios-testflight.sh --plan
   scripts/prepare-ios-testflight.sh --upload ~/WovenMatterBuilds/testflight-$(date -u +%Y%m%d-%H%M%S)
   ```

   `--plan` should show one distribution identity and the API key as ready.
   `--upload` archives the app (letting Xcode create the App Store profile with
   the key), exports the IPA, checks it, and uploads exactly that IPA with:

   ```sh
   xcrun altool --upload-package IPA --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" \
     --p8-file-path KEY.p8 --output-format normal
   ```

   Apple then processes the build and emails you when it appears under
   TestFlight in App Store Connect. Later uploads are just step 5 again.

### Internal testing

Internal testers are people on the team in App Store Connect, up to 100. Their
builds need no Apple review.

1. In App Store Connect, open the app → TestFlight → Internal Testing → **+**,
   and create a group such as `Team`. Turn on automatic distribution so each new
   build reaches the group.
2. Add yourself to the group.
3. On the iPhone or iPad, install **TestFlight** from the App Store and sign in
   with the same Apple Account. Open the invitation email, or open TestFlight
   directly, and install Woven Matter. It sits next to Woven Matter Dev.

### External testing

External testers are anyone you invite by email or through a public link, up to
10,000. The first build of each version goes through Beta App Review; later
builds of the same version may not need a full review.

1. TestFlight → **Test Information**:
   - Beta App Description: what Woven Matter is and what to try.
   - Feedback Email: where tester feedback should go.
   - Privacy Policy URL: `https://wovenmatter.com/privacy`.
   - Beta App Review contact: name, phone and email.
   - Sign-in required: no. The app has no Woven Matter account.
   - Review notes, for example:

     > Woven Matter works on its own; pairing with a Mac is optional and not
     > needed to review the app. Notes, folders, calendar and timers are stored
     > on the device. To try Quick Chat: Settings → iPhone Connections → Claude ·
     > API key (or OpenAI · API key), paste the test key below, then open Chats
     > and ask a question, or ask it to create a note or a timer. Web search is
     > optional: Settings → iPhone Connections → Web search.
     >
     > Test provider key: (paste here)

     Put the test key only in this App Store Connect field, never in the
     repository. Use a key with a low spending limit that you revoke after
     review. Tapping "Sign in to a model provider to use Quick Chat" in an
     empty chat opens the same Connections page.
2. TestFlight → External Testing → **+**: create a group and add the build. It is
   sent to Beta App Review.
3. After approval, add testers by email, or turn on the group's **public link**
   and share it. You can cap how many people may join through the link.

### How often, and for how long

There is no fixed schedule: every `--upload` makes a new build, and internal
testers can install it as soon as Apple finishes processing it. External testers
get it after review, when one is needed. A build can be tested for 90 days after
upload; then TestFlight stops opening it, so upload a fresh build at least every
couple of months while people are testing.
