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

Opening Built-in Settings requests cached/bundled catalog metadata using a
configuration-only helper request. It does not perform native sign-in status or
model discovery. Explicit connection refresh and completed sign-in still verify
connections. Cancelling passive status/discovery terminates its native work;
normal EOF remains a valid one-shot helper request boundary.

The model browser and default chooser display at most 40 controls per page.
Search covers the complete catalog, and every model remains reachable. Catalog
classification and row preference state are indexed outside row rendering.

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

## Validation boundary

This session deliberately runs no CI or test suites. Regression cases are added
for future main-branch validation. Native compilation and the shared Dev build
are the immediate delivery checks. Responsiveness during real Settings navigation,
account changes, long drafts, and tool-heavy conversations remains live acceptance;
no universal latency claim is inferred from source review.
