# OpenClaw 2026.9.2 integration upgrade

Protocol baseline: OpenClaw tag `v2026.9.2`, commit
`3928bad9badfcb6c7d140530435e806fb8092190` (Gateway protocol v4).
Woven Matter base: `dc39c49620f1f0777acb2be0d713fe85507d5607`.

## Implemented

- Stable Ed25519 device identity and issued device token in macOS Keychain,
  scoped to the enrolled Gateway, with separate Dev/production services.
  A remote workspace's enrollment identity survives changing SSH-forward ports.
  Keychain failures are visible; they do not silently create a new identity.
- Bounded handshake, negotiated payload checks, idle watchdog, background
  reconnect/backoff, event-sequence gap recovery, and stale-connection fences.
  `hello.features` remains discovery metadata rather than an RPC allowlist.
- Shared native session discovery with pagination and idempotent import. Import
  keeps the native session key, including non-default agents; it does not copy
  the chat or send a prompt. Existing ACP compatibility remains unchanged.
- Session subscriptions and bounded transcript snapshots, including manual
  earlier-page loading. SQLite retains stable entry/display-row anchors and raw
  content, reconciles local optimistic rows, and avoids rewinding live output.
- Gateway-owned runs remain recoverable when Woven closes. Recovery observes
  the shared session without resending input. Missing liveness is unknown, not
  idle; unconfirmed delivery is not labeled successful. Another client's run
  cannot be attached to our pending input merely because it is active.
- Session-scoped pending approval replay, ordinary question forms, five-second
  inbox refresh, one-time allow/deny, and receipt probing after uncertain question
  delivery. Decisions are bound to the captured enrollment/session/generation.
  No automatic answer or approval write retry is introduced by the inbox.
  Requests without a live in-conversation presenter remain pending rather than
  being automatically denied.
- Agent-scoped configured/prepared model discovery, model-specific thinking
  options, slash-command argument hints, Fast/reasoning/verbosity/usage actions,
  and explicit per-field reset to agent defaults.
- A credential-free browser handoff to OpenClaw Control UI for richer media,
  account management, and plugin screens. Browser authentication is independent;
  Woven never puts a Gateway token into the browser URL.

## Deliberate boundaries and remaining parity work

This is a substantial integration upgrade, **not a claim of 100% native parity**.

- History refresh uses a recent 100-row snapshot; older rows are loaded on
  demand. Cursor-based full catch-up, reset/compaction branch reconciliation,
  and an offline delivery outbox remain future work. Numeric page offsets are
  not persisted as durable cursors. Already imported older rows remain local.
- Incoming media is retained as raw Gateway content with an explicit Control UI
  fallback, not downloaded/rendered natively. Native artifacts, audio/video,
  Mermaid, and hosted plugin rendering remain outstanding.
- The inbox is session-scoped, not a global all-Gateway notification center.
  Secret-store questions, standing grants/allow-always, and native account
  switching remain in Control UI. The Gateway still validates every decision.
- Existing local/Buzz/remote enrollment and launch behavior is retained. This
  does not silently attach to or reconfigure Eddie, migrate accounts, or replace
  existing Gateway credentials. Remote startup retains its existing explicit
  credential-access workflow.
- Cron/heartbeat administration is unchanged. A browser link is not embedded
  Control UI and is only offered when a safe URL is available.

## Validation and review

### PR #38 follow-up code review (2026-09-09)

Reviewed the complete PR from `dc39c49` through `dd2efa5` against the pinned
OpenClaw source above, then addressed these findings:

- **P1 — stale transport authority:** an explicitly retired client could reopen,
  and controls captured before a WebSocket reconnect could still mutate the
  session. Retirement is now permanent; decisions, settings, and Stop are bound
  to the exact connected transport as well as the enrollment generation. Old
  history callbacks and session-list responses cannot update a replacement link.
- **P1 — incorrect recovered output:** tool results could claim an optimistic
  assistant row or prove successful delivery. Reconciliation now distinguishes
  native tool/synthetic records from actual assistant responses. Contradictory
  in-flight metadata is not considered idle.
- **P1 — steering recovery:** follow-up remote input IDs were only in memory;
  restart/history refresh could duplicate messages or attach an earlier reply to
  the latest assistant. Input-to-message mappings now persist transactionally,
  recovery checks the latest input, and uncertain steering delivery enters
  observation without resending. Receipts must identify the supplied input.
- **P2 — partial history pages:** page-local sibling ordinals changed identity
  when a byte-bounded page started halfway through a transcript record. Canonical
  projection-content identities now remain stable across overlapping pages.
- **P2 — import integrity and authorization:** denied history left a phantom
  conversation, history reads unnecessarily required approval-management scope,
  and concurrent/archived imports could duplicate a shared session. History is
  fetched first without approval privileges; the existing-session check is now
  transactional and an explicit reimport restores the archived conversation.
- **P2 — inbox state:** an old poll could repaint resolved decisions, question
  drafts were indexed by list position, and multi-select free text discarded
  selected options. Polls are revision-fenced, drafts follow request IDs, and
  ordinary question answers preserve both selected and permitted free-text values.

Regression coverage includes retired clients, same-enrollment transport changes,
partial sibling pages, mixed question answers, denied/least-privilege imports,
concurrent imports, tool-only recovery, and exact steering rows after database
reopen. The full provider-free suite passes (117 Swift tests and 11 remote tests),
along with static checks, the macOS Debug build, and native bundle validation.
This audit does not establish live Eddie acceptance or a rendered live inbox;
the existing manual acceptance checklist below still applies. No merge, release,
Gateway configuration change, provider turn, or production installation occurred.

Run `scripts/test-changes.sh --all`. Tests use fake sockets, in-memory credential
stores, temporary SQLite databases, and existing local harness fixtures. They
must not contact model providers or read production Gateway credentials.

The added tests cover durable identity/token reuse, incomplete feature lists,
silent-handshake timeout, sequence duplicate/gap handling, raw media retention,
sibling identity, terminal errors, missing liveness, unsafe browser URLs,
idempotent import/reopen, live-text preservation, unknown delivery, and stale
origin rejection. Existing ACP and remote harness tests remain in the full run.

The Dev app was built/launched and its OpenClaw settings inspected. No Gateway
was linked in the inspected workspace; live controls and real Eddie acceptance
are not established by these checks. No provider turn, Gateway restart, account
change, release, or production installation was performed for validation.

Before merge, review on a deliberately selected test Gateway:

1. Link it, restart Woven, and confirm the same device identity remains paired.
2. Import an existing non-default-agent session twice; confirm one Woven chat.
3. Exchange messages from both clients; disconnect/reconnect Woven mid-run and
   confirm no duplicate send and no incorrectly successful unknown delivery.
4. Reopen Woven during an active run; verify resumed history, completion, and stop.
5. Request an approval/question before opening the controls; verify backfill,
   remote resolution, expiry, and refresh after a lost response. Relink while a
   decision is open; verify the stale decision is rejected.
6. Check model/thinking, argument hints, Fast/reasoning/usage changes and default
   reset against OpenClaw, then inspect the controls at narrow and wide sizes.
7. Load older pages and check raw media fallback and independent Control UI login.

Authoritative source contracts at the pinned OpenClaw tag:

- `docs/gateway/clients.md`
- `packages/gateway-protocol/src/schema/{frames,logs-chat,sessions,sessions-list,sessions-row}.ts`
- `packages/gateway-protocol/src/schema/{approvals,questions,commands,agents-models-skills}.ts`
- `src/gateway/server-methods/{chat-history-handler,sessions-subscriptions,approval,models}.ts`
