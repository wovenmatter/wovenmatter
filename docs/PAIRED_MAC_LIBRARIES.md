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
workspace administrator capabilities remain local. Calendar ownership is recorded
separately from edit origin, so editing a schedule from another Mac does not
move its executor. Imported observations do not fire native-history capture
triggers or dispatch commands. Native workspace files are outside library sync.

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

Changes carry a Lamport counter and causal vector. A causal successor supersedes
its predecessor. Concurrent edits choose the same winner on every Mac using
counter and origin ordering, while preserving the losing value. Concurrent
deletion wins over editing an identity. Conflicting note content gets a stable,
visible **Recovered edit** note; exact other conflicts remain in
`paired_library_conflicts`. Replaying a conflict cannot create another copy.
An explicit later restore can supersede a deletion causally.

Each pair retains separate push and receive cursors. Receive data and its cursor
commit together. The sender advances only after an acknowledgement for the exact
page. Process loss or a lost reply therefore retries durable identities. Peers
relay the original records, rather than inventing a new edit origin. Persistent
membership, routes, cursors, tombstones and recovery state survive restart.

Large values are content-addressed separately from their row metadata. A receive
page can durably queue such a row until its bytes arrive, allowing other writing
to continue. File downloads retain byte offsets across restart, accept only the
expected next chunk, and verify size and SHA-256 before installing a local file.
Incomplete files never replace a completed copy. Individual values/files have a
256 MiB safety boundary; larger workspace outputs should remain workspace files.

## Pairing, membership and revocation

Both Macs negotiate `library.peers.v1`. Initial pairing keeps the existing
explicit approval and secret-bound claim flow. Macs can also paste a pairing
link from the other Mac; its pending confirmation and reciprocal join resume
with the same privately saved grants after a lost reply or restart. The approved requester installs
a reciprocal device grant; each side stores its own bearer in device-only
Keychain storage. Pending pairing secrets and bearers are absent from discovery,
shared SQLite data, UI snapshots and the peer journal.

Authenticated paired Macs exchange device verifiers and revoked verifier
tombstones. That membership lets any Mac add another Apple connection and lets
other paired Macs authenticate it after reconnection. Revocation is monotonic
for each credential. Explicit fresh pairing can issue a new credential for the
same device without reviving an old bearer. A learned address must answer a
fresh verifier-based challenge before receiving a bearer; redirects and cookies
are disabled. Merely appearing on the tailnet grants nothing.

Once routes and membership have propagated, Macs can contact each other directly,
including when the Mac that joined them is offline. There is no public directory:
a Mac must first learn a route through pairing, discovery or a connected peer.
Ordinary network loss retains local work and retries quietly. A revoked Mac
retains its local data but cannot use revoked credentials to resume syncing.
Unreachable execution owners apply queued revocations on reconnection.

Mobile devices keep their offline replica and approved Mac connection. Their
authenticated registry supports workspaces whose credential namespaces belong to
other paired Macs. This change does not turn phones into full desktop replicas
or automatically replace a mobile device's chosen library endpoint.

## Upgrade and recovery

Before the first peer import, each Mac saves a consistent, integrity-checked
`Paired Mac Backups/before-peer-sync.sqlite` snapshot. It includes committed WAL
content. The app never restores this automatically over subsequent writing.
Retain the original database and device-only credential vaults when recovering.

Older node preferences no longer select a reduced desktop interface. Upgrade
preserves the old replica and command journal, takes backups, and imports a
former node's native database on the same physical Mac. Its former execution
directory remains intact. Cached notes, conflicts and unsent composer text get
deterministic **Saved before pairing upgrade** notes. Pending note and folder operations
are retained and reconciled with their original identities when the existing
approved Mac reconnects. Migration does not replay pending agent commands.

SQLite recovery backups and original replica/native files preserve ambiguous
legacy collisions. Provider credentials remain in their original local storage.
The retired node's execution lease must be free before import; upgrade never
force-kills another owner. A fresh Dev snapshot drops copied peer routes,
membership state, counters and cursors, retaining source history without
connecting to production.

## Review and device test plan

Automated fixtures cover the persistent merge rules and actual Mac services with
in-memory credential vaults and controlled network/execution fixtures. No
provider services or real pairing credentials are consumed.

- Pair two Macs that each already have notes and history. Both should retain
  their normal workspace and sidebars, with no database-role selector.
- Disconnect them. Create and edit notes on both, including editing the same
  note. Reconnect and verify both converge, with conflicting writing recoverable.
- Delete a note on one Mac while editing it on the other. The original should
  stay deleted and the concurrent writing should remain in a recovered note.
- Add a remote workspace and an Apple connection from either Mac. Reconnect the
  other Mac and inspect the single workspace inventory and paired device roster.
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
