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

## Cost and scope

There are no new GPU, video, or networking dependencies. Chromium runs in the
remote workspace and starts when an agent connects; capture starts only when a
viewer subscribes and stops with its last subscriber. The Mac receives JPEGs
and sends input; it does not launch another local browser for this viewer.

A five-second static-page probe on the same Apple Silicon Mac measured the
Node service plus its Chromium descendants at **31.2% of one CPU core** with the
previous screenshot loop and **0.6%** with change-driven capture. The no-viewer
baseline was about 0.4%. These short process-tree samples use cumulative CPU time
from `ps`, are noisy near zero, and are not Linux-host guarantees.

The opt-in native benchmark measures the production HTTP stream, frame feed,
off-main image decode, viewer model and AppKit canvas in a real 1280×800 window.
A debug Swift test process used **1.0% of one core idle**, and **11.8% while drawing
268 animated frames over five seconds** (about 54 fps). Resident memory was
46 MiB before opening the viewer, 96 MiB idle and 96 MiB after animation. This is
a short isolated test-process measurement, not whole-app resource usage; it
excludes WindowServer, remote Chromium, SSH/TLS and the backend-owner RPC hop.
Offscreen bitmap screenshots are deliberately excluded: their software drawing
cost substantially overstates this window path. No byte-accurate app bundle size
or deployed-workspace cost claim is made.

WebGPU would not remove capture, transport, JPEG decoding or round-trip delays.
A hardware video codec could reduce bandwidth for sustained motion, but would
add encoder/decoder negotiation and recovery complexity. Measure real WAN input
latency and bandwidth before adding that transport. The current ordered input
path still waits for each batch acknowledgement, so a high-RTT drag cannot have
local-browser response time even when incoming images remain smooth. This is
not a claim of native latency, display-vsync performance, audio streaming or
video-conferencing quality.

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

Observed on an Apple Silicon Mac, October 25, 2026, locked Playwright 1.64.1:

| Simulated RTT | Serial 30-key burst, median | Batched burst, median | Previous image schedule | Live stream |
| --- | ---: | ---: | ---: | ---: |
| 0 ms | 12 ms | 11 ms | 4.3 fps | 60.2 fps |
| 50 ms | 1,660 ms | 68 ms | — | — |
| 100 ms | 3,122 ms | 114 ms | 2.3 fps | 60.2 fps |
| 200 ms | 6,162 ms | 215 ms | 1.6 fps | 60.0 fps |

Each keyboard figure is the median of three 30-key bursts; the fixture verifies
all 30 characters arrived. Frame rates are measured over approximately three
seconds per mode. A five-second static-page stream transferred 22,139 bytes,
including its one full initial image and heartbeat metadata. Standalone capture
cost was 33.1 ms median / 34.2 ms p95 across 30 captures. These are transport
measurements, not end-to-end Mac display latency or guarantees for every page,
remote CPU, resolution or network. The initial stream handshake and SSH readiness
are outside the steady-state frame-rate measurement.

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
