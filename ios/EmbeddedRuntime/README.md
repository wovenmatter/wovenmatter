# Embedded runtime sources

See [on-device execution architecture and validation](../../docs/IOS_EMBEDDED_EXECUTION.md).

Rebuild the checked-in resources with:

```sh
npm ci --ignore-scripts --prefix ios/EmbeddedRuntime
node scripts/build-ios-embedded-runtime.mjs
node scripts/build-ios-embedded-runtime.mjs --check
```

Run the shared offline Python/WebKit smoke scenarios on macOS without installing
or launching either app:

```sh
scripts/test-embedded-runtime-macos.sh
```

This executes the checked-in worker and WASM resources with temporary workspace
data. The same `SmokeRunner.swift` scenarios run in the iOS simulator fixture.
The macOS check does not replace simulator UI or device acceptance.
