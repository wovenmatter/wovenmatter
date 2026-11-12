# Conversation streaming

The transcript follows T3 Code's chronological work log: commentary stays where
it was emitted, contiguous thinking/tool activity becomes a compact disclosure,
and the final answer remains a native selectable response with Copy. Only an
expanded work group gets a bounded inner scroll view. Completed work folds under
its duration; interrupted/failed work remains inspectable.

Execution checklists appear above the composer, using the harness's own steps,
identities and statuses. They disappear when the run settles. Proposed plans
remain separate transcript content. A checklist control call is hidden only when
there is a normalized replacement, and failed controls remain visible. Providers
that do not emit checklists do not get invented progress.

## Live state

A window holds one connection to its own background server and follows each
open chat there (`backend.stream`, see
[Woven everywhere](architecture/WOVEN_EVERYWHERE.md), "Streaming"). Live text
of a message already shown is applied as it arrives; anything else is read
again from the window's read-only projection. A chat another Mac or a Linux
host runs is relayed from the background server's member-signed stream to that
machine and renders in the same view; while that machine is unreachable the
chat shows the history library sync brought, with an offline notice. Nothing
polls for a transcript, questions, approvals or settings.

## Storage and rendering

- Canonical native/wire captures remain in the central SQLite database. The
  desktop activity index is a disposable compact read model, not the archive.
- A revision clock, invalidation triggers and tombstones support incremental
  activity refreshes, including corrections/deletions in retained older runs.
  Older-page loads reconcile with the current presentation before application.
- Markdown, merged timelines and file-change counts are prepared off the main
  actor. Compact file-change records omit diff bodies; opening a diff loads its
  owning activity's full data.
- Tool details load on expansion and actual scroll visibility. Visible live
  details refresh; collapse/offscreen cancellation stops those full reads.
  Settled details use a bounded in-memory cache keyed by all contributing
  record revisions. Large text details are paged.
- Sending explicitly returns to the newest reply. Reading/expanding older work
  suspends following, and Latest reply returns to the stream. Response selection
  survives updates only while its selected source text is unchanged.
- The active-chat sweep draws into a canvas rather than animating child layout.
  Reduce Motion continues to suppress the sweep through the shared activity
  presentation.

The paragraph-stability rule was adapted from T3 Code; attribution and the MIT
notice are bundled in `app/App/ThirdPartyNotices.txt`. Reference source examined:
`t3dotgg/t3code` commit `611132c171f3a821bd2e32f22261135cef6330ac`.

### Response selection

Responses and assistant commentary use one read-only AppKit text view for
continuous selection across Markdown blocks, plus a bottom Copy button for the
complete displayed Markdown. Streaming preserves selection; links still require
confirmation. The outer lazy stack keeps stable message, file and media anchors.

A 256-point buffer bounds the native backing to the outer viewport plus 512
points, clipped to the response. Small scrolls reuse it; width changes and content
shrinking update it. Text storage and selection retain full document coordinates
without a nested scroll view. Measurements and decoration ranges are cached.

## Performance logging

Debug builds emit metadata-only `ConversationPerformance` unified logs with
read and preparation/application durations, summary counts and full-decode
counts. They contain no message text or identifiers. Filter with:

```sh
log stream --style compact --level debug \
  --predicate 'subsystem == "wovenmatter.desktop.dev" AND category == "ConversationPerformance"'
```
