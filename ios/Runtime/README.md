# On-device Pi Durable

The app bundles the actual `@earendil-works/pi-durable`, `pi-ai`, and `chord`
1.0.3 packages already locked in `default-agent/package-lock.json`. It does not
ship Node, run a remote agent loop, or download executable SDK code. Rebuild
with `node scripts/build-ios-pi-runtime.mjs`; use `--check` to verify committed
resources match the reviewed sources and installed locked dependencies.

`PiDurableRuntime` serializes the SDK on JavaScriptCore. Swift provides secure
random bytes, UTF-8, schema URL resolution, timers, a private filesystem, and
asynchronous inference/tool capabilities. The filesystem exposes only that
conversation's directory, excludes symlink escapes, takes an exclusive writer
lock, and fsyncs journal files and directory entries before exposing commits.
Upstream `JsonlStorage` owns transaction markers, torn-write recovery,
checkpoint replay, and interrupted-tool behavior.

## Native contracts

The Swift `Inference` closure receives normalized pi-ai `{model, context,
options, scope}` JSON and emits normalized `AssistantMessageEvent` JSON.
The native provider service owns credentials and HTTP. Secrets never enter
Pi Durable's JavaScript heap or persisted transcript. Inference scope combines
the SDK's persisted provider session identity with a digest of the exact request;
children and compaction do not share a mutable request scope. SDK streaming
and tool execution remain on the device.

The Swift `Tool` closure receives `{name, arguments, conversationID,
nativeConversationID, taskID, toolCallID}` and returns upstream
`ToolExecutionResult` JSON. App tools must enforce grants/approvals and honor
Swift task cancellation. They default to unsafe replay: interrupted side
effects are reported as interrupted, not blindly repeated.

`open()` is a read-only execution viewer after its migration/configuration
commits; it does not schedule saved work. `resume()` explicitly enables the
scheduler. `submit(text:requestID:)` durably admits input and returns its receipt.
A caller must persist its request ID **before** submitting and recover a lost
acknowledgement through `submission(requestID:)`; retrying an existing request
ID never submits twice. `wait` returns a settled receipt for both successful
and unanswered runs. `unanswered` must not be presented as completed.

`abort()` is a durable user Stop and cascades through owned children.
`close()` suspends pending work without cancelling the durable run; reopen a
new instance to view/resume it. App suspension and explicit user Stop are
separate operations. No mobile background execution guarantee is made.

`snapshot()` is active UI context, which can omit compacted/reset history.
`conversations()` and paginated `history(nativeConversationID:cursorJSON:)`
provide the complete immutable records for central synchronization, including
children and old context. Runtime checkpoint files stay on the execution device.

## Subagents and code mode

The built-in `subagent` tool creates a real SDK task-owned conversation. It
inherits the parent's exact inference model/account and native tools, returns
its final result to the parent, cannot spawn further children, and stops with
the parent. Ownership and stable request IDs recover the same child after a
restart. Four children may execute concurrently.

The built-in `codemode` tool runs model-authored JavaScript in a separate WebKit
Web Worker. It never evaluates that code in the privileged SDK JavaScriptCore
context. An ephemeral WebView has no navigation or network access (CSP blocks
connections, frames, images, forms and external scripts). Only allowlisted
native tools cross the message bridge. Each nested tool is admitted as a real
SDK ToolTask before its side effects execute. Worker cancellation/timeout
terminates the worker and settles nested work. The default total limit is two
minutes; model code has no process or direct filesystem capability.

Code mode supplies `tools`, `ALL_TOOLS`, `text()`, `store()` and `load()`.
Stored JSON is committed to the conversation after a successful invocation.
The code tool is not replay-safe; a process death during execution cannot
re-run unknown side effects. Output and tool argument sizes are bounded.

## Verification

`swift test --package-path ios --filter PiDurableRuntimeTests` runs the actual
JSC SDK and isolated WebKit code worker on macOS without provider services.
Checks cover native tool and inference integration, durable receipt recovery,
unsafe-tool interruption, persisted user Stop, ownership locking, torn journal
recovery, subagent inference isolation, nested durable tools, blocked worker
network/native access, and termination of an infinite loop.

The iOS app includes the same package/resources. Simulator/device builds and
app-level acceptance are separate from portable runtime tests. Real provider
acceptance uses the user's explicitly selected configured account.
