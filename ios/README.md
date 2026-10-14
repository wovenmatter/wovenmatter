# Woven Matter for iPhone and iPad

Native clients share a central Woven Matter database while Pi Durable executes
on the device. Inference uses provider connections signed in on that device or
an explicitly selected Tailscale host. Mac pairing is optional for local work.

## Build and validate

```sh
scripts/build-ios.sh
scripts/build-ios.sh --device-compile
scripts/test-ios.sh --package
scripts/test-ios.sh --all-devices
```

Open `WovenMatterCompanion.xcodeproj`, scheme `WovenMatterCompanion`, to run from
Xcode. Device installation uses existing local signing assets. The generated
project comes from `project.yml`; keep both in sync. Tests use synthetic stores
and provider fixtures, never personal accounts or inference services.

For the user's Mac acceptance build, use `scripts/build_and_run.sh` with its
existing data. For a disposable Mac database, that same launcher accepts
`WOVENMATTER_DEV_VARIANT=Companion` and a separate `WOVENMATTER_DEV_CACHE_DIR`.
Do not substitute an empty variant for a requested personal dev build.
Build/install does not authorize pairing, unpairing, or account sign-in.

UI-only simulator fixtures use `WOVENMATTER_UI_FIXTURE=1` and a stable
`WOVENMATTER_UI_FIXTURE_NAMESPACE`. Pairing and agent execution are disabled in
that mode. Use a separate simulator without fixture variables for real pairing.

## Source layout

- `CompanionApp`: SwiftUI/UIKit navigation, device execution and lifecycle.
- `CompanionClient`: durable local data, offline mutations and owner journal.
- `CompanionInference`: provider connections, credentials and streaming.
- `PiDurableRuntime`: bundled SDK hosted by JavaScriptCore; see [runtime](Runtime/README.md).
- `EmbeddedExecution`: confined Python/WASM commands; see [execution](../docs/IOS_EMBEDDED_EXECUTION.md).
- `../shared`: portable note types and versioned wire contracts.

Both apps compile the desktop's `DashboardStyle.swift` and bundle the same
`SharedAssets.xcassets`. Follow [the style guide](../docs/STYLE_GUIDE.md).

See [distributed architecture](../docs/DISTRIBUTED_CLIENT_ARCHITECTURE.md),
[device acceptance](../docs/DISTRIBUTED_CLIENT_TESTING.md), and
[background execution](../docs/IOS_CONTINUED_EXECUTION.md) for the shared contracts
and remaining hardware/provider checks.
