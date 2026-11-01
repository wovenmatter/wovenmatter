# Settings and workspace responsiveness

The September 28 Dev investigation captured delayed button handling at integration
head `0dec43a`. The evidence identified several independent sources of work:

- Built-in/Connections entry reloaded ten providers before and after status, with
  two synchronous Keychain queries per provider on the main actor. The captured
  process log contained 537 main-thread `SecItemCopyMatching` events.
- All 7,548 invalid-width layout warnings in the captured five-minute interval
  originated in composer sizing. SwiftUI measurement proposals were assigned
  directly to the mounted AppKit view, including infinity and huge finite values.
- A process sample captured about 300 ms aggregate of main-thread database-lock
  waiting. A concurrent cron-history read held that lock while constructing and
  using date formatters for every stored run.
- Built-in Settings eagerly populated a native model picker and repeatedly
  derived row state from a catalog containing hundreds of models. Its automatic
  status request also performed native Claude status and model discovery.

Later September 28 samples of the updated Dev app captured 726 samples on initial
Built-in Settings entry and 1,900 on a repeated entry under synchronous main-thread
SwiftUI rendering. Those stacks included model-row construction, layout, and focus
work. The captured Keychain reads were on the background account actor, with none
on the main thread. These are sample counts, not precise elapsed milliseconds.

The first model-browser correction bounded a page to 40 rows but still placed
those rows inside eager section and row stacks. Each model row has two toggles
and two ordering buttons, so entering the page could construct 160 model controls
before the user scrolled to them. The follow-up changes those two stacks to lazy
stacks within the existing page scroll viewport. Pagination and catalog behavior
remain unchanged.

The signed Dev build at `9634251`, containing the lazy-row correction `5309b8c`
and SDK display change `eb7faaa`, compiled and launched successfully. Follow-up
entry samples captured 343 samples under synchronous click rendering on initial
entry, versus 726 before, and 237 on repeated entry, versus 1,900 before. No
main-thread Keychain reads appeared in those samples. These captures support less
render work on entry; they are not a controlled benchmark, and sample counts must
not be treated as wall-clock latency or a guaranteed speedup. A capture that missed
the entry click was excluded from this comparison.

Native inspection initially exposed a lazy model list; scrolling materialized the
row controls. Next moved the browser to models 41–80 of 421, an Opus 5.5 search
returned one matching model, and clearing the search restored models 1–40 of 421.
The SDK version disclosure also expanded and collapsed successfully.

These observations do not establish the duration of every reported stall, or
that the separate long-conversation slowdown has the same cause.

## Behavior after this change

Account display metadata is read and mutated through a background actor. Reads
share a scope/revision cache; returned values are fenced against cancellation,
scope changes, and newer credential revisions. Only display metadata is cached
there. Explicit refresh can request fresh metadata. Model preference changes have
separate notifications and revisions from credential changes, so they do not
trigger Keychain reloads and Usage refreshes. Credential renewal and explicit
connection verification retain their existing ownership.

Opening Built-in Settings shows enabled models and the configured or previously
resolved default. Entry does not start a catalog helper or initialize either SDK.
A compact metadata cache supplies names; missing names can be read from the
needed provider metadata files in the background. Local Claude alias versions
are accepted only from compatible local runtime metadata. Unknown implicit
defaults remain “First available model” until discovery resolves them.

“Browse all models” explicitly loads the full catalog. Opening the default-model
chooser does not load it; the chooser has its own explicit browse action. Page
entry and workspace changes return to enabled models even if a full catalog was
previously cached. Explicit connection refresh and completed sign-in still verify
connections. Cancelling passive status/discovery terminates its native work;
normal EOF remains a valid one-shot helper request boundary.

The model browser and default chooser expose at most 40 model rows per page.
The browser's section and row stacks defer native controls outside the scroll
viewport. After explicit browsing, search covers the complete catalog and every
model remains reachable.
Catalog classification and row preference state are indexed outside row rendering.

Composer measurement uses separate, reusable TextKit objects and finite viewport
widths. Sizing probes do not alter the mounted editor, selection, or native text
container. Installed layout and measurement share the same height calculation,
including trailing blank lines and the existing visible-line limit.

Scheduled-job presentation initially reads 50 runs per job, with explicit access
to older runs. Durable collection and deduplication retain their full-history
semantics. Date codecs are reused under their own lock. Presentation reads,
receipt pagination, and policy-cache population run off the main actor and reject
stale results. Rendering a note-edit affordance no longer calls SQLite.

This is a targeted correction to measured presentation paths. It does not replace
the entire SQLite ownership model; remaining synchronous scheduler mutations are
part of the separate asynchronous-database work.

## Follow-up Settings sanity pass

Three further changes remove identifiable repeated work:

- `094b275` retains one main-actor catalog metadata index across page entries,
  reused only when every model field and its ordering match. Account, preference,
  filter, and selection state are not shared in this memo.
- `1569996` coalesces matching catalog requests already in flight. `27337c9`
  clears that request state on cancellation, errors, and completion, including
  when a superseding configuration resolves from the catalog cache.
- PR #89's `aa4ff36` skips publication of unchanged SDK polling results. This was verified by source
  review, not a live polling stress benchmark.

The signed Dev build `8ab8e1b` compiled and launched successfully. A repeated-entry
sample captured 239 samples under synchronous click rendering, versus 237 in the
preceding build: this does not demonstrate an overall latency improvement. The
repeated catalog/lab classification previously represented by 17 samples was
absent, as were model-row construction frames on entry.

Manual checks covered SDK version expansion/collapse, the 421-model catalog,
an Opus 5.5 search returning one match and clearing back to 421, opening/cancelling
the default chooser, and switching All workspaces → Local → All workspaces until
each scope settled. These checks did not modify drafts or saved preferences and
did not run inference. Source/diff review passed; no CI, test suites, or session
timers were run for this pass.

## Explicit catalog browsing

The enabled-only follow-up is owned by PR #87 commits `83aadf0` and `d420b63`.
The signed Dev build `8f128674a72aa9082d02b04e68cb5c7228dc48a1` compiled,
passed code-signature verification, and launched successfully.

Native inspection verified six enabled models on initial page entry and in the
unopened-catalog default chooser, including Opus 5.5. Explicit browsing from the
chooser exposed all 421 models. Full-catalog search for Opus 5.5 returned one
match; “Show enabled models” cleared the filters and returned to six models.
Leaving and reopening the page, and switching All workspaces → Local → All
workspaces, each returned to the six enabled models. These checks left saved
model preferences unchanged and restored All workspaces with the enabled list.

Source review verified that entry and chooser opening do not launch the catalog
helper. The backend publishes only the selected projection, including the
intermediate scope-change snapshot. Small metadata reads and per-scope cache
serialization run off the main actor, with cancellation and scope guards. Cached
Claude alias names are revalidated against local runtime metadata; local aliases
never establish a remote runtime's model version. Full discovery, explicit
connection refresh, and existing runtime selection remain separate operations.

This pass verifies deferred work and the native UI behavior. It does not add a
controlled latency benchmark or live remote/provider acceptance result. No CI,
test suites, provider inference, account authentication, or session timers ran.

## Validation boundary

This session deliberately runs no CI or test suites. Regression cases are added
for future main-branch validation. The signed Dev build, entry profiles, and native
scrolling, pagination, search, and disclosure checks above are the completed
delivery checks. Broader responsiveness during account changes, long drafts, and
tool-heavy conversations remains live acceptance; the targeted entry evidence
does not establish a universal latency guarantee.
