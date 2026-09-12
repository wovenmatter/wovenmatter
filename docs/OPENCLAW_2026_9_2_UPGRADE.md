# OpenClaw 2026.9.4 integration upgrade

Protocol baseline: OpenClaw tag `v2026.9.4`, commit
`3a9d69db306cd7f081e06254cb89c4bcc14a7107` (Gateway protocol v4).
Woven Matter base: `cc6d2882c11239623c7f0925bf8db481a4a6985a`.
The historical filename is retained for existing review links.

## Current stable compatibility review (2026-09-12)

The official release API reports **v2026.9.4**, published 2026-09-11 at
03:46:22 UTC, as the latest stable feature release. The separately maintained
v2026.6.35 release is the June extended-stable line, not a newer feature baseline.
Source was fetched directly from the official repository over SSH and checked
out at **3a9d69db306cd7f081e06254cb89c4bcc14a7107**. Compared with v2026.9.2
(3928bad9badfcb6c7d140530435e806fb8092190), Gateway protocol remains **v4** and
the signed device challenge payload remains **v3**. This is a source compatibility
pin, not an installer change or an update of any enrolled Gateway.

- [Official release](https://github.com/openclaw/openclaw/releases/tag/v2026.9.4)
- [Protocol version](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/version.ts)
- [Connect authentication selection](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-client/src/connect-auth.ts)
- [Session-aware model discovery](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/server-methods/models.ts)
- [Native transcript run identity](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/sessions/transcript-events.ts)

### Changes and complete-PR audit findings

- Persisted device credentials now use `auth.deviceToken`. Explicit shared
  bearer credentials retain `auth.token` and precedence; the selected credential
  remains covered by the Ed25519 signature. Device identity and Keychain scope
  are unchanged. There is no automatic credential deletion or token fallback.
- Model discovery sends the native `sessionKey` and `includeDetails: true`, while
  retaining `view: configured`, `preparedOnly: true`, and the non-default agent.
  Upstream can apply the session's account selection without provider discovery.
  Described model names retain `modelProvider` for matching provider-qualified
  catalog choices and their thinking levels. Account switching remains external.
- Native `__openclaw.runId` now reconciles history when an idempotency key is
  absent. Exact input idempotency keys still take precedence, preserving steering
  correlation. Tool and synthetic records still cannot prove a successful reply.
- The older in-conversation permission relay now captures enrollment and socket
  authority before presenting a decision, sends once on that transport, and
  leaves dismissed requests pending. Removed its automatic write retries and
  unused retry helper. Existing permission options are preserved; the newer
  inbox remains limited to one-time decisions.
- Question replies require an `answered` result, including receipt probes after
  uncertain delivery. A failed session-control operation clears the stale
  snapshot so the user must refresh before submitting another decision.
- Main was reconciled by a non-rewriting merge from cc6d2882c11239623c7f0925bf8db481a4a6985a,
  retaining the prior 13ede3f audit. Interrupted local ACP recovery excludes both
  Gateway and OpenCode sessions. Runtime/per-workspace settings, hover/visibility,
  ACP behavior and the existing UI components remain in the resulting tree.

### Contract comparison and limits

| Area | 2026.9.4 result |
| --- | --- |
| Gateway/auth/device | v4 frames/v3 signatures retained; optional hello auth method is additive; separate device-token field honored. Pairing/scope upgrades still require the Gateway's normal authorization. |
| Session list/import | Existing pagination and transactional import retained. New `activeOnly` is optional; the library intentionally lists all discoverable sessions. Native agent-qualified keys are retained. |
| History/reconnect | Current upstream improves failed-attempt filtering and CLI identity projection. Woven consumes canonical tail pages and native run identity, reconnects and resubscribes without resending unknown input. Durable delta-cursor catch-up, reset branch replacement and full offline outbox remain unimplemented. |
| Approvals/questions | Existing replay and resolution contracts remain compatible. Both native approval paths now avoid write retries across disconnects. Optional question URLs, secret storage and richer external interaction remain Control UI capabilities. |
| Controls | Patch/reset, abort, reasoning/verbosity/usage and Fast settings retain existing contracts. Upstream Fast applicability metadata is additive; a stored preference is not proof the selected model fulfilled Fast mode. |
| Models | Session-scoped prepared catalog and model-specific thinking metadata are consumed. Native account selection, provider connection/discovery and plugin management remain outside this PR. |
| Events | New rate-limit retry metadata on nonterminal chat status is additive and does not complete a local run. Observer lifecycle revisions and plugin rendering additions are not a claim of native parity. |

The complete diff was inspected for transport lifecycle, reconnect/write authority,
input persistence, import concurrency, transcript projection, inbox state, UI
wiring and main integration. No PR39/40/37 feature branch was merged, and no
cross-harness streaming redesign is included.

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

Reviewed the complete PR from `dc39c49` through `dd2efa5` against the then-pinned
OpenClaw v2026.9.2 source (3928bad9badfcb6c7d140530435e806fb8092190), then addressed these findings:

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

### Final isolated validation (2026-09-12)

`WOVENMATTER_TEST_CACHE_DIR=/private/tmp/wovenmatter-pr38-sept12 scripts/test-changes.sh --all`
passed: **166 Swift tests** (107 store/core and 59 client), **34 remote tests**,
static/privacy checks, macOS Debug build and native bundle validation.
`git diff --check` passed. The initial sandboxed attempt could not execute Swift
macros; the authorized unsandboxed run passed without changing build settings.

New regressions cover separate shared/device wire authentication, provider-qualified
model selection, exact input ID precedence, native run-ID reconciliation after
SQLite reopen, survival of Gateway runs during local ACP recovery, session-scoped
prepared model requests, and cancelled question results without write retries.
Existing retired-client, reconnect-decision, import-concurrency, missing-liveness,
steering and tool-only recovery coverage also passes.

A standalone native fixture compiled the actual `OpenClawSessionView`,
`DashboardDesign` and `SettingsComponents` against a fake model, using a separate
bundle identifier. Accessibility and rendered inspection confirmed controls,
scrolling, question multi-selection, free-text entry and submission enablement.
This is fixture evidence only: it does not validate a live approval, Gateway
pairing, provider response or the full application's narrow/wide workspace layout.
The fixture was closed. Shared Woven Matter Dev was neither replaced nor launched;
all build products remained in the isolated cache. The manager's exact-head Dev
integration and Trey's manual Gateway acceptance checklist remain outstanding.

### Local Link Gateway startup correction (2026-09-12)

User acceptance exposed a local launch failure hidden by discarded stderr/stdout.
The old command forced `--auth none` on an agent-specific port while inheriting
`gateway.tailscale.mode=serve`. The installed 2026.9.4 CLI rejected this with exit
78: `gateway.auth.mode=none cannot be used with gateway.tailscale.mode=serve`.
This was reproduced before the user narrowed testing, using a temporary minimal
configuration, not the live Gateway or user configuration.

Local-workspace preparation now reads the selected local configuration and uses
its port and authentication. An existing listener is borrowed: unlink and app
shutdown never terminate it. If no listener exists, Woven owns only the foreground
child it starts, with no auth, bind, or Tailscale override and no `--force`.
Serve-enabled and Serve-disabled configurations follow this same path; neither
requires changing the user's Serve setting. The proposed `--tailscale off`
workaround was withdrawn and is not included.

Plaintext, environment, and OpenClaw store-backed authentication are resolved only
in memory. The actual setup uses a store SecretRef; its single team-scoped value
is read through a parameterized, read-only query matching upstream
`src/secrets/store/secret-store.ts`. No credential or database migration is
performed. Password auth is supported in the Gateway connect frame. Credentials
are absent from persisted links and argv. Unsupported included Gateway settings,
custom-bind/TLS, trusted-proxy bypass, or unresolved references fail visibly
instead of overwriting configuration or weakening security.

Startup stdout/stderr are continuously drained into a 16 KiB in-memory tail.
Failures include exit status and at most eight sanitized lines/2 KiB; known
credential values, credential-bearing lines, URLs and home paths are redacted.
No raw startup log is written to disk. Existing process cancellation/reaping
remains bounded.

Per the user's direction, no new tests, scenario matrix, or testing infrastructure
was added for this correction. Existing repository-required validation is used;
Trey's actual Link Gateway retry in the manager-built Dev app remains the
acceptance check. Real Serve availability has not been asserted from a fixture.
