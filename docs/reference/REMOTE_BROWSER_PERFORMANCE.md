# Remote browser performance

The shared remote browser uses Chromium's change-driven `Page.startScreencast`
through the existing authenticated image stream. It captures changed pages at
about 60 fps in the animation fixture, without a repeated screenshot loop on
static pages. Multiple viewers of one page share the same capture session.
The native viewer reads the newest image at up to about 60 Hz; when nothing
changes, its owner waits for a frame instead of repeatedly returning empty replies.
Image arrival is independent of WAN round-trip latency after stream establishment.
Slow receivers retain only the newest pending image; a stalled connection is
closed. Neither the owner nor the frontend keeps a playback queue.

The owner reuses the active viewer's authenticated service client rather than
performing an SSH/HTTP health probe for every image or gesture. Credential and
workspace identities are still checked before and after each operation. Images
and input omit administration snapshots and bypass command replay storage.
Tab metadata runs separately, once per second, so a slow title lookup cannot
block images or input. Chromium control sessions are reused per page.

Input sends immediately. Input that accumulates during an acknowledgement is
sent in order in batches of at most 32 gestures, with bounded bytes and a five
second execution deadline. DOM keydown/keyup semantics are retained. Navigation,
a stale frame or any failure stops the remaining batch; uncertain input is never
retried. Mouse-down, held movement and mouse-up reach Chromium separately, so
sliders and selections update during the gesture. Pending movement is coalesced;
clicks and keys retain their order. Continued drags use fresh frame identities
without losing their original gesture/document binding, so active drags can
outlast the 30-second frame expiry. Focus loss, dismissal, disconnect, navigation
and a 15-second pointer inactivity deadline release held buttons. Cancellation
remembers the gesture ID, so an overtaken press cannot arrive after cancellation.
Clipboard text is copied only after an explicit acknowledged Copy.

Identical JPEGs are suppressed on the network. Heartbeats renew the captured
frame identity every two seconds, without recapturing or retransmitting the image. The native
viewer skips unchanged-image decoding and redraws. JPEG validation/decompression
runs off the main actor; AppKit receives a prepared CGImage. Idle feeds expire within four seconds of their last read completing; an initial
image read has a ten-second timeout. Workspace update/removal closes the owner's feeds immediately; failed authentication terminates the stream. The stream has a four-viewer limit, bounded image and
parser sizes, and no redirects or disk cache. Closing a viewer leaves agent tabs
open. There is no Pause/Resume control.

## Reproduce

Install the locked dependencies and matching Playwright Chromium, then run:

```sh
PLAYWRIGHT_BROWSERS_PATH=/path/to/browser/cache node remote/test-support/browser-performance.mjs
```

The benchmark creates an isolated browser profile and removes it afterward. It
uses real Chromium with a local form and animated canvas; no provider services
or production workspaces are involved. It compares the previous serial request
schedule (tabs, screenshot, 200 ms sleep; one request per key) with the current
batch/stream transport. Both schedules use the current Chromium implementation,
so this comparison does not credit the optimized version for CDP-session reuse.
Network latency is simulated, with no packet loss or bandwidth cap.

Regression coverage includes authenticated service routes, background-tab input,
partial-batch failure/replay rejection, stale frames, bounded streaming parsing,
backpressure, disconnect cleanup, late-frame rejection, metadata-independent image
refresh, unchanged image reuse, frame-feed expiry and workspace identity changes.
The opt-in native fixture exercises the production AppKit input view through the
HTTP batch and live-stream clients against actual shared Chromium, including IME
text. Container smoke tests repeat stream and batch checks on fresh and preserved
homes. Hosted CI and Trey's live workspace acceptance remain separate checks.

To exercise the real native input path, run
`node remote/test-support/browser-native-fixture.mjs` with the same browser-cache
environment. Pass its printed loopback URL as `WOVENMATTER_BROWSER_INPUT_FIXTURE`
to `swift test --package-path app --filter RemoteBrowserViewerTests`. The fixture
verifies rapid consecutive clicks, keyboard/IME input, a slider changing before
mouse-up, cancellation release and image refresh on a background Chromium tab.
Set `WOVENMATTER_BROWSER_LONG_DRAG=1` to also exercise an extended real drag
beyond the 30-second frame expiry. Stop the fixture with SIGINT/SIGTERM; it closes its browser and removes its profile.

For the isolated native cost sample, add `WOVENMATTER_BROWSER_PERFORMANCE=1` and
filter to `measureNativeViewerWhenRequested`. It opens and closes one temporary
AppKit window and prints process CPU and resident memory for baseline, idle and
animation intervals. Run this test alone, without concurrent builds/benchmarks.
