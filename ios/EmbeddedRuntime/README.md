# Embedded runtime sources

See [on-device execution architecture and validation](../../docs/IOS_EMBEDDED_EXECUTION.md).

Rebuild the checked-in resources with:

```sh
npm ci --ignore-scripts --prefix ios/EmbeddedRuntime
node scripts/build-ios-embedded-runtime.mjs
node scripts/build-ios-embedded-runtime.mjs --check
```
