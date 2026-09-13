# OpenClaw 2026.9.4 integration upgrade

Verified against official OpenClaw v2026.9.4, source
`3a9d69db306cd7f081e06254cb89c4bcc14a7107` (Gateway protocol v4,
device signature v3). The filename retains the original review target for link
compatibility. This source review does not update an installed Gateway.

## Final scope

- Gateway identity and device tokens persist in Keychain. Shared token/password
  authentication remains distinct from device authentication. Handshakes,
  reconnects, idle watchdogs and stale-transport fences bound connection work.
- Local startup respects the selected configuration, port, authentication and
  Tailscale settings. Existing listeners are borrowed without process ownership;
  releasing the link does not stop them. Startup failures expose bounded,
  scrubbed diagnostics. Configuration and secret-store reads are read-only.
- Shared OpenClaw sessions remain in Settings. Previous/Next browsing uses 25
  sessions per page, at most 10 pages. Browsing never imports. Import buttons
  reuse the shared quiet hover style with compact sizing.
- Import fetches every available history page into private temporary files before
  one atomic database transaction. Native session keys and message dates remain
  intact, stable transcript anchors deduplicate rows, and reimport keeps one
  conversation. Changed multi-page transcripts fail with a retry message instead of partial success.
- New local OpenClaw chats use `sessions.create` with a session-specific `cwd`
  pointing at the configured shared Woven Matter root. The response must confirm
  that directory. Eddie's agent workspace, identity, defaults and imported sessions
  are not changed; REPOS and Databases continue through the shared root's links.
- Both local import lists exclude native Woven Matter sessions and already-linked
  session identities, deduplicate entries and fetch only enough eligible records
  for the requested page. Successful imports disappear from the list.
- Local OpenCode v2 imports retain the server connection/session ID and original
  location. Every message page is fetched before the association, complete snapshot
  and imported marker are committed together. A changed session or failed page
  leaves no partial import. New OpenCode sessions carry a native origin marker.
- Imported conversations display `(imported)` only beside the harness in the
  existing hover card. Stored import provenance survives restart and background
  refresh; native Woven Matter conversations are not relabeled.
- Native SQLite paging supplies older imported messages while scrolling. Separate
  import activity places old imports in Recents and survives scheduled history
  reconciliation without changing message timestamps.
- Gateway-owned runs recover without resending uncertain input. Missing liveness
  remains unknown; native run identity and exact input idempotency keys reconcile
  optimistic rows. Exact persisted input keys take precedence; provider-specific
  keys fall back to explicit Gateway run identity. Reconciliation repairs orphan
  history duplicates by native record identity while keeping local run references;
  unique native projections survive content revisions. Separate records are not
  merged merely because their text matches. Live output is protected from stale
  history.
- The existing composer retains model/thinking selection, prepared session-scoped
  model discovery, provider-qualified models, argument hints and stop behavior.
  Existing in-conversation permission handling retains its connection fences and
  does not automatically retry uncertain approval writes.

The additional OpenClaw session sheet and its sliders entry button have been
removed. Its settings/reset/stop controls, browser handoff, approval replay inbox,
question forms and polling were removed with their exclusively used APIs and
helpers. No replacement or relocated UI is included.

## Boundaries

Ongoing history refresh uses a recent 100-row snapshot after full import. Durable
delta-cursor background catch-up, reset/compaction branch replacement, offline
outbox, native rich media/plugin rendering, account switching and native question
management remain outside this PR. Raw Gateway media content is retained; upstream
projection and content limits still apply. This is not a claim of full native parity.

## Verification and acceptance

The existing `scripts/test-changes.sh --all` checks cover static/privacy checks,
remote tests, Swift tests, an isolated macOS Debug build and native bundle
validation. Tests exclusively covering the removed sheet APIs were removed;
transport, history, recovery and in-conversation approval coverage remain. No new
test infrastructure was introduced for these UI follow-ups. Focused duplicate
repair regressions cover provider keys, content revisions, steering precedence
and distinct same-text replies.

The manager previously verified local Link Gateway reaches Ready. The manager
owns shared Dev integration and live acceptance of the final head: browsing,
full import, original dates, scrolling, Recents, compact Import hover styling,
and absence of the session sheet/button. No main merge, release or deployment is
part of this task.

## Upstream references

- [Official release](https://github.com/openclaw/openclaw/releases/tag/v2026.9.4)
- [Protocol version](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/version.ts)
- [Connect authentication](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-client/src/connect-auth.ts)
- [Session-aware models](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/server-methods/models.ts)
- [Transcript identity](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/sessions/transcript-events.ts)
