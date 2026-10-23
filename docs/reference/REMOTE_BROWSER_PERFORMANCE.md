# Remote browser performance

The shared remote browser uses a continuous authenticated image stream, with a
30 fps capture target. Image arrival is independent of WAN round-trip latency.
The native viewer reads the latest image from its connection owner at up to
30 Hz. Slow links apply backpressure before another image is captured; a stalled
connection is closed. Neither the owner nor the frontend keeps a playback queue.

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
retried. Clipboard text is copied only after an explicit acknowledged Copy.

Identical JPEGs are suppressed on the network. Heartbeats renew the captured
frame identity every two seconds, without retransmitting the image. The native
viewer skips unchanged-image decoding and redraws. JPEG validation/decompression
runs off the main actor; AppKit receives a prepared CGImage. Idle feeds expire within four seconds of their last read completing; an initial
image read has a ten-second timeout. Credential revocation closes the owner's
feeds immediately. The stream has a four-viewer limit, bounded image and
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

Observed on an Apple Silicon Mac, October 23, 2026, locked Playwright 1.64.1:

| Simulated RTT | Serial 30-key burst, median | Batched burst, median | Previous image schedule | Live stream |
| --- | ---: | ---: | ---: | ---: |
| 0 ms | 12 ms | 11 ms | 4.3 fps | 30.0 fps |
| 50 ms | 1,662 ms | 68 ms | — | — |
| 100 ms | 3,165 ms | 127 ms | 2.3 fps | 30.1 fps |
| 200 ms | 6,170 ms | 234 ms | 1.6 fps | 30.0 fps |

Each keyboard figure is the median of three 30-key bursts; the fixture verifies
all 30 characters arrived. Frame rates are measured over approximately three
seconds per mode. A five-second static-page stream transferred 22,555 bytes,
including its one full initial image and heartbeat metadata. Standalone capture
cost was 33.5 ms median / 34.5 ms p95 across 30 captures. These are transport
measurements, not end-to-end Mac display latency or guarantees for every page,
remote CPU, resolution or network. The initial stream handshake and SSH readiness
are outside the steady-state frame-rate measurement.

Regression coverage includes authenticated service routes, background-tab input,
partial-batch failure/replay rejection, stale frames, bounded streaming parsing,
backpressure, disconnect cleanup, late-frame rejection, metadata-independent image
refresh, unchanged image reuse, frame-feed expiry and credential revocation.
The opt-in native fixture exercises the production AppKit input view through the
HTTP batch and live-stream clients against actual shared Chromium, including IME
text. Container smoke tests repeat stream and batch checks on fresh and preserved
homes. Hosted CI and Trey's live workspace acceptance remain separate checks.
