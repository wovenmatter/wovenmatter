# Long-reply scrolling investigation

## Current response selection (PR #107)

Responses and assistant commentary use one read-only AppKit text view for
continuous selection across Markdown blocks, plus a bottom Copy button for the
complete displayed Markdown. Streaming preserves selection; links still require
confirmation. The outer lazy stack keeps stable message, file and media anchors.

A 256-point buffer bounds the native backing to the outer viewport plus 512
points, clipped to the response. Small scrolls reuse it; width changes and content
shrinking update it. Text storage and selection retain full document coordinates
without a nested scroll view. Measurements and decoration ranges are cached.

### Recorded scroll audit

Provider-free Debug replay: eight messages, 31,296 characters, 768-point window
height, 64-point steps/16 ms waits, reversing at endpoints for 12 seconds; first
two seconds excluded and user scroll ownership set before replay. All renderers
were rebuilt on macOS 27.2 (26B5101f), Xcode 27.0. Two runs per renderer/width used
opposite order; values below are median p95/p99/CPU and maximum observed interval.
Sampled runs were excluded. These are scheduling intervals, not frame times or FPS.

| Window width | Renderer | p95 interval | p99 interval | Maximum observed | Main CPU per step |
| --- | --- | ---: | ---: | ---: | ---: |
| 1305 | Previous four-block renderer | 24.37 ms | 29.34 ms | 31.40 ms | 5.99 ms |
| 1305 | PR before buffer (`fa2d1ef`) | 18.44 ms | 18.56 ms | 22.56 ms | 5.17 ms |
| 1305 | Selectable native buffer | 18.50 ms | 18.69 ms | 28.31 ms | 4.88 ms |
| 480 | Previous four-block renderer | 24.78 ms | 30.45 ms | 32.75 ms | 5.99 ms |
| 480 | PR before buffer (`fa2d1ef`) | 18.49 ms | 19.02 ms | 30.70 ms | 5.34 ms |
| 480 | Selectable native buffer | 18.49 ms | 18.68 ms | 30.48 ms | 4.68 ms |

The earlier audit on 26B5091g measured 9–20% higher CPU for `fa2d1ef`; the OS
changed, so only the matched comparison above isolates buffering. Small differences
and universal performance gains are not established. Buffered replays recorded
up to 64-point lazy-height clip corrections (four-block desktop: 56 points).
Trackpad/momentum scrolling, initial positioning, retained/prepended history and
selection while streaming remain manual acceptance. Native tests cover selection,
link safety, sizing, clipped painting and viewport coordinates; benchmark hooks
are excluded from shipped sources. The four-block investigation below is historical.

## Historical four-block investigation

Rapid scrolling through a retained eight-message conversation (approximately 27,000 characters) repeatedly paused at the same content boundaries. History pagination was inactive: the app already had all eight messages. Prepared Markdown parsing was off the main thread and did not appear in the long stalls.

## Cause and change

The outer lazy stack treated a complete assistant reply as one child. Realizing a long reply required a large SwiftUI layout and accessibility-focus subtree at once. Native CPU traces showed repeated 119–137 ms main-actor scheduling gaps at the same scroll offsets, including up to 76 ms of internal focus-responder traversal in one gap. Those stalls contained no samples attributable to incoming accessibility RPCs, database work, or periodic tool refreshes.

The previous fix exposed groups of at most four existing top-level Markdown blocks as direct lazy children. Lists, quotes, code fences and tables remain intact and use the existing renderer. Group identities derive from the owning message and starting block ordinal. The first group keeps the original message anchor; work appears once, media remains ordered, and a dedicated stable changed-files row retains disclosure/diff state as streaming appends groups. No text is reparsed by the layout planner.

A separate no-op tool-snapshot publication issue was fixed in PR #61. That removes avoidable background invalidations, but was not the cause of the repeated content-boundary stalls.

## Controlled comparison

The same Debug build configuration (Swift `-Onone`), 1305×768 native window and retained conversation were used on macOS 27.2 build 26B5086k with Xcode 27.0. A disposable in-app harness advanced the actual transcript clip view 64 points per step, waited 16 ms, reversed at either end and stopped after 12 seconds. Time Profiler sampled the app. One native click started each run; no accessibility inspection occurred during the replay. Results below exclude the first 2 seconds to remove click/setup overhead.

These are main-actor replay scheduling intervals, **not display frame times or FPS**. Samples are one run per configuration, so small differences are not statistically established. The replay exercises native layout but does not simulate all wheel/momentum behavior.

| Lazy child size | Steps | p95 interval | p99 interval | Maximum | Gaps over 50 ms | Main CPU per step |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Entire reply (baseline) |537|18.20 ms|38.50 ms|136.91 ms|5|7.46 ms|
| One Markdown block |569|18.62 ms|25.55 ms|42.29 ms|0|8.84 ms|
| Two Markdown blocks |566|19.73 ms|26.75 ms|28.99 ms|0|7.96 ms|
| Four Markdown blocks (selected) |553|23.66 ms|30.97 ms|36.06 ms|0|7.30 ms|

Four blocks retained the large-stall improvement with essentially baseline CPU per step. Two blocks had tighter tail cadence but did more sustained work. At the former repeated 6336→6400 point boundary, baseline intervals were 136.91/135.85 ms; four-block intervals were 17.02/17.25 ms. Maximum focus traversal within an interval fell from 76 ms to 10 ms. All configurations reached both ends and revisited the relevant boundaries.

An eager outer stack also removed the large stalls but performed more sustained whole-tree work and would scale poorly with history; it was rejected. Removing the scroll-position binding or the existing vertical fixed-size modifier did not resolve the mechanism.

## Limits and regression coverage

SwiftUI still estimates offscreen heights. The one/two-block replays showed large document-coordinate corrections during initial realization; four-block corrections were limited to approximately 126–184 points, with a stable final document extent. Coordinate changes alone do not establish visible content jumps; native history, initial-position, direction-change and latest-reply checks are required alongside timing.

A single enormous paragraph, list, quote, code block or table is still one atomic block. This change does not promise a universal layout-cost bound, perfect frame pacing, or lower CPU for every conversation. It does not change provider polling, persistence, pagination limits or the history retention policy.

Provider-free layout tests cover rich-block coverage/order, grouped tail growth and appends, old-message anchors after prepending history, single header/footer ownership, empty/failed/pending fallbacks, media order, and safe-link filtering. Native build, combined integration checks and offline runtime acceptance are recorded in the PR validation. Temporary benchmark/fixture hooks and provider transcripts are excluded from shipped sources.
