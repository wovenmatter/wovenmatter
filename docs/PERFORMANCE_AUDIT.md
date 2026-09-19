# Everyday workspace performance

This audit uses the real native views and database with disposable, provider-free
fixtures. It compares ordinary light use with a larger workspace; the larger
case is a stress case, not a claim about a typical user's data.

## Reproduction

Run `scripts/profile-workspace.sh light [git-ref]` or
`scripts/profile-workspace.sh heavy [git-ref]` on macOS. Without a ref, the script
copies the current working tree. With a ref, it archives that exact revision.
The script injects diagnostic startup into the temporary copy, then uses the
repository build/launch script with the Performance development variant.

The temporary app skips normal startup and workspace ownership, asserts its
separate bundle identity, creates a unique temporary database and draft journal,
and does not start provider services, usage collection, runtime discovery, or
session restoration. Reopening the fixture also skips runtime discovery. Keep
interaction to fixture documents and chats; settings and actual provider sends
are outside this profiling workflow. The fixture source never ships in the app.

The light workload has 12 chats and 8 notes/assets. The heavy workload has 1,000
chats and 120 notes/assets. Both include short chats, a 240-message paged chat
with a 60-section final reply, activity transcripts, rich notes, spreadsheets,
and HTML. Light/heavy long notes have 30/300 paragraphs, spreadsheets 20/100 rows
and 8 columns, and activity turns 8/200 tool records. All data is synthetic.

Each fixture writes `.build/performance-evidence/trace-PID.csv` in the source
worktree (override with `WOVENMATTER_PERFORMANCE_EVIDENCE_DIR`) with
the delay of a 16 ms timer on the main run loop, in common modes. Mark an
interaction window with:

```sh
python3 scripts/performance-support/record-window.py begin TRACE.csv LABEL
# Exercise the native app.
python3 scripts/performance-support/record-window.py end TRACE.csv LABEL
```

The result reports maximum timer delay and counts above 16/50/100 ms. This is
run-loop scheduling evidence, **not frame time, FPS, or click-to-display latency**.
Tool transport and idle time do not become reported stalls. Accessibility queries
can themselves cause work inside the app, so these observations include the
accessibility inspection workload and are not isolated human-input latency.
Use the same interactions, accessibility reads, build configuration, window geometry,
and quiet compiler conditions for comparisons. Capture a process sample during
the action to distinguish view/layout work from decoding or idle time. Cold and
warm visits must be distinguished; absolute timings vary by host and OS.

## Native survey

Baseline: `51b592a61e99a10575516263bdd31dfb29646991`, Debug, native arm64, macOS
27.2. The September 19 survey covered short and long chats, activity expansion,
sidebar switching/search, short and long note editing, spreadsheet editing,
offline HTML, and note editing during a synthetic background response. No
concurrent builds ran during the measured windows. These are exploratory
single-pass observations with native accessibility inspection, not a repeated
statistical benchmark or end-to-end latency measurement.

| Heavy workload / interaction | Baseline maximum delay | Candidate maximum delay |
| --- | ---: | ---: |
| First open of 100 × 8 spreadsheet | 1,833 ms | 729 ms |
| Enter text in A2, Tab, enter text in B2 | 535 ms | 287 ms |
| Notes → Chats → search `Chat 099`, sheet open | 737 ms | 419 ms |
| Open long conversation from short chat, scroll up three pages | 605 ms | 546 ms |
| Open activity conversation, expand work and 200-file group | 260 ms | 255 ms |
| Open long note, edit end, open HTML preview | 232 ms | 195 ms |

The sheet/edit/sidebar observations use baseline trace 10316 and candidate
10067. The other candidate journeys use trace 11434. Raw CSVs, marked windows,
build logs, and candidate source hashes are retained in the worktree's ignored
`.build/performance-evidence` directory. Earlier pre-restart exploratory traces
were lost and are excluded from this table.

The candidate's light workload opened the 20 × 8 sheet with a 302 ms maximum
delay, edited adjacent cells with 153 ms, and opened/edited the short note with
133 ms. The light baseline comparison and repeat measurements remain pending.

The background-stream survey exercised 300 database chunks at 50 ms intervals,
with tool records and commentary boundaries, then opened and edited a note.
Both builds displayed incremental output and accepted note edits. Baseline and
candidate maximum delays were 178 and 246 ms respectively, but the baseline
window included extra stream invocations and inspection retries; these are
functional observations, not an improvement/regression comparison. Actual
provider timing, provider cancellation, startup discovery, network sync, usage
imports, and account operations are intentionally outside the fixture. This
audit does not claim that those paths are optimized or independently accepted.

The source explains the spreadsheet scaling cost: the eager grid creates all
800 text fields, including off-screen rows, and each binding read decodes the
whole document. Earlier process sampling identified SwiftUI/AttributeGraph
layout plus repeated decoding; its lost raw sample is supporting investigation
only. The current repeatable behavior and source review justify bounded document
reuse and row virtualization without attributing every delay to decoding.

The source review also found existing off-main conversation Markdown preparation,
lazy sidebar rows, revision-gated database snapshots, and a bounded conversation
cache. These remain useful and were not replaced wholesale with the old
performance PR's mechanisms. Long-message layout and background activity need
separate measurements from spreadsheet teardown.

## Candidate and validation

The candidate virtualizes fixed-width spreadsheet rows and reuses one
decoded document per open note pane. The document key is the exact source plus
note identity, so changes from another writer invalidate it immediately. Local
edits reuse their normalized encoded value. The cache cannot grow with the
number of previously opened notes. Journal, write-behind, and database mutation
semantics are unchanged.

The focused note-editor harness passes: unchanged reads decode once; legacy
block identity remains stable; local edits, external source replacement, and
note changes produce the correct document; and six actual AppKit
edit/parse/save/reopen and clear/reopen cases retain metadata and table links.
Candidate native checks also accepted edits in the last row of a 100-row sheet.
Read-only checks of the isolated SQLite databases confirmed that A100/B100 edits
and input after Tab crossed H19 → A20 persisted in the intended cells. The
viewport can leave the newly focused cell outside the horizontal view; a
baseline comparison is still required before calling keyboard validation done.
`scripts/test-changes.sh --all` passed, including the unsigned app build and
native bundle validation. The staged public-tree privacy scan, diff whitespace
check, shell syntax checks, Python parsing, and Bash override argument checks
also passed. The initial sandboxed full run could not launch its AppKit helper;
the same validation succeeded through the approved execution path.

The Mac locked before the final native comparison. Keyboard viewport behavior
against baseline, native reopen checks, and repeated light/heavy measurements
remain outstanding until it is manually unlocked. This is a draft candidate,
not final native acceptance or an integration/release approval.

The build script also handles an empty variant-override array under macOS Bash
3.2 with `set -u`. Empty and populated array expansion were checked explicitly,
including preservation of the product name containing spaces. This supports
reliable validation builds; it is not a runtime performance change.
