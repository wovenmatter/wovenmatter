# On-device Pi Durable

Quick Chat runs the real `@earendil-works/pi-durable` SDK inside the app, in
JavaScriptCore. The bundle (`ios/Sources/PiDurableRuntime/Resources/pi-durable.js`)
is built from the release `default-agent/package-lock.json` locks, the same one
the server's Pi Durable runs. The app ships no Node and downloads no code, so
an SDK update reaches the device only in a new app build.

```sh
(cd default-agent && ../scripts/with-pinned-node.sh npm ci)
(cd ios/Runtime && ../../scripts/with-pinned-node.sh npm ci)   # esbuild
scripts/with-pinned-node.sh node scripts/build-ios-pi-runtime.mjs [--check]
```

The script writes the bundle, `provenance.json` (the SDK release and the
packages bundled), the notices' heading and `MobileInference/PiSDKVersion.swift`.
`--check` verifies the committed files match.

## Sources

- `entry.js`: one conversation per context. It opens the SDK's stock JSONL
  storage over the conversation's directory, registers the host's tools, and
  drives turns: send, steer (the SDK's own mid-turn input, `whenBusy: "steer"`),
  interrupt (`abort`), configure and close.
- `turns.js`: folds what the conversation shows into the host's events. It
  runs `default-agent/src/projection.mjs`, the server's own projection of a
  Pi Durable conversation, unchanged, and finishes each message, thinking
  block and tool call once, in order.
- `platform.js`: the Web APIs the SDK needs (timers, URL, TextEncoder, crypto,
  AbortController), backed by Swift.
- `inference-stream.js`: hands pi-ai's stream to the native inference closure
  and ends it with an error if the closure fails.

Node built-ins the shared `default-agent` modules import in code the bundle
never reaches stay external; the build fails if any survives tree shaking.

## Host contract

`PiDurableRuntime` (Swift) opens a `PiDurableSession` per conversation, under
`<directory>/<conversation id>/`. The SDK's log there is the conversation's
native log; reopening continues it. A run that a close or a relaunch cut short
is settled as aborted on open, not continued: the host has saved that turn as
stopped, and the next message starts a turn. The directory takes an exclusive lock, and its files are fsynced before a
commit is published. Credentials never enter JavaScript or the log: the
inference closure receives pi-ai's `{model, context, options, scope}` and emits
pi-ai events. Tools are the host's closure, except `ask_user`, which surfaces
as a prompt the person answers. Tests (`swift test --package-path ios`) use a
stand-in model and never call a provider.
