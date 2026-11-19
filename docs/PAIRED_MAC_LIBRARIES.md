# Paired Mac libraries

Every paired Mac runs the normal Woven Matter desktop app and saves a complete
local shared library. Pairing combines libraries through ongoing synchronization;
it does not move a database, retire a host, promote a node, or make one Mac the
authority. Any Mac can add a remote workspace or pair another Apple device.

## Shared data and execution ownership

`PairedLibraryTables` is the reviewed content boundary. Shared rows cover notes,
versions, folders and roots, conversation/message/run observations, native history,
calendar definitions, dictation history, library settings and indexes, saved
artifacts, workspace descriptors, the names people give workspaces
(`execution_workspace_names`) and remote workspace definitions. Shared library
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
than apply locally. A new folder on another Mac is asked of that Mac the same
way (`createFolder`, from a Mac only, for a Mac that lists `folders.create.v1`):
it creates the directory in its own managed workspace root and its own folder
rows, which synchronize to every device; the asking Mac writes none of them.
No Mac writes a folder bound to another Mac's
disk, resolves another Mac's path on its own, or offers to delete another
Mac's directory. The chat actions need positive authority on the Mac applying
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
record stays read-only, including across restarts. Agents are listed the same
way (`AgentPlacements`): a Mac lists as its own only the agents whose owner
record names it, and lists another member's agent under the workspace that
record leads to, by its plain harness name. An agent whose owner record, or
whose workspace's registry row (its Mac's, or its Linux host's), has not
arrived is listed nowhere, never under this Mac. Owner records, registry rows,
workspace names, and the workspace and trash flag of a chat's execution
projection advance the workspace change counter, so each view follows one
that arrives on its own.
Imported observations do not
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

Any Mac can name any workspace. The name is a shared row keyed
by the workspace's registry ID, so it reaches every paired Mac; a Linux host
relays the row and can never write it. The workspace's owner also publishes
the name as its registry name, which is what the iPhone, agents and devices
that have not updated show. Without a chosen name a Mac's workspace is titled
on the desktop with its tailnet machine name (the first label of its
`*.ts.net` address; a Dev instance adds `(Dev) · <instance>`, since it shares
the machine). The address is the registry row's, and when the row has none,
the one in the route this library keeps for that Mac (`mac_routes`, by its
library host ID, which is the row's `ownerDeviceID`), so the title and the
list's order do not change while a Mac is unreachable; the computer name it
registered is used only for a Mac with neither. A production Mac also keeps
the last address in its own row when it refreshes the registry while Tailscale
is unavailable; only a Dev instance publishes no address, which is how it
says it stopped. A Linux workspace is titled with the name from its setup,
which defaults to the first label of its host name (its tailnet machine
name); one registered under its full tailnet address, as a bots-only host
is, shows that label. The desktop's messages name a workspace by this title.

The desktop sidebar lists every other member's workspace, Mac or Linux, as one
list of remote workspaces (`RemoteWorkspaceSidebarModel.links`): a registry
row that is visible in connections and is known not to be this Mac's own,
merged with the Linux hosts this Mac set up. A Mac row is this Mac's when its
owner is this library's host or its folder owner is this Mac's; a Linux row
this Mac owns without a configuration for it is a host it removed. Until this
Mac has read its host ID, a row that cannot be told from its own is not
listed. An offline Mac stays listed. Another device's Dev instance is listed
only while that device is active (`ExecutionWorkspace.connections`), the same
projection the library host gives Settings → Workspaces, so a Dev instance
that quit without withdrawing its row drops out of the sidebar, New Chat and
Settings together. Folders are grouped under the row that names their
owner (`ExecutionWorkspace.displayOwner`; when a Mac registered several rows
for one device, such as a Dev instance beside it, the listed one), agents under
the row their owner record leads to. Each harness on a workspace is one row,
and one function picks the agent that stands for it everywhere
(`RemoteWorkspaceSidebarModel.choices`): this Mac's own while this Mac has
the harness ready there, else another member's, else this Mac's own. A chat
started from another member's agent for a Linux host is created on the host
by a request this Mac signs; that member's Mac is not involved.

Uninstalling a Linux workspace on the Mac that set it up marks its registry
row `deleted` (`LibraryHostController.withdrawRemovedLinuxWorkspaces`,
written by its owner against the row's revision), so every paired device
drops it. Only a completed uninstall does this: the removal is recorded on
that Mac and kept until the row is marked, and a row the Mac merely holds no
configuration for is never deleted, because a deleted identity cannot be
registered again. The same machine set up later is a new workspace with a new
ID.

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
a stable, visible **Recovered edit** note, except a Page or an Artifact's saved
inputs: concurrent versions of those merge on every device into the same result
(see [Pages](PAGES.md)), so nothing needs recovering. Other losing versions remain in
`peer_sync_conflicts` while they are still concurrent, and a losing library
item's version stays there with its bytes. Replaying a conflict cannot create
another copy.

Each device keeps only the versions that still matter (`peer_sync_versions`):
each row's frontier and the versions waiting for their bytes, each under the
cursor of one sequence. A new or newly kept version takes the next cursor and
the versions it supersedes are deleted, so a peer paging after its cursor
receives each row's current versions once. That is all it needs: a version it
misses was superseded by one that arrives later in the same order, and anything
it writes meanwhile is concurrent with that later version. A deletion records
the row's key and the columns that decide where it applies (its conversation,
workspace or device), never the old row.

Each pair retains separate push and receive cursors. Receive data and its cursor
commit together. The sender advances only after an acknowledgement for the exact
page. Process loss or a lost reply therefore retries durable identities. Peers
relay the original records, rather than inventing a new edit origin. Persistent
membership, routes, cursors, tombstones and recovery state survive restart. A
quarantined record is dropped once a version that covers it applies.

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
replaces constant polling. Peers must share the exchange format
(`PairedLibraryFormat`), and a mismatch is reported as "update required" rather
than partially applied. A release that only adds a shared table or column keeps
the format: a device that has not updated keeps the records it cannot apply
yet, relays them, and applies them once it updates
([Woven everywhere](architecture/WOVEN_EVERYWHERE.md), "Versions").
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
replacement never hides a grant from cleanup. Execution requests served by a
Mac are authorized live by their grant's provenance, so removing the requesting
Mac ends grants derived through it immediately. A Linux host authorizes by
token, so its grants end when the queued cleanup reaches it, which is eventual
while it is offline. A phone whose grant is rejected clears that workspace's
credential and requests a new one on its next workspace refresh. Grants cover
execution only: no Mac or Linux host serves inference to a phone, which uses
only its own sign-ins.

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

A library can hold rows older than the owner records, and paired libraries
may already hold each other's such rows. Nothing marks such a claim
as done once: every time a Mac opens its library for writing it claims the
unowned rows it has local evidence of having run, and nothing else.

- A conversation with a native session on this Mac (`harness_sessions`, which
  never synchronizes and is written only where the chat was created) and no
  independent execution: no projection onto a Linux host's or an iPhone's
  workspace. A projection onto a Mac's workspace is only paired-Mac routing
  and does not prevent the claim; one left by an earlier build, which guessed
  owners from who edited a chat, is removed when the Mac that owns the chat
  opens its library.
- A schedule with a run this Mac reserved for itself or sent (`calendar_runs`
  and the run's delivery, both local), unless its executor record assigns it
  to another device. A run a Linux host reported to the Mac that manages it
  is not evidence: such a schedule may be any Mac's. In a library that has
  never received peer data every other schedule is claimed too, and one
  assigned to a phone keeps that executor.
- Agents, once the Mac's device ID is known at startup: the ones that device
  ID created, and each agent the Mac ensures for itself.

An owner record that exists or was received always wins; who last edited a row
is never evidence, because any Mac may edit it; and a row without evidence
stays unclaimed and read-only until its owner's record arrives. Claims are
ordinary shared records, so two Macs claim disjoint rows and each learns the
other's on the next exchange, which also routes the other Mac's chats to it.
Once a library has received peer data, a schedule without that evidence on
any Mac stays unowned: no Mac runs it, and editing it does not claim it (only
creating a schedule does). A Linux host that a workspace's schedules are
handed to keeps running them whoever owns them.

Provider credentials remain in their original local storage. A fresh Dev snapshot drops copied peer routes,
membership state, counters and cursors, retaining source history without
connecting to production. It keeps the copied ownership records, and it has a
new device ID, no native sessions and every schedule assigned to a device that
does not exist, so a snapshot's new identity owns nothing it copied and never
runs another Mac's schedules, whether or not its source had owner records.

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
