# Central library and distributed workspaces

This is the storage, execution and synchronization contract for paired clients.

## Roles

One designated Mac owns the authoritative Woven Matter SQLite library. Its background service exposes the library API; closing the interface does not transfer authority. iOS, iPadOS, and other Macs use local replicas of the same library and synchronize durable changes.

Execution workspaces run on Macs, Linux containers, and iOS devices. A conversation has one execution workspace, and a run has one owner. A client is an interface to any authorized reachable workspace. Client disconnection does not cancel accepted execution. A central-library outage does not prevent direct workspace control after pairing/provisioning.

Tailscale carries inter-device connections. Woven Matter additionally authenticates individual devices and scopes their access. The central service provisions credentials only for the authenticated paired device. Workspace administrator secrets and provider refresh credentials are not part of content synchronization.

## Storage boundary

The central library consolidates notes, folders, conversations, complete exposed execution history, shared settings, and saved artifacts. Project roots and managed SQLite datasets follow [the workspace data model](WORKSPACE_DATA_MODEL.md): one execution owner per root/dataset, separate from the central history database. Workspace files remain in their workspace: repositories, dependencies, build outputs, caches, and native runtime checkpoints are not mirrored wholesale. Saving an output to the library creates an explicitly synchronized artifact.

A client replica is separate from native runtime persistence. Cache eviction must never remove unsynchronized changes, active runtime state, or the only copy of locally originated history. Each execution workspace retains its own durable execution records and publishes them directly to the central library. An observing client may cache a foreign workspace journal for display, but must never publish that history or its artifacts. Linux workspace publication continues independently of any viewing client, including after the workspace service restarts. Each workspace uses its own publication identity scoped to that library and workspace; provisioning ownership does not confer execution ownership.

Library changes use conditional revisions and retained deletion/conflict state. Commands use stable IDs, immutable request identity and durable receipts. Replay imports observations; it never executes commands. Interrupted transfers resume by validated offsets and content digests. Acknowledgement is emitted only after durable acceptance. Histories exceeding a network page are paged or chunked without truncation.

## Workspace organization across devices

**All Workspace** is the combined library-content view, not an agent directory.
Each client presents its own execution device as **Local workspace** and other
registered devices as **Remote workspaces**, alongside configured Linux hosts.
Agents and folders belong under their workspace. On iPhone and iPad the single
local agent is **Quick Chat**, powered by Pi Durable. Another device's Quick Chat
is saved history only; clients never start or control Quick Chat on a remote phone.

Notes retain an explicit workspace identity even when they are not in a folder.
Creating an unfiled note on a device assigns that device; editing synchronized
writing elsewhere does not transfer ownership. Folder membership provides a
workspace association for older filed notes. Existing unfiled notes without
reliable ownership evidence remain shared/unassigned instead of being attributed
to whichever client first downloads them. All Workspace keeps those items visible.

Workspace comparisons normalize legacy device/remote ID prefixes without
rewriting execution roots or moving runtime data. New-item actions use their
workspace context, never the first reachable remote host. Connectivity affects
whether remote actions are available, not whether a saved workspace is listed.

## Device connections and synchronization

The central Mac manages membership and access in Settings → Devices.
Macs discover compatible Woven Matter services among peers visible through their
existing Tailscale client. Initial pairing requires approval; discovery alone
never grants library access. A one-time pairing link remains available. iPhone
and iPad use Settings → Device Connections with QR scanning or a pasted pairing link.
Each Mac defaults to **Central database**. The **Database role** section at the
bottom switches it to **Node** through a guarded restart, preserving the existing
database separately. An unpaired node opens setup; after pairing it starts its
own execution workspace. Only nodes offer central-database discovery/link entry.
Local Agent Workspace and Remote Agent Workspaces manage execution locations;
library pairing belongs in Devices.

A paired client receives the registry and access to enabled execution workspaces
from the central Mac. Previously authorized direct connections do not depend on
the central Mac being reachable. Per-device presence describes contact by that
device, not requests from another client. Connectivity and synchronization are
separate states: a reachable central Mac does not mean every pending change has
been accepted. Revocation takes effect centrally immediately and propagates to
unreachable workspaces when they reconnect.

Notes, folders and calendar edits commit locally with durable pending operations.
Synchronization runs after edits and on foreground/reconnect opportunities, with
retry backoff and periodic reconciliation. Independent resource streams must make
progress even when another stream has a conflict or interrupted artifact transfer.
Sync acknowledgements advance only the exact submitted operation; edits made
while a request is in flight remain queued. Conflicting edits retain both versions;
deletions retain tombstones and never resurrect an old identity during replay.

Notes, calendar and the library index are available offline after download.
Recent central transcripts are cached automatically; older transcript pages and
large saved artifacts are downloaded on demand. The
immutable federation journal currently retains downloaded origin events in full;
it is not pruned or skipped to simulate lazy transcript transfer. Cache cleanup never
removes pending edits, conflicts, pinned content, or the only copy of locally
originated execution data. Unsynchronized data remains until acknowledged by the
central library. Provider credentials, runtime checkpoints and ordinary workspace
files are outside this library-content synchronization boundary.

When the central Mac is offline, ordinary library edits on one client remain local
until central synchronization resumes. Direct workspace commands and history reads
continue against reachable owners. No client becomes a replacement central library,
and no viewing client acts as a synchronization intermediary for another workspace.
Sync runs automatically. Devices on Mac (Device Connections on iOS) contains pairing and device access,
not sync-lane dashboards or optional per-chat offline toggles. Recovery for an
actual conflict belongs with the affected item. Ordinary disconnection must not
create intrusive banners or dialogs. Explicit **Unpair** removes central-issued
access grants, retaining cached content, pending writing, inference sign-ins,
and the database binding so another database cannot receive old pending writes.

## Quick Chat on iOS and iPadOS

Quick Chat is powered by Pi Durable on the phone, with device-local provider
connections and unchanged native sign-in flows. Models run through the selected
cloud provider or explicitly configured Tailscale inference adapter. Local model
inference is outside scope. Account secrets stay in the device Keychain.

Quick Chat exposes a fixed notes/web tool boundary. It can edit the existing
local notes replica, use explicit note references, and search/read the public web
through an optional device-owned Exa key. Native and SDK dispatch both exclude
code execution, shell/repository tools, Python/WASM, subagents, goals, timers and
phone-owned scheduling. It has only a short save/interruption allowance when
backgrounded, followed by explicit Resume; it promises no background execution.
Earlier phone-agent chats remain history without resuming their saved tool work.

Mac/Linux workspace agents remain the primary mobile execution experience. Their
existing sessions, permissions, models, approvals, questions, Stop and steering
controls stay with their owners. Owner-scoped folder APIs allocate directories
on the execution host, and direct session creation captures that folder's root.
Linux keeps an independent durable folder outbox and publishes metadata before
its conversations when central returns. Immediate direct control requires only
the already-authorized Linux service and the phone on the Tailnet. Shared calendar
schedules retain the existing central-library scheduling path; the phone does
not run scheduled tasks or move old phone-owned tasks automatically.

## Client roles and compatibility

A secondary Mac switches explicitly to Node mode before pairing. The transition flushes local writing, checks active work, and restarts with a separate ownership role. Its prior library is preserved. Every Mac retains its own local execution workspace. Its execution origin is distinct from the authority for the paired library. Creating or provisioning additional Linux workspaces remains a central-Mac operation.

The existing companion protocol remains compatible while new federation capabilities are negotiated explicitly. Persistent identities, pairing and unsynchronized writing survive migration. Older servers/clients receive explicit unavailable or version responses for unsupported capabilities.

## Required acceptance

- Real Pi Durable Quick Chat edits local notes with a controlled inference fixture, rejects coding/automation tools, preserves history and resumes safely after interruption.
- Cloud/provider and Tailscale inference routes preserve selected model/account identity; real account checks are reported separately from fixtures.
- With the central Mac offline, clients control reachable workspaces and retain local writing and execution history.
- Reconnection consolidates multiple clients and execution origins without duplicate sends, stale Stop/approval actions, missing output, or resurrected deletions.
- Saved artifacts synchronize with integrity checks and resumable transfers; workspace working files remain local.
- Secondary Mac client mode preserves both the paired replica and the prior local library, with safe failed-transition rollback.
- iPhone and iPad support the existing shared styles and canonical green cube app icon; simulator checks precede physical-device acceptance.

Implementation status and exact test evidence belong in the PR handoff; this document states the required contract and does not claim unperformed live acceptance.

## Provider model metadata

The app has no first-party bundled model inventory or catalog generator. Opening
one provider fetches only its credential-free `https://pi.dev/api/models/providers/{provider}?types=chat&pi-version={SDK-version}`
shard directly, avoiding the service’s version-normalization redirect while retaining a no-redirect policy, using `User-Agent: pi/<SDK compatibility version>`. `types` selects the
representation; both loaders explicitly retain only supported chat APIs. Native
API-key xAI connections retain the `xai-api` identity while fetching the `xai` shard. Device Claude subscriptions retain `claude-subscription` while fetching the `anthropic` shard.

The native cache and the shared desktop/remote cache store bounded provider files
with ETag, Last-Modified and a four-hour freshness window. They perform no launch
fetch or polling. Refresh happens only while browsing a provider or resolving an
uncached selected descriptor; cached selections remain usable during catalog
outages. Refresh/retry is explicit after a first-load failure. Public metadata
requests contain no credentials, cookies, account/device IDs or inference input,
and do not follow redirects. Fixed provider/API/base-URL policy is checked before
credential access. Complete compatibility, reasoning, input and tiered-cost
metadata survives storage; it cannot supply credential destinations or headers.

Device connections save their selected descriptors. Existing device conversations
retain their original `modelJSON`. Desktop/remote conversations and native child
contexts pin selected descriptors in their existing durable records; inference
hosts also retain their own descriptor for each authorized client conversation.
Catalog refresh cannot replace a run's model, provider, account or execution owner.
Authorized subscription-host discovery and explicitly configured Tailscale server
IDs remain separate from public metadata discovery.

On desktop and hosted Claude connections, model names and effort options come from the SDK's demand-driven
`supportedModels()` with empty streaming input, or its last valid saved result.
An empty cache has an unavailable/retry state, with no app-authored aliases. The
SDK does not expose context/output limits in that result; the existing native
adapter's conservative host budgets remain limits, not discovered entitlements.

The upstream Pi desktop/remote dependencies still contain and eagerly import their
own provider baseline (about 951 KB in Pi 1.1.0). Woven's provider catalogs and
selected-label UI no longer depend on it. Removing those upstream bytes requires
an SDK packaging change and is outside this cleanup. The actual iOS Pi Durable
runtime bundle and `harnesses/catalog.json` installation manifest are retained.

OpenRouter catalog entries that declare the dynamic-router unavailable-price sentinel are omitted; their prices are never replaced with zero. Normal chat entries remain available, and destination/header validation still runs before exclusion.
