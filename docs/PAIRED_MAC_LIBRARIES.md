# Paired Mac libraries

Every paired Mac runs the normal Woven Matter desktop app and saves a complete
local shared library. Pairing combines libraries through ongoing synchronization;
it does not move a database, retire a host, promote a node, or select a central
Mac. Any Mac can add a remote workspace or pair another Apple device.

## Shared data and execution ownership

`PairedLibraryTables` is the reviewed content boundary. Shared rows cover notes,
versions, folders and roots, conversation/message/run observations, native history,
calendar definitions, dictation history, library settings and indexes, saved
artifacts, workspace descriptors and remote workspace definitions. Shared library
and attachment bytes transfer by content hash. A new paired Mac downloads the
shared data; there is no optional per-chat offline flag or automatic eviction of
the only locally saved copy.

Execution retains one owner. Native session bindings, SDK checkpoints, delivery
queues, timers, command receipts, provider credentials, SSH credentials and
workspace administrator capabilities remain local. Conversation, agent and
calendar ownership are shared records of their own, separate from edit origin,
so editing a chat or schedule from another Mac does not move its executor.
The execution owner's native rows are its truth: while a Mac currently executes
a chat natively (not adopted into another workspace and without retained or
independent execution history), an observed version of that chat or its runs
never replaces agent binding, authority, folder or run and message state there.
Rename and pin are shared edits from any Mac; a rename stored as a title override
applies whichever row arrives last. Trash, restore and draft folder moves change
runtime state, so the app sends them for another Mac's chat to that Mac, which
applies its own checks and effects; with that Mac unreachable they fail rather
than apply locally. These actions need positive authority on the Mac applying
them: it runs the chat natively, or the chat belongs to a known independent Linux
or iOS workspace. A chat adopted into such a workspace keeps the projection
semantics it already had: trash and restore apply to this library's projection
and are never routed to its earlier Mac or dispatched to the Linux workspace,
and draft folder moves for it are not supported. A chat whose owner record has not arrived yet
is unavailable for them. A trash request that still arrives through synchronization
is accepted only when the owner is idle, with the owner's goal pause and
delivery cancellation, and is otherwise declined. The owner republishes its
version so every Mac converges on it. Paired-Mac routing for a chat is rebuilt
from its owner record. Ownership is positive: a
Mac recovers interrupted runs, schedules goals, records
goal usage, runs schedules, indexes library messages and captures workspace files
only for rows whose owner record names that Mac. A row received before its owner
record stays read-only, including across restarts. Imported observations do not
fire native-history, library-indexing or capture triggers, or dispatch commands.
Native workspace files are outside library sync; an observer downloads the
owner's retained library bytes and never resolves a path on its own disk.
Outside MCP exposure is a per-Mac setting: shared tool choices synchronize, but
enabling exposure on one Mac never enables it on another.

A workspace descriptor keeps its stable ID, execution owner and credential
namespace when another Mac receives it. Direct credentials are issued separately
for the requesting device. A device already enrolled with a Linux workspace can
connect directly when its managing Mac is offline. First enrollment needs that
Mac's management capability; this is execution ownership, not library authority.
Remote workspace definitions appear in the shared inventory; administrator and
SSH credentials do not become shared configuration.

## Change exchange and conflicts

Shared table mutations and their journal entries commit in one SQLite
transaction. A persistent device UUID identifies a replica. Primary/natural keys
identify rows; local SQLite sequence numbers are not shared identities.

Changes carry a Lamport counter and causal vector. Each identity keeps a durable
causal frontier: every version no other known version dominates. A dominated
version is obsolete forever; among concurrent frontier versions a deletion wins,
then counter and origin ordering choose the same winner on every Mac, whatever
the arrival order, page boundaries or restarts. An explicit later restore
supersedes the deletion causally while a concurrent edit stays in the frontier.
A local write supersedes the frontier it has seen. Losing live note content gets
a stable, visible **Recovered edit** note; other losing versions remain in
`paired_library_conflicts`, and library bytes they reference are not cleaned up.
Replaying a conflict cannot create another copy. Older stores recompute their
canonical winners once on upgrade.

Each pair retains separate push and receive cursors. Receive data and its cursor
commit together. The sender advances only after an acknowledgement for the exact
page. Process loss or a lost reply therefore retries durable identities. Peers
relay the original records, rather than inventing a new edit origin. Persistent
membership, routes, cursors, tombstones and recovery state survive restart.

Large values are content-addressed separately from their row metadata. A receive
page can durably queue such a row until its bytes arrive, allowing other writing
to continue; waiting rows are scanned from a rotating durable position, so
unavailable bytes never starve ready rows. File downloads retain byte offsets
across restart, accept only the expected next chunk, and verify size and SHA-256
before installing a local file, including a complete download interrupted before
installation. Incomplete or corrupt files never replace a completed copy.
Individual values/files have a 256 MiB safety boundary; larger workspace outputs
should remain workspace files. A deterministically invalid record is quarantined
in its own savepoint without partial changes, and is reported; storage failures
still stop the page.

## Pairing, membership and revocation

Both Macs negotiate `library.peers.v2`. Initial pairing keeps the existing
explicit approval and secret-bound claim flow, marked as a Mac pairing; only that
explicit purpose can produce a paired-Mac grant, and device metadata never
chooses a grant's role. Macs can also paste a pairing link from the other Mac.
Each Mac has a device-only Curve25519 signing key. At the explicitly paired
endpoint the requester learns the revocation context the other Mac holds for
it, proves its key for exactly that context, and supplies the bearer it issued
for the other Mac; the reply proves the other Mac's key for that reciprocal
grant. Each Mac pins the other's key by device UUID in its local credential
store, outside replicated SQL. The signed join is persisted before it is sent
and repeated verbatim after a lost reply; the other Mac accepts only that exact
transcript. Pending pairing secrets and bearers are absent from discovery, shared
SQLite data, UI snapshots and the peer journal. Grants from earlier unreleased
builds of this feature are not upgraded; pair those Macs again.

Each Mac authenticates only bearers it issued itself. Paired Macs exchange
membership that authenticates nothing: signed Mac admissions (introductions that
bind a device UUID, library and key, signed by both the introduced Mac and the
introducing Mac), names of mobile devices, and signed unpair events. A Mac
introduced by another can then obtain its own grant directly: the target signs a
one-use challenge with its pinned key, the requester signs it with its own
pinned key, and the target issues a grant valid only at itself. Challenges are
held in memory, so a restart invalidates them. This keeps paired Macs
synchronizing when the Mac that introduced them is offline or later unpaired.
An unpaired Mac cannot introduce anyone new, and pins are never replaced by
synchronized membership. Every paired-Mac endpoint, and the ordinary library and
federation endpoints, accept only grants the receiving Mac issued, so a bearer a
Mac minted or holds for another Mac is useless anywhere else.

An unpair is a distinct signed event. A grant or admission stays valid only while
it acknowledges every known unpair event for its device, and an admission's
subject signs the exact set it acknowledges. Concurrent unpairs on different Macs
therefore all apply when they meet, and only a pairing made after learning them
survives; a grant issued without knowledge of an unpair made elsewhere is
revoked when that unpair arrives. Each exchange advances trust by one hop. The
Macs this Mac admits when an exchange begins are the only signers it trusts in
that exchange: every new unpair they signed is accepted together, as concurrent
events, before any introduction is judged, and only those Macs (if still
admitted after those unpairs) can introduce new Macs. A Mac learned in an
exchange can unpair or introduce others only in a later exchange; repeated full
membership synchronization carries its events and introductions again, so its
own unpairs always apply before anything it introduced. Unpairs accepted earlier
always remain, and an introduction accepted earlier survives its introducer's
later unpair. An unpair signed by a Mac that was already unpaired when the
exchange began is rejected: its random event identifier cannot show whether it
was made before or after that Mac's removal. A legitimate unpair made offline by
a Mac that was then itself unpaired can therefore be declined by Macs that
learned of its removal first; such an unpair must be repeated from an active Mac.
This design does not preserve every offline concurrent unpair.
Identifiers in signed membership must be canonical lowercase UUIDs and contexts
are bounded. A learned address must sign a fresh challenge naming the expected
Mac, library and contacted endpoint with that Mac's pinned key before it
receives a bearer; an authenticated display-name change is adopted. There is no
shared-secret fallback, and redirects and cookies are disabled. Merely appearing
on the tailnet grants nothing.

Within the trusted boundary, a Mac that is still admitted can introduce a device
UUID that no other Mac has pinned yet; pins prevent that binding from being
replaced later, but cannot undo an introduction made while that Mac was trusted.
A still-admitted Mac can also publish unpair events for others. Recovering from
a lost signing key needs that Mac to be unpaired everywhere and paired again.

Once routes and membership have propagated, Macs can contact each other directly,
including when the Mac that joined them is offline. There is no public directory:
a Mac must first learn a route through pairing, discovery or a connected peer.
Ordinary network loss retains local work and retries quietly. A revoked Mac
retains its local data but cannot use revoked credentials to resume syncing.
Unreachable execution owners apply queued revocations on reconnection; a
revocation is recorded as applied only after this Mac's own access is revoked.

Mobile devices keep their offline replica and approved Mac connection, and their
bearer works only at that Mac. Other paired Macs list them for display. When a
Mac enrolls one of its phones in a workspace another Mac manages, it asks that
Mac directly, and the managing Mac records the requesting Mac as that issued
grant's provenance. A replacement request is staged: earlier provenance is
retired only once the replacement is actually issued (which replaces the earlier
token), so a failed or offline replacement never hides a grant from cleanup. A
direct grant the managing Mac issues to a device it paired itself likewise
retires that device's delegated provenance for the workspace, after any queued
device-only cleanup for it has run, so a later unpair of the delegating Mac never
revokes the direct grant. Provenance is retired while the workspace's enrollment
is still in progress. For a remote workspace, which keeps one token per device,
cleanup queued during an enrollment for the provenance being replaced is
satisfied once the replacement is committed; a failed replacement, a
replacement from the Mac being unpaired, or the device's own unpair keeps that
cleanup queued.
Execution and inference requests served by the managing Mac's own services are
authorized live by their grant's provenance before credentials are prepared and
again before a model stream starts. Unpairing the requesting Mac therefore ends
grants derived through it on those services immediately and leaves grants the
managing Mac issued for its own devices. Remote workspaces (Linux, or the
retired node's execution host) authorize by token: their grants end when the
queued remote cleanup reaches them, which is eventual while they are offline. Execution grants
from before provenance was recorded cannot show who received them and are
retired, except the Mac's own. A phone whose grant is rejected clears that
workspace's credential and, while connected to its Mac, requests a new one on its
next workspace refresh; a workspace owned by another paired Mac keeps that
workspace's registered library namespace and endpoint. Every new or renewed
workspace credential the phone installs, whether requested automatically or
from Settings, also replaces the token of each inference connection bound to
that workspace's exact host scope and endpoint; a reconnect or re-pair during
installation installs nothing further. A Dev connected client that keeps a
direct workspace credential clears it when the workspace rejects it and
requests a replacement through its central library, retrying on each reachable
central refresh until it succeeds, including after a restart; it never presents
the rejected token again. The pending request records only workspace IDs, bound
to that client's library and device, and is cleared on success, on unpairing,
or when the workspace is removed.
The retired node's execution host, which runs only for a Dev connected client,
is a remote execution workspace with the same trust boundary as a Linux
workspace its chosen managing Mac enrolled: it issues grants through its own
management grant and authorizes requests by token validity, so revocation there
takes effect when queued cleanup reaches it.
This change does not
turn phones into full desktop replicas or automatically replace a mobile
device's chosen library endpoint.

## Upgrade and recovery

Before the first peer import, each Mac saves a consistent, integrity-checked
`Paired Mac Backups/before-peer-sync.sqlite` snapshot. It includes committed WAL
content. The app never restores this automatically over subsequent writing.
Retain the original database and device-only credential vaults when recovering.
Ownership of rows that existed before pairing is claimed exactly once, before any
peer data arrives; a schedule assigned to a client device keeps that executor.

Older node preferences no longer select a reduced desktop interface. Upgrade
preserves the old replica and command journal, takes backups, and imports a
WAL-aware copy of a former node's native database on the same physical Mac; the
original execution directory is never modified. Notes, folders and schedules
that the node held only as projections of the central library are not imported,
so the central Mac's current writing wins; writing that existed only in the
node's workspace is preserved. The import commits with its completion marker, so
a retry never duplicates rows. Cached notes, conflicts and unsent composer text
get deterministic **Saved before pairing upgrade** notes. Pending note and folder
operations are sent to the original approved Mac with their original operation
IDs before pairing, so its receipts make retries exact; any operation it does not
apply is kept as a visible note rather than abandoned. Imported runs that were
active are recovered during the upgrade launch. Goal membership is kept by
stable run IDs: an imported active goal first enrolls the node's runs it had not
yet counted, then is paused; usage for enrolled runs keeps counting, and only
runs after the upgrade enroll later. A goal this library already had is never
changed by the import. Nothing is replayed
against the new local library and pending agent commands are never replayed.
If an upgrade step fails (for example the retired node's lease is still held),
the full app still opens, the failure is reported, paired synchronization stays
paused, and the upgrade is retried on the next launch.

SQLite recovery backups and original replica/native files preserve ambiguous
legacy collisions. Provider credentials remain in their original local storage.
The retired node's execution lease must be free before import; upgrade never
force-kills another owner. A fresh Dev snapshot drops copied peer routes,
membership state, counters and cursors, retaining source history without
connecting to production. It keeps the copied ownership records, so a snapshot's
new identity owns nothing it copied and never runs another Mac's schedules.

## Review and device test plan

Automated fixtures cover the persistent merge rules and actual Mac services with
in-memory credential vaults and controlled network/execution fixtures. A test
process falls back to isolated memory storage even if a fixture omits it, and
paired-credential storage failures never stop phone or library service. No
provider services or real pairing credentials are consumed.

- Pair two Macs that each already have notes and history. Both should retain
  their normal workspace and sidebars, with no database-role selector.
- Disconnect them. Create and edit notes on both, including editing the same
  note. Reconnect and verify both converge, with conflicting writing recoverable.
- Delete a note on one Mac while editing it on the other. The original should
  stay deleted and the concurrent writing should remain in a recovered note.
- Add a remote workspace and an Apple connection from either Mac. Reconnect the
  other Mac and inspect the single workspace inventory. The new device's bearer
  works only at the Mac it paired with.
- Pair a third Mac, let membership synchronize, then take the joining Mac
  offline. The other two should still exchange notes and new connections.
- Save a large library file, interrupt its download and restart the receiving
  app. Other notes should synchronize while the file resumes and verifies.
- Open a conversation owned by the other Mac. Read its saved history offline;
  when reachable, Send/Stop should address its original execution workspace.
- Confirm scheduled work runs only on its owner. Disconnecting another Mac must
  not start a duplicate execution or move an accepted run.
- Unpair a device from one Mac. After the other peers reconnect, its old library,
  direct execution and inference credentials must be rejected. Retained local
  writing must remain available on the unpaired device.
- For a former node, confirm recovered writing and its original native sessions
  survive the upgrade. Do not delete the original replica or recovery backups.

Real multi-Mac Tailscale connectivity, macOS Keychain access, sleep/wake, and
real-account execution require Trey's hands-on acceptance before merging.
