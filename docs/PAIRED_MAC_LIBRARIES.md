# Paired Mac libraries

Every paired Mac runs the normal Woven Matter desktop app and saves a complete
local shared library. Pairing combines libraries through ongoing synchronization;
it does not move a database, retire a host, promote a node, or make one Mac the
authority. Any Mac can add a remote workspace or pair another Apple device.

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
namespace when another Mac receives it. There is no managing Mac: every Mac
reaches every other Mac's and Linux host's execution API, and administers
every Linux host, with requests signed by its own member key (see
[Woven everywhere](architecture/WOVEN_EVERYWHERE.md)). Nothing is enrolled for
a Mac. A phone that still uses a bearer gets its grant for a Linux workspace
from that host, requested by any Mac; for another Mac's own workspace, from
that Mac. Remote workspace definitions appear in the shared inventory; SSH
credentials stay on the Mac that installed the host and do not become shared
configuration.

Another machine's chats arrive in this library by synchronization like any
other history; there is no separate per-Mac cache of them. While one is open,
this Mac's background server follows it live on that machine's member-signed
stream (`GET /v1/stream?protocol=1`) and sends its commands there; nothing
polls the other machine. When it is unreachable, the chat shows the
synchronized history and says the machine is offline.

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

Large values are content-addressed separately from their row metadata. Saved
artifact chunks and native history parts never carry bytes: their rows name a
file in `library-chunks/` by SHA-256 and size. A receive
page can durably queue such a row until its bytes arrive, allowing other writing
to continue; waiting rows are scanned from a rotating durable position, so
unavailable bytes never starve ready rows. A waiting row is relayed at once,
ahead of later writing that covers it, and until it is applied a local edit of
that identity stays concurrent with it, so a version whose bytes are still in
transit is never silently superseded. File downloads retain byte offsets
across restart, accept only the expected next chunk, and verify size and SHA-256
before installing a local file, including a complete download interrupted before
installation. Incomplete or corrupt files never replace a completed copy.
Individual values/files have a 256 MiB safety boundary; larger workspace outputs
should remain workspace files. A deterministically invalid record is quarantined
in its own savepoint without partial changes, and is reported; storage failures
still stop the page.

## Pairing, membership and revocation

Every device has a long-lived Curve25519 signing key that never leaves it: a
Mac's is in its Keychain and is both its paired-Mac key and its member key. The
member list, request signatures and trust rules are specified in
[Woven everywhere](architecture/WOVEN_EVERYWHERE.md) ("Membership and device
keys", "Trust model"); this section covers how paired Macs use them.

**Pairing two Macs.** Initial pairing keeps the explicit approval and
secret-bound claim flow, marked as a Mac pairing; only that explicit purpose can
produce a paired-Mac grant, and device metadata never chooses a grant's role.
Macs can also paste a pairing link from the other Mac. The join is the one
Mac-to-Mac step that still uses bearers: with the grant it was issued, the
requester calls `POST /v1/peers/join/prepare` at the paired endpoint to learn
the revocation context the other Mac holds for it, then `POST /v1/peers/join`,
proving its key for exactly that context and supplying the bearer it issued for
the other Mac; the reply proves the other Mac's key for that reciprocal grant.
Each Mac pins the other's key by device UUID in its local credential store,
outside replicated SQL. The signed join is persisted before it is sent and
repeated verbatim after a lost reply; the other Mac accepts only that exact
transcript. When the join completes, each Mac records the other as a signed
`mac` member entry. Pending pairing secrets and bearers are absent from
discovery, shared SQLite data, UI snapshots and the peer journal.

**Member list.** Membership is a signed record set kept in shared library rows
and synchronized like any other content. Trust comes only from the signatures,
resolved on each device from its own local anchors, never from what a row or an
endpoint says about itself. Any Mac member can add a device. A Mac that one Mac
added is trusted by every other member through that signed entry, with no grant
or handshake of its own, so Macs keep synchronizing when the Mac that introduced
them is offline or later removed. A Mac this device has trusted continuously for
24 hours is pinned as a local anchor. Macs paired before members existed are
converted into members on launch from their pinned keys; library content is
never touched.

**Signed synchronization.** Library exchange runs in `LibraryPeerSync` between
every `mac` and `linux` member, with each request signed by the caller's device
key: `POST /v1/peers/sync`, `/v1/peers/notify`, `/v1/peers/files` and
`/v1/peers/file`. A local commit is announced once, debounced, to online peers,
and each pulls with one exchange; a peer that reappears is caught up once; a
60-second presence check, backing off to 15 minutes for an offline peer,
replaces constant polling. Peers must share the exact shared-table schema, and
a mismatch is reported as "update required" rather than partially applied.
Requests go only to tailnet HTTPS endpoints (`https://*.ts.net`) taken from
signed member entries; there is no public directory, redirects and cookies are
disabled, and merely appearing on the tailnet grants nothing. Once membership
has propagated, every Mac and Linux host reaches every other directly. Ordinary
network loss retains local work and retries quietly.

**Removal.** Removing a device publishes a signed revocation, and every device
refuses that device's signed requests as soon as the revocation synchronizes.
Removing a Mac voids everything it signed; the removing Mac first re-signs the
entries it holds from the removed Mac, so the devices it added stay (review the
device list afterwards). It also queues a rotation of the installer bearer on
every Linux host the removed Mac added. A removed device retains its local data
but cannot resume syncing. Unreachable execution owners apply queued revocations
on reconnection; a revocation is recorded as applied only after this Mac's own
access is revoked. Recovering from a lost signing key needs that Mac to be
removed everywhere and paired again.

**Bearers that remain.** Each Mac authenticates only bearers it issued itself,
so a bearer a Mac minted or holds for another Mac is useless anywhere else.
Besides the join, paired-Mac bearers serve only:

- `/v1/peers/usage`, read with the grant from pairing with that Mac (see
  "Usage across devices");
- the bearer-era roster (phone names, Mac introductions and signed unpair
  events), which rides along each signed exchange as an attachment so that
  grants issued before members are revoked with their device. It authenticates
  nothing, and pins are never replaced by it.

**Phones.** A phone that pairs with a member key gets an `ios` entry signed by
the Mac it pairs with, added when the phone confirms the pairing. It signs its
requests and syncs its offline replica with whichever Mac or Linux host answers,
trying the last one that worked first; the Mac it paired with is only a starting
point, and other members never need it. Pairing a phone again replaces its key,
as after restoring a backup. Phones are not full desktop replicas.

A phone without a member key, or one whose Mac answers that it does not list
its key, keeps its bearer grant at the Mac it paired with. When that Mac enrolls
such a phone in another Mac's workspace, it asks that Mac directly, and that Mac
records the requesting Mac as the grant's provenance; a Linux host issues the
grant to any Mac's signed request. A replacement is staged: earlier provenance
is retired only once the replacement is actually issued, so a failed or offline
replacement never hides a grant from cleanup. Execution and inference requests
served by a Mac are authorized live by their grant's provenance, before
credentials are prepared and again before a model stream starts, so removing
the requesting Mac ends grants derived through it immediately. A Linux host
authorizes by token, so its grants end when the queued cleanup reaches it,
which is eventual while it is offline. A phone whose grant is rejected clears
that workspace's credential and requests a new one on its next workspace
refresh. Every new or renewed workspace credential also replaces the token of
each inference connection bound to that workspace's exact host scope and
endpoint.

## Upgrade and recovery

Before the first peer import, each Mac saves a consistent, integrity-checked
`Paired Mac Backups/before-peer-sync.sqlite` snapshot. It includes committed WAL
content. The app never restores this automatically over subsequent writing.
Pairing starts the backup and does not wait for it: on a library of several
gigabytes the copy and its check take minutes, and they read their own
connection, so every other database job keeps running. Until the backup
exists, that Mac refuses peer pages with `peer_unavailable` (the sender retries
and shows the Mac as offline, not failing) and starts its own first exchange
once the backup is written. An interrupted backup starts again at launch, and
a marker beside it (`before-peer-sync.sqlite.required`) keeps imports refused
until it finishes. A backup that fails, usually for lack of space for a second
copy, is retried after one minute, doubling to fifteen; meanwhile the first
synchronization reports its error.
Retain the original database and device-only credential vaults when recovering.
Ownership of rows that existed before pairing is claimed exactly once, before any
peer data arrives; a schedule assigned to a phone keeps that executor.

Provider credentials remain in their original local storage. A fresh Dev snapshot drops copied peer routes,
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
  other Mac and inspect the single workspace inventory and member list.
- Pair a third Mac, let membership synchronize, then take the joining Mac
  offline. The other two should still exchange notes and new connections, and
  a phone should sync with whichever Mac answers.
- Save a large library file, interrupt its download and restart the receiving
  app. Other notes should synchronize while the file resumes and verifies.
- Open a conversation owned by the other Mac. Read its saved history offline,
  with its offline notice; when reachable, it follows that Mac live and
  Send/Stop address its original execution workspace.
- Confirm scheduled work runs only on its owner. Disconnecting another Mac must
  not start a duplicate execution or move an accepted run.
- Remove a device from one Mac. After the other peers synchronize, its signed
  requests and its pairing bearers must be rejected. Retained local
  writing must remain available on the unpaired device.

Real multi-Mac Tailscale connectivity, macOS Keychain access, sleep/wake, and
real-account execution require Trey's hands-on acceptance before merging.

## Usage across devices

Usage is not a shared library table: each Mac keeps its own index and reads other
Macs over `/v1/peers/usage` with the bearer grant from pairing with that Mac. A Mac reports
its own usage plus the Linux machines it reads, as hourly counts and labels with
folder names only, never transcript content or paths. A Linux machine's rows keep
the host's own IDs when passed on, so a Mac that also reads that host directly keeps
one copy. A Mac reports that it is still reading until its first full import ends.
Account-wide sources are left out, so they are not counted once per Mac. Other
devices' rows stay on the Usage page; agent tools and phones keep reading only this
Mac's records.
