# Long-reply scrolling investigation

## Current response selection

Assistant responses now use one read-only, selectable AppKit text view per
message. Paragraphs, headings, lists, quotes, code and native table cells share
one text storage, so dragging or Select All can cover the entire response. A
compact Copy button below each response copies its complete displayed Markdown;
assistant commentary in the work transcript uses the same component. Selection
is preserved when streamed text grows. Link filtering and confirmation remain.

The outer conversation stack remains lazy, with stable message, changed-file
and media anchors. The four-block SwiftUI grouping described below is historical:
it broke continuous response selection. The native response has one text view
instead of the large SwiftUI layout/focus tree measured in that investigation.
The historical timings do not measure the current native renderer.

## Native response scroll audit (PR #107)

The selectable response still has one text storage and one text view. Its native
backing frame now follows only the visible part of the outer transcript; the
wrapper reports the complete response height to SwiftUI. Text layout and selection
stay in document coordinates. There is no additional scroll view. This prevents a
long response from requiring a full-height native backing surface while scrolling.

Decoration ranges are collected when content changes, and drawing visits only
ranges intersecting the dirty viewport. Width/height measurements are reused until
content, streaming state or width changes. AppKit does not independently resize
the frame owned by SwiftUI. The existing lazy rows and stable file/media anchors
remain intact.

A provider-free fixture used the production `DashboardCloudConversation`, eight
synthetic messages totaling 31,296 characters, and prepared rich Markdown with
headings, lists, quotes, code, tables and links. Both renderers used the same Debug
configuration on macOS 27.2 (26B5091g), Xcode 27.0 and 768-point window height.
The native clip advanced 64 points, waited 16 ms and reversed at an endpoint for
12 seconds. The fixture set user scroll ownership before replay so initial
bottom positioning could not distort the run. Timing excludes the first two
seconds. Baseline and candidate runs alternated to reduce machine-load effects.

These are **main-actor replay intervals, not frame times or FPS**. The desktop
numbers are medians of two runs; narrow numbers are medians of three. Small
changes and universal performance guarantees are not established by this sample.

| Window width | Renderer | p95 interval | p99 interval | Maximum observed | Main CPU per step |
| --- | --- | ---: | ---: | ---: | ---: |
| 1305 | Previous four-block renderer | 24.02 ms | 27.82 ms | 30.72 ms | 5.65 ms |
| 1305 | Selectable native viewport | 18.29 ms | 18.34 ms | 19.16 ms | 6.79 ms |
| 480 | Previous four-block renderer | 24.17 ms | 28.57 ms | 32.43 ms | 5.67 ms |
| 480 | Selectable native viewport | 18.35 ms | 18.49 ms | 18.99 ms | 6.16 ms |

The native viewport improved tail cadence in this replay, with about 20% more
main-thread CPU at desktop width and 9% more at narrow width. It is a scroll-pacing
tradeoff, not a claim of reduced CPU consumption. No interval exceeded 50 ms.
A single 31,180-character response had a maximum interval of 18.42 ms. A
39,052-character conversation with the long reply initially offscreen had a
39.42 ms maximum including its initial realization, again without a 50 ms gap.
The final replays reached both endpoints and retained zero unexplained clip
coordinate corrections. Lazy offscreen height estimates still vary; these tests
do not prove all wheel/momentum behavior or every history/streaming scenario.

Native regression checks cover width round-trips, streamed height invalidation,
SwiftUI frame ownership, clipped code-box painting, bounded native viewport size,
logical text coordinates, visible glyph coverage matching a full rendering, and
selection/copy of offscreen text. Native selection, table cells and safe-link
confirmation remain covered. Temporary fixture and profiling hooks are excluded
from shipped sources.

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
