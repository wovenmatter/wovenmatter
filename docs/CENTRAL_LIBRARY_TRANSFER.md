# Moving the central database to another Mac

In **Settings → Apple Devices → Database role**, choose **Change to node…**
on the current central Mac, select the destination Mac, then approve **Back up
and accept transfer** on that Mac. Both Macs must run a compatible version and
be reachable through Tailscale. Running agents and pending approvals must finish
before either database is frozen. A paired node can instead choose **Request
central role…**; the current central Mac still reviews the destination.

The destination merges its existing central SQLite library, even if that library
was preserved when the Mac became a node. Its current node replica is backed up
separately, and its unacknowledged writing and locally originated history are
imported without acknowledging or changing that original replica. Conflicting
writing gets recovery copies. Independent items with the same title keep their
separate identities. Deletions keep the original identity deleted; live writing
on the other side is recovered under a new identity. Saved artifact conflicts
also get independent recovery identities. Additional conflicting metadata is
retained exactly in `library_transfer_conflicts` and in the original backups.

The old central becomes a node after the destination has verified and activated
the merged database. **Continue and restart** finishes the application role
change. A destination that was a node also needs this restart before the source
can finish. Native agent sessions, execution files, provider accounts and
checkpoints stay on their original Mac. Scheduled work keeps its execution
owner; recovered conflicting schedules are not automatically scheduled.

## Backups and interrupted transfers

Each Mac retains its original database and library blobs under its workspace's
`Library Transfers` directory. The source uses
`<transfer-id>/source-backup`; the destination uses
`received/<transfer-id>/destination-backup/<backup-id>`. A node's replica backup
includes pending edits, local history, calendar state, dictations and saved
artifacts. Settings shows backup locations and the number of recovered items.
Backups are never automatically deleted.

The source exports a separate copy of its backup. Verification, origin routing
and merging never modify that original backup. Uploads resume from durable
byte offsets and verify each file's length and SHA-256 digest. The destination
checks SQLite integrity, approved source identity, pairing records and schema
compatibility before activation. Unsupported schemas and conflicting immutable
event identities stop the handoff without activating a partial merge.

Before activation is issued, cancelling restores ordinary writes on the old
central and destination. Once the source durably records its activation
decision, it cannot independently resume as central: it retries the saved
handoff until the destination confirms completion. A lost response or process
restart does not create a second central authority. Network interruptions retry
automatically; other failures remain visible with a saved **Retry transfer**
action. An authenticated destination cancellation can release an uncommitted
source. Do not restore a backup as another live central while the new central
is serving; use a coordinated return transfer or recovery with both hosts
stopped.

## Existing clients and workspaces

The destination keeps its canonical library identity and accepts the source's
identity and earlier transfer identities as aliases. Existing paired-device
credential verifiers are merged; revocation on either side remains effective.
Runtime execution credentials keep their original library/workspace scope.
The former central's execution API remains limited to its local workspace,
and existing workspace access denials remain in force.

Clients retain the exact IDs and contents of pending operations. A validated
move resets only central replay cursors, leaving local history, direct-workspace
cursors, receipts and pending operations intact. The former central returns an
authenticated move response. Clients also remember registry Mac endpoints and
can challenge a known candidate using a fresh nonce and the original device
credential's verifier. They send no bearer to a candidate before verifying its
proof; ordinary HTTP redirects remain disallowed.

An offline device does not need to pair again. It learns the new address when
either its previous central or a previously learned candidate is reachable.
There is no external location directory: a device that never learned the new
Mac's address must wait for a known route to return. Meanwhile it continues
saving local edits and working with already authorized reachable workspaces.

Each execution workspace publishes only its own history. Observer caches are
not relays. Linux owners retain their original publisher and MCP credentials;
the new central notifies them using a delegated enrollment/revocation/relocation
capability and retries offline owners. This capability does not authorize
workspace administration. A Linux owner needs a compatible service and a saved
delegation before the handoff. Provider credentials remain on that owner.

Central outages continue to affect only services hosted on the unavailable Mac,
new pairing/provisioning, and content that was never downloaded. Repositories,
ordinary workspace files and runtime checkpoints do not become library sync
content as a consequence of a transfer.
