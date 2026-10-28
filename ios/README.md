# Woven Matter for iPhone and iPad

Use the phone to create and control conversations on Mac and Linux workspaces.
Pair once with the central Mac through Settings → Device Connections using its
QR code or link. All library/workspace endpoints use authenticated HTTPS over
Tailscale; the iPhone must be on the user's Tailnet. After grants are provisioned,
Linux agents, folders and conversations remain directly controllable while the
Mac is offline. Accepted work keeps running when the phone closes.

Quick Chat is powered by the bundled Pi Durable SDK and retains existing
on-device provider sign-ins, streaming, history, dictation and note references.
Its tools are limited to notes and public web search/reading. Add an optional
Exa API key in Settings → Quick Chat → Web search. Keys remain in the device-only
Keychain. Quick Chat has no shell, repository tools, Python, code mode, subagents,
goals or local scheduling. Previous device-agent chats remain retained history.

Notes keep their existing local-first editor and moderate coalesced sync, including
offline creation and editing. Workspace folder creation is performed by its owning
Mac/Linux service. Linux publishes its new folder metadata before its conversation
history after reconnecting with the central library. Update workspace services to
the same revision for the new folder APIs. Settings → Pending changes offers
explicit receipt recovery and retries for interrupted requests.

## Build and development validation

```sh
scripts/build-ios.sh
scripts/build-ios.sh --device-compile
scripts/test-ios.sh --package
scripts/test-ios.sh --ui
scripts/test-ios.sh --all-devices
scripts/verify-ios-app.sh /absolute/path/to/WovenMatterCompanion.app dev
```

Open `WovenMatterCompanion.xcodeproj`, scheme `WovenMatterCompanion`, to run from
Xcode. Device installation uses existing local signing assets. Dev builds keep
`Woven Matter Dev` and `com.wovenmatter.companion.dev`; they support simulator and
direct-to-phone iteration independently of the distribution app.

UI fixtures use `WOVENMATTER_UI_FIXTURE=1` with a separate namespace. They disable
real pairing/execution. The dedicated Quick Chat smoke uses synthetic inference
and an isolated note store. Tests never consume provider services or sign in.

## Distribution preparation

Release uses `Woven Matter` and `com.wovenmatter.companion`, preserving Dev builds.
The app bundles a privacy manifest declaring app preferences, private file timing,
and elapsed-time APIs. It declares user content and searches for the selected providers’ app functionality.
Its analytics declarations cover the independent random
library analytics ID and generic product interaction events, with no tracking or
personal-identity linkage; see [analytics](../docs/analytics/README.md).

```sh
scripts/prepare-ios-testflight.sh --plan
# Later, after development testing and explicit archive approval:
scripts/prepare-ios-testflight.sh --archive /absolute/path/to/new-output-directory
```

The archive helper uses existing signing assets, verifies the product profile,
privacy manifest and absence of Python resources, then creates a private export.
It never initiates account authentication or uploads/publishes a build. App Store
Connect app records/access, distribution signing/provisioning, export compliance,
beta metadata and physical iPhone acceptance must be verified before delivery.
Development validation does not establish release-candidate validation.

See [architecture](../docs/DISTRIBUTED_CLIENT_ARCHITECTURE.md),
[acceptance](../docs/DISTRIBUTED_CLIENT_TESTING.md), and
[lifecycle](../docs/IOS_CONTINUED_EXECUTION.md).
