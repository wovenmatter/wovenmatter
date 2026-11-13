# Woven everywhere: devices, library and bots

This is the working contract for the change that makes every Woven Matter
surface reach every other one directly, gives every machine its own library
copy, and moves bots into this repository. Each workstream builds against the
interfaces here. When an interface has to change, change this document in the
same commit.

## Product rules

- **Everything reaches everything.** Once paired, every device reaches every
  other online device directly. No single Mac is ever required. Macs are the
  full user interface, the iPhone is a focused interface, and Linux machines
  are headless hosts.
- **One kind of machine.** Each Linux or macOS machine runs one Woven server.
  It hosts the workspace, a full library copy, Woven MCP and, when enabled,
  bots. A Linux machine may run bots without being a workspace; adding the
  workspace later reuses the same server. A Mac must have the Woven Matter
  desktop app installed by hand and be paired in Settings → Apple Devices
  before it can host bots.
- **Full access by default** for every harness everywhere, including sessions
  agents start. Agent-started sessions use the destination workspace's own
  saved defaults and are never capped by the caller. The UI shows each
  harness's own mode names, with every full mode shown as "Full access".
- **Nothing waits on a prompt.** Macs grant Keychain and macOS privacy
  permissions once from Settings. Each Mac's permission status reaches every
  device. Password prompts in sessions fail at once with a clear message.
- **No consent prompts** for sending data to providers the user signed in to.

## Membership and device keys

- Every device has a long-lived Curve25519 signing identity: the Mac Keychain,
  the iPhone Keychain, and a 0600 file on Linux under the Woven data root.
  This generalizes today's paired-Mac identity (`PairedMacIdentity.swift`): a
  Mac's member key *is* its paired-Mac signing key, and a Mac's or Linux
  host's device ID is its library replica identity
  (`library_identity.host_device_id`, the sync clock's origin). On
  Linux the key is `<library data root>/secrets/member-signing.key` (raw
  32-byte key, base64, created on first start).
- The **member list** is a synced, signed record set. Each member entry names
  the device ID, kind (`mac`, `linux`, `ios`), display name, public key,
  endpoints, the adding device and its signature. Any Mac member may add a
  device, because adding needs the UI. Removal is a signed revocation that
  every device applies as soon as it syncs.
  - Storage (`LibraryMembers.swift`, `MemberDirectory.swift`): shared rows
    `library_members(device_id, added_by, added_at, payload)` (newest entry per
    adder) and `library_member_revocations(event_id, device_id, payload)`, in
    the paired sync table set; local, unsynced `library_member_anchors`. Entry
    and revocation signatures are Ed25519 over the length-prefixed canonical
    encoding used by `PairedMacIdentity.swift`, domains
    `woven.member.entry.v1` (`device, kind, name, key, endpoints, added_by,
    added_at`) and `woven.member.revocation.v1` (`event, device, revoked_by,
    revoked_at`).
  - Resolution (`LibraryMemberResolver`): trust starts at local anchors and
    flows only through entries signed by Macs that still stand; see "Trust
    model" below. A device's kind comes from a Mac's entry; its own
    self-signed entry may change only its name and endpoints. Two live keys
    for one device: not trusted. Removing a Mac voids everything it signed,
    whatever the date; `MemberDirectory.remove` therefore first re-signs, from
    the removing Mac, the entries and removals of the removed Mac that this
    Mac still holds, so the devices it added stay. A newer entry from a
    standing Mac re-adds a removed device, with a new key if it presents one.
    Local, unsynced `library_member_pin_candidates` records when each Mac was
    first trusted, for pinning.
  - Adding: Mac↔Mac pairing (link or nearby request, then the signed join)
    records the other Mac on both sides. A phone that includes
    `memberPublicKey` (raw 32 bytes) in `PairRequest` gets an `ios`
    entry from the Mac it pairs with, signed when the phone confirms the
    pairing (`POST /v1/pair/confirm`), before its grant is issued; a pairing
    that is never confirmed adds no member. `POST /v1/pair` first checks that
    the Mac can add that key (`MemberDirectory.checkAdd`) and otherwise answers
    409 with the reason (`member_key_changed`) before the code is spent; it
    also returns `PairResponse.libraryIDs` (the libraries in its
    registry). Pairing a phone again on a Mac replaces its key
    (`add(…, replacingKey: true)`: a removal of the old key, then the new
    entry), as for a phone restored from a backup, whose Keychain key is this
    device only; a Mac's key never changes. Phones without a member key keep
    their bearer grant. A Linux host: the Mac that adds it reads `memberIdentity` from
    `GET /v1/host/status`, signs its entry (endpoint: `libraryEndpoint`, else
    `https://<host>/wovenmatter/`) and sends `POST /v1/host/members/adopt` with
    a `LibraryMemberAdoption` `{anchor: {deviceID, kind: "mac", publicKey},
    entries, revocations}` through the administrative link, signed and with
    the installer's bearer. The Linux server accepts the installer's API bearer
    only while the host has never been adopted (`GET /v1/members` reports
    `adopted: false`; anchors are never removed, so this stays true even once
    every Mac is removed); after that it needs a signed `mac` member request.
    A request whose signature does not verify but that carries the
    installer's bearer is handled as the bearer alone. The body reaches the
    library socket's `POST /v1/members/adopt` byte for byte. The first
    adoption anchors its Mac, which must have signed this host's current key.
    A later adoption only carries entries and removals (which also arrive by
    sync): its anchor must already be a standing Mac with the key this host
    trusts (else 400 `already_adopted`), and it never adds or replaces an
    anchor. Later member changes reach the host by peer sync.
  - When: the Mac that manages a Linux host over SSH sets it up as soon as it
    installs the host, installs it bots-only, or adds the workspace to a
    bots-only host, and again on each launch (`LibraryHostController.setUpLinuxHost`).
    Setup is the adoption above, then, for a host with a workspace, exposing
    and enrolling it (`provisionCentralExecutionWorkspace`: Tailscale Serve
    for its execution API, then the grant that registers the row's
    `endpoint` and `executionDeviceID`). Neither step waits for the other or
    for an earlier enrollment. A step that fails (the host's library still
    starting, the host offline) is retried after 5 seconds, doubling to at
    most 10 minutes, until both succeed; a bots-only host is only adopted.
    The trust rules above are unchanged: the installer's bearer still adopts
    only a host that was never adopted.
  - Upgrade: Macs paired before members existed (a key pinned by a signed
    join) are converted into members on launch. Phones and Linux hosts pair
    again. Library content is never touched.
- **Authentication between members: signed requests.** Every request from
  one member to another is signed with the caller's device key. Nothing is
  issued, cached or renewed, and nothing expires on a timer. Revoking a member
  takes effect as soon as the revocation syncs.
  - Headers:
    - `X-Woven-Member-Device`: the caller's device ID.
    - `X-Woven-Member-Audience`: the destination member's device ID. Every
      member keeps its own nonce cache, so without it a request captured on
      its way to one member could be replayed to another within the window.
    - `X-Woven-Member-Time`: Unix time in milliseconds.
    - `X-Woven-Member-Nonce`: 16 random bytes, base64url without padding.
    - `X-Woven-Member-Signature`: an Ed25519 signature, base64url without
      padding.
  - The signed message is the UTF-8 string
    `woven-member-v2\n<audience>\n<METHOD>\n<path with query>\n<time>\n<nonce>\n<hex SHA-256 of body>`.
    Device IDs (caller and audience) are lowercase UUIDs. An empty body
    hashes the empty string. There is no `v1` fallback. A WebSocket upgrade signs its
    `GET` request. The path is the request target exactly as the client
    sends it, except that a leading `/wovenmatter` mount is dropped
    (`MemberRequestSignature.canonicalTarget`: `/wovenmatter/v1/x?y` and
    `/v1/x?y` sign alike, `/wovenmatter?y` signs as `/?y`), because Tailscale
    Serve strips it before a Linux host sees the request while a Mac receives
    it intact. Any other prefix is signed as sent: a Swift client calling the
    Linux Node server through `/wovenmatter-execution/<id>/…` signs that full
    path, and the Node server, which sees the path with that prefix stripped,
    also accepts a signature over the path with it restored.
  - The verifier accepts a request when:
    - the audience is its own member device ID (checked first). A Linux
      host's Node server and library host share the machine's ID and keep
      separate nonce caches; their signed routes do not overlap, so a
      request for one does nothing at the other;
    - the device is on the current member list and not revoked;
    - the time is within 300 seconds of its own clock;
    - it has not seen the nonce in that window;
    - the signature verifies with the member's raw 32-byte Ed25519 public key.
      That key is CryptoKit `Curve25519.Signing` compatible, and Node verifies
      it with `crypto.verify(null, …)`.
  - **Where the audience comes from.** A caller takes the destination's
    device ID only from a signed or synced record, never from what the
    endpoint says about itself (a member that answered for another could
    otherwise collect requests to replay there): a member list entry
    (`deviceID` beside its `endpoints`; peer sync, Node's Mac delegate, the
    phone's host choice) or, for a workspace (execution, bots, host
    administration, inference, `/mcp/workspace`), `MemberAudience.serving`
    (shared Swift; Node `createMemberTransport().audienceFor`): the
    registry's `executionDeviceID` when that is an active member, or a Mac
    workspace's (a Mac's execution device is its member ID). A Linux host
    registers a new workspace with its member device ID as `executionDeviceID`
    too (`clientExecution.provision`, given the library host's identity), so
    the registry alone names its audience. Only for an older Linux record,
    whose Node server named its own random execution device ID, the audience
    falls back to the one active `linux` member whose advertised endpoints
    share the workspace endpoint's `.ts.net` host. Two members claiming one
    host: nobody. A Mac accepts a Linux host's
    `/mcp/workspace` call from that serving member as well as from the
    execution device. The installing Mac addresses its first adoption to the
    `memberIdentity.deviceID` it read over SSH. A phone learns the pairing
    Mac's ID from `PairResponse.hostDeviceID`. `GET /v1/identity`
    is used only by the Mac that is about to sign that host's entry. A
    workspace or host without a known device ID is not signed for
    (`member_audience_unknown`); the caller treats it as not reachable yet.
  - The shared test vectors in
    `shared/Tests/WovenMatterSharedTests/MemberSignatureVectors.json`
    (regenerate with `generate-member-signature-vectors.mjs` there) are
    checked by Swift (CryptoKit, and swift-crypto through
    `MemberSyncTests`) and by Node (`remote/test/member-auth.test.mjs`),
    including an `audience-changed` reject.
- Pairing a new device still uses the existing pairing link and confirmation
  UI on a Mac. Its result is a signed member entry instead of a bearer grant.
- The Linux Node server verifies member signatures itself. It reads the member
  list from its local library host (`GET /v1/members` on the library socket),
  which returns each member's `deviceID`, `kind`, `name`, `publicKey`
  (base64), `endpoints` and `revoked`, plus a `revision`.
  The list is cached by `revision`, reloaded every 15 seconds and, at most
  every 2 seconds, when an unknown device signs.
- On the Linux server (`remote/src/server.mjs`, `member-auth.mjs`), a signed
  request from any member gets what a device grant had: execution and
  inference routes, `GET /v1/bots/status|resources` and `GET /v1/bots/ws`. A
  `mac` member is also an administrator, like the installing Mac's bearer:
  every administrator route, the bots changes and `/v1/host/*`. The bearers
  it still accepts are listed under "Bearers that remain".
- Swift (`shared/…/MemberRequestSignature.swift`): `MemberRequestSigner`
  (`headers(method:target:body:audience:)`, or `bodySHA256:` for a hashed
  body) and `MemberRequestVerifier(audience:…)` (own device ID, nonce cache,
  window) are portable; `MemberIdentity.signer` and `MemberDirectory.verifier`
  bind them to a device key and the resolved list. Node:
  `signMemberRequest({…, audience})` and `createMemberVerifier({loadMembers,
  audience})`, where the server's audience is its library host's identity.
  `MemberDirectory.authenticate(_:allowing:)` checks any request (the Mac's
  bots WebSocket upgrade uses it through
  `LibraryHostController.authenticateMember`). On a Mac, signed requests are
  accepted on peer sync (`mac`, `linux`), the mobile API and `/mcp` (`ios`,
  `mac`), `/v1/execution/*` (`mac`, `ios`, `linux`; no execution grant
  needed), `/mcp/workspace` and `/mcp/workspace/prepare` (`linux` only; see
  "Sessions across devices") and `/v1/bots/*` (`mac`, `ios`; signed only, no
  grant). The inference host takes signed `ios` and `mac` members too
  ("iPhone reach").
- Swift clients sign with `MemberSignedHTTPClient(endpoint:signer:audience:)`
  (`app/Sources/WovenMatterClient`): the target is the exact path sent, so a
  Mac endpoint (`https://<mac>.<tailnet>.ts.net:<port>/wovenmatter`, no
  trailing slash) signs `/wovenmatter/…` and a Linux execution endpoint
  (`…/wovenmatter-execution/<id>/`) signs its full path. The Mac app's
  `SignedExecutionWorkspaceTransport` replaces execution grants for every
  other Mac and Linux workspace with a known `executionDeviceID`; a signed
  refusal is final ("does not recognize this Mac yet" until the member lists
  synchronize). Nothing is provisioned or saved: a workspace this Mac cannot
  sign for (its serving member is unknown) is not reachable yet.
- Node signs through its library host: `POST /v1/members/sign` on the
  library socket returns the headers for one request, so the Linux private
  key never leaves `wovenmatter-library` (`remote/src/member-client.mjs`).
  Node signs only for tailnet HTTPS endpoints (`https://*.ts.net`). The
  library host signs only the requests Node makes
  (`LibraryHost.signableAudiences`): the execution API (`GET
  /v1/execution/{providers,conversations,interactions}`, `GET
  /v1/execution/conversations/<uuid>/{transcript[?before=…],capabilities}`,
  `POST /v1/execution/commands`) to an active `mac` or `linux` member, and
  `POST /mcp/workspace[/prepare]` to an active `mac` member, under a
  `/wovenmatter` or `/wovenmatter-execution/<id>` base; anything else is 403
  `not_signable`. The whole local socket answers only the Node server that
  launched the library host: when its parent process is `node`, a connection
  is admitted only if the kernel names that parent as the peer
  (`SO_PEERCRED`) and the host has not been orphaned, so another program of
  the same account that reads the token file can neither sign as this
  machine nor call its tools with its own tool selection. Limit: code of the
  same account that can attach to the Node process (`ptrace`, refused by the
  default Yama `ptrace_scope=1` for non-descendants) or that replaces the
  installed service could still act as it; only a separate account for the
  agents would remove that, which their full-access contract rules out.
- Remote host administration (status, logs, restart, update) is available to
  every Mac member, as signed requests to the Linux server:
  `GET /v1/host/status` (remote-host.sh `status` plus `library` and
  `memberIdentity`), `GET /v1/host/logs?lines=N`, `POST /v1/host/restart`
  (202), `POST /v1/host/bots-configure {poolBytes, diskBytes}` (bytes or
  `null`), and `POST /v1/host/update?fingerprint=<sha256>[&roles=…]` whose body
  is the host bundle (202; `GET /v1/host/update` reports `running`,
  `succeeded` with the status, or `failed` with the error), plus `POST
  /v1/host/members/adopt` (above). A signed upload is received (streamed to
  `<state>/host-update/bundle-*.stream`) only when the claimed member is a
  Mac or the installer's bearer comes with it, so other members get 403
  before any of it is written; the file is removed on every outcome except a
  started update, whose unit removes it when done. Restart and update
  run in a transient systemd user unit, because they stop the server. First
  install still runs over Tailscale SSH from the Mac that adds the machine,
  which also keeps SSH as its update fallback. Every other Mac lists every
  Linux host in the synced registry (Settings → Workspaces, "From other
  devices") and manages it with these signed routes
  (`RemoteHostAdministrationClient`): status, logs, restart, bots-configure
  and update, which uploads this Mac's host bundle and polls `GET
  /v1/host/update`. Nothing says which Mac added a host. "Update everything"
  (`BotUpdatePlan.Step.linuxHost`) updates every Linux host in the registry
  this way (`RemoteWorkspacesModel.runSharedHost(_:.update)`); SSH is only
  the fallback for a host this Mac added. A Linux host's sessions use any
  Mac's `/mcp/workspace` once the session's `execution_conversations`
  row has synchronized there, whichever Mac added the host. On a Mac, other
  Macs' agents (including those for Linux hosts they added) sync as peer
  agents (`pairedAgentWorkspaces`), and a new chat with one is created on its
  workspace with signed requests (`createPairedMacSession`).
- Bots are not members. Each bot has its own Woven MCP key (see Bots).
- **Bearers that remain**, and why:
  - The installer's API bearer, through the SSH tunnel of the Mac that added
    a host: first install, the first member adoption (before the host was ever
    adopted), the SSH update fallback, that Mac's own management link
    (`RemoteWorkspaceServiceClient`) and a bots-only host that is not in the
    registry. **Installer bearer:** the server accepts it only on that
    SSH/loopback path, never through Tailscale Serve: a request carrying any
    header Serve adds (`X-Forwarded-For`, `X-Forwarded-Host`,
    `X-Forwarded-Proto`, `Forwarded`, `Via`, `Tailscale-User-*`,
    `Tailscale-Headers-Info`, `Tailscale-App-Capabilities`) is never the
    installer (`remote/src/installer-bearer.mjs`). `POST
    /v1/host/installer-bearer` (a signed Mac member, or the installer itself)
    rotates it: `remote-host.sh rotate-token ID` writes a new
    `WOVENMATTER_API_TOKEN` to `service.env` and the running server switches
    to it at once, closing (`4401`) every bots relay the old bearer opened;
    the reply is `{rotated: true}`, plus `bearer` only for the
    installer on its own tunnel. A Mac that removes another Mac queues a
    rotation (durably, retried with pending revocations,
    user-defaults key `library.execution.pending-installer-rotations`) on every Linux host in
    the registry whose `ownerDeviceID` is the removed Mac.
  - Outside-client and session MCP bearers (`/mcp`, agent tool sessions),
    bot MCP keys (bots are not members), the runtime host API
    (`/v1/bots-host/*`) and runtime token, and the library socket's local
    bearer: none of these is a call between members.
  - The phone's pairing credential, which confirms (`POST /v1/pair/confirm`)
    and ends (`/v1/pair/unpair`) a pairing. Every other request the phone
    makes is signed.

### Trust model

Every device decides membership for itself, from its own anchors
(`LibraryMemberResolver.resolve(…, own:)`). Signed times only order records
among Macs that still stand; they never decide who wins a dispute.

- **Anchors.** This device (removed only by itself), the Mac that adopted a
  Linux host, and every Mac this device has trusted continuously for 24 hours
  (pinned in `library_member_anchors`, never synced, never removed, key never
  replaced). A pinned Mac stays a root when the Mac that introduced it is
  removed, but it can itself be removed. The wait keeps a Mac vouched for by a
  key whose removal is still on its way from ever being pinned.
- **Entries** count while their signer stands and while they are newer than
  every effective removal of their device. Everything a removed Mac signed is
  void, so backdating does nothing; a removal older than a standing Mac's
  entry for the device does nothing either. Records dated more than 10
  minutes ahead are ignored until then. A new signature from this device is
  dated after every record about that device it holds
  (`MemberDirectory.after`), so clock skew never hides it.
- **Removals** are effective when a standing Mac (or the device itself)
  signed them. A Mac that removed this device, unless a standing Mac re-added
  this device afterwards, removes nobody here. Removals that depend on each
  other are settled from the anchors outward (the well-founded alternating
  fixpoint): a Mac stands only if no Mac that might stand removed it.
- **What this guarantees.** Once an honest Mac's removal of a stolen key
  reaches a device, that key is untrusted there for good, whatever it signs
  or dates. A stolen key that removes honest Macs is itself ignored by every
  device it removed, so the honest Macs keep trusting each other there.
- **Limits.** While a stolen Mac key is not yet removed it is a member and can
  do anything a Mac can (add devices, remove devices); removing it re-signs
  the devices it added, so review the device list afterwards. On a device the
  attacker did not remove, an honest Mac and the attacker that removed each
  other both lose, and so does every Mac the attacker removed there, until
  that device's own user re-adds the honest Macs; a Linux host in that state
  is added again. A device that knew the other Macs only through the removed
  Mac, and had not yet pinned them, pairs again with a remaining Mac.

## Library on every surface

- Macs and Linux machines hold a full library database and run the same Swift
  library code: `WovenMatterDashboardStore` and its dependencies, built for
  Linux. Linux has no rendering; agents read and edit notes, calendar, history
  and artifacts through the database with the exact same code as the Mac
  (`NoteDocument`, `applyNoteEdits`, receipts, versions).
- On Linux this code runs as the `wovenmatter-library` executable, which the
  Node server supervises. It listens on a loopback port and a Unix socket. It
  serves:
  - the peer sync protocol (today's paired-Mac protocol, generalized to all
    members);
  - the mobile library API that the iPhone uses (today's
    `DeviceAPI` and `FederationAPI`), so a phone can sync
    with any Mac or Linux machine;
  - the library-backed Woven MCP tool groups (notes, history, calendar,
    library, artifacts) for the local Node server, replacing today's relay to
    one Mac's `/mcp/workspace`.
  The peer and mobile routes are published with Tailscale Serve on the host,
  under the same path layout a Mac uses (`/wovenmatter`).
- **Sync** is peer-to-peer among every online member, using the existing
  row-level replication (`PairedLibraryStore`: change log, version vectors,
  per-peer cursors, conflict copies). A local change is announced to online
  peers once and batched; a device that comes online catches up once. There is
  no constant polling: today's 5-second loop becomes change-driven, with a
  slow presence check.
  - `LibraryPeerSync` (store package) runs it on Macs and Linux hosts, between
    `mac` and `linux` members only, all signed: `POST /v1/peers/sync`
    (`LibraryPeerExchange {deviceID, after, page, version, attachment?}`: push
    this device's page after its last pushed cursor, receive the peer's after
    `after`; repeated until neither has more). `after` is the caller's
    committed receive cursor for the answering device, so the answering
    device also records it as what that caller holds (its pushed cursor for
    the caller becomes the larger of the two, never past its own change log)
    and its own later pushes start there. At most the last page of an exchange
    is sent back once, as an idempotent echo. `POST /v1/peers/notify
    {deviceID, cursor}` (the receiver pulls when `cursor` is past what it has),
    `POST /v1/peers/files` and `POST /v1/peers/file` (content-addressed files,
    as before). A device sends only to advertised endpoints that are tailnet
    HTTPS (`LibraryPeerSync.isTailnetEndpoint`: `https://<name>.ts.net`, no
    credentials, query or fragment), as Node and the phone do.
  - Only a real change enters the change log: an update that leaves every
    column as it was records nothing. Writers that run on a timer compare
    first: the Mac's 5-second registry refresh rewrites a
    `paired_remote_workspaces` configuration (stored as sorted-key JSON) or a
    `execution_workspaces` registration only when its decoded value
    changed.
  - Triggers: a write that appends to the change log
    (`WorkspaceDatabase.observePeerChanges`) is announced, debounced 300 ms,
    to peers that are online; starting, a newly learned member and a contact
    from a peer each catch up once; a presence check every 60 s (doubling to
    15 minutes for an offline peer) is the only timer. `resume(reason:)`
    clears every backoff and catches up with each peer once: on a Mac on wake
    (`NSWorkspace.didWakeNotification`) and on a network path change
    (`NWPathMonitor`); on Linux when a presence tick comes far later than
    scheduled (the machine slept) or the interfaces' addresses changed. Any
    signed request from a peer that was not online clears its backoff and
    catches it up. A notice that arrives during "Sync now" runs once more
    afterwards.
  - Receiving (`PairedLibraryStore.peerRecordAllowed`, given the sending
    member as `PairedLibrarySender`): origins are self-declared and records
    are relayed, so rows whose meaning depends on their author are checked
    against the sender. Member entries and removals are never deleted, must
    match their signed payload, never roll back to an older entry and never
    rewrite a removal (otherwise quarantined, or skipped when merely stale).
    A Linux host (any sender but a Mac) writes `execution_workspaces`
    only for the workspace it serves itself (`MemberAudience.serving`, before
    and after the change), `execution_conversations` only for that
    workspace's sessions, owner rows (`paired_*_owners`,
    `calendar_task_executors`, `calendar_run_publishers`) only naming
    itself, and never `paired_mac_routes` or `paired_remote_workspaces`. Other
    such rows it relays are skipped; they arrive from a Mac directly.
  - HTTP deadlines (both the Mac listener and `LibrarySocketHTTPServer`,
    `LibraryHTTPParser.Deadlines`): the request head within 15 s; then the
    body for up to 15 minutes as long as bytes arrive at least every 30 s; a
    complete request is answered within 60 s, and a reply being written may
    take up to 15 minutes while it moves. An 8 MiB page or a 64 MiB upload
    over a slow relayed path therefore completes.
  - A Mac also carries its bearer-era pairing roster (`PeerMembership`) in
    `attachment` until phones pair as members; Linux hosts send none.
- Linux session history is written into the machine's own library copy, which
  then syncs everywhere. That replaces the per-Mac publisher outbox.
- **iPhone sync set.** Full copies of notes, Quick Chats with their
  transcripts, calendar, and timers and reminders. The list of every session
  on every device, with title and status. Transcripts for very recent
  sessions (updated in the last 3 days, or running), plus any session the
  user opens or keeps offline. Large files are fetched when opened.
- **Versions.** Sync requires matching schemas (`PairedLibraryStore` already
  rejects a mismatch). The schema is the SHA-256 hash of the shared tables
  (`PairedLibraryTables`): per table, its column names with their declared
  types, sorted by name, and its key columns in key order. Physical column
  order is not part of it, so a library migrated over many releases (columns
  added at the end) and a freshly created one, such as a Linux host's, agree;
  rows are exchanged by column name. A column that only older libraries still
  have is removed by a migration rather than tolerated: opening a library
  drops `dashboard_conversations.is_main` (unused since September 2026) and
  removes it from the change log and merge state. Builds before this format
  computed the hash over physical column order, so every device must run a
  build with this format to sync; an older one answers or receives
  `update_required`. When peers disagree, every device shows which part
  needs updating and offers "Update everything". There is no compatibility
  layer. A mismatched exchange answers 409 `{code: "update_required",
  message, version, schema}`; `LibrarySyncStatus` (`{deviceID, version,
  schema, peers: [{deviceID, name, kind, state: online|offline|updateRequired|failing,
  version, lastSynchronized, lastContact, error}], conflicts, quarantined}`,
  `updateRequired`) is on the Mac's `LibraryHostSnapshot.librarySync`, the
  library socket's `GET /v1/sync/status` and, for phones, the mobile API's
  signed `GET /v1/sync/status` on every Mac and Linux host. On a Mac, a peer
  in `updateRequired` raises the same "Versions don't match" / "Update
  everything" notice as a bots version mismatch (`ApplicationModel+Bots.swift`).

- **Storage names.** Table names say what a table holds:
  - `library_identity` holds this replica's device ID (`host_device_id`) and the library's ID (`library_id`), which every paired device names.
  - `paired_*` is peer sync between Macs and Linux hosts: the change log, cursors, version vectors and conflicts, plus the owner rows.
  - `execution_*` is execution workspaces, this Mac's own included, with their journals, conversations, runs, adoptions, receipts, settlements, native history, and their scheduled MCP callers. Most of it is peer-synced library content (`PairedLibraryTables`).
  - `calendar_task_executors` names the device that runs each scheduled item; `paired_calendar_owners` names the Mac that owns the row. `calendar_run_publishers` and `calendar_published_runs` are who may report runs and the runs they reported. `calendar_replica_context` and `calendar_execution_conflicts` belong to a replica that executes another library's schedule.
  - `device_*` is what the library keeps for devices that reach it over the device API: the phone change feed (`device_sync_revisions`, `device_sync_changes`, written by the `device_sync_*` triggers), mutation, command, draft, tool and calendar receipts, scheduled MCP callers, saved files and message provenance.
  - `library_items`, `library_messages`, `library_settings` and `library_locations` index the Library pane (files and links found in chats); `library_members*` is the signed member list.

  Libraries created before November 2026 used `companion_*` names for all of these, and kept the library ID in `companion_workspace`. Opening such a library renames the tables in place, moves the library ID into `library_identity`, drops the old triggers (each is recreated under its new name) and rewrites the table names in peer sync bookkeeping, so nothing is lost or sent again (`renameLegacyCompanionStorageUnlocked`). The paired-devices file (`companion-devices.json`, now `library-devices.json`), the desktop's `companion.*` settings and its pairing credential and member key in the Keychain (`com.wovenmatter.companion.*`) move once in the same way.

### Library host (`wovenmatter-library`)

The `wovenmatter-library` executable (`app/Sources/WovenMatterLibraryDaemon`,
logic in `WovenMatterLibraryHost`) builds for Linux and macOS. Linux hosts run
the statically linked build described under "Linux build".

**Command line.** Every path is explicit or derived from `--data-root`; there
is no default production location.

```
wovenmatter-library --data-root DIR [--port N] [--socket PATH] [--token-file PATH]
                    [--harness-catalog PATH] [--name NAME] [--endpoint URL]... [--migrate-only]
wovenmatter-library --data-root DIR --identity
wovenmatter-library --data-root DIR --adopt-members FILE|-
wovenmatter-library --version
```

- `--port N`: loopback TCP port (127.0.0.1 only). `0`, the default, picks a
  free port.
- `--socket PATH`: the local API's Unix socket, default `DIR/run/library.sock`.
- `--token-file PATH`: the local API bearer, default `DIR/run/library-api.token`.
- `--harness-catalog PATH`: the shared `harnesses/catalog.json`; by default the
  copy a host release ships three directories above the binary.
- `--migrate-only`: open and migrate the database, print
  `{"event":"migrated"}` and exit. Use it to verify an install or update.
- `--name NAME`, `--endpoint URL` (repeatable): this machine's own member
  entry (name, base URLs such as `https://host.tailnet.ts.net/wovenmatter/`).
- `--identity`: print `{deviceID, kind, name, publicKey, endpoints}` and exit.
- `--adopt-members FILE|-`: apply a `LibraryMemberAdoption`, print the member
  list and exit (the same as the socket's `POST /v1/members/adopt`).
- When both listeners are ready it prints one line to stdout and writes the
  same object to `DIR/run/library.json` (0600):
  `{"event":"ready","pid":N,"port":N,"socket":"…","version":"1","schema":"<hex>"}`,
  where `schema` is the paired-library schema hash (`pairedLibrarySchema()`),
  which the Node server reports as `librarySchema`. SIGTERM or
  SIGINT stops it cleanly and removes that file. Exit codes: 0 clean, 1
  startup failure, 64 usage.

**Data layout.** The root and every directory it creates are 0700 and must be
owned by the running user.

| Path | Contents |
| --- | --- |
| `DIR/library/` | The `DashboardStore` support directory: `workspace.sqlite` (+ WAL), `dashboard-device-id` (this machine's device ID), library and attachment files |
| `DIR/secrets/` | 0600 files that replace Keychain items (`LinuxSecretStore`), one per generic-password item, and `member-signing.key` (this machine's member key) |
| `DIR/run/library.sock` | Local API socket, 0600; peers must also be this user (checked with `SO_PEERCRED`) and, when the host was launched by `node`, that very parent process (see "Node signs through its library host") |
| `DIR/run/library-api.token` | Local API bearer, 0600, 43–256 base64url characters. The Node server may create it before starting the host; otherwise the host creates it |
| `DIR/run/library.json` | Ready record (above) |
| `DIR/foundation/` | Linux Foundation's own per-user files (URLSession's cookie store and URL cache): the host points `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` here at startup, so nothing lands in `~/.local/share` or `~/.cache` |

**Loopback routes** (published with Tailscale Serve under `/wovenmatter`,
which the host strips):

- `GET /v1/health` → `{"status":"ok","service":"wovenmatter-library","version":"1","deviceID":"…","uptimeSeconds":N}`,
  or 503 when the database is unavailable. Unauthenticated; it reveals only
  the device ID, which is the member device ID.
- `GET /v1/identity` → `{deviceID, kind: "linux", name, publicKey, endpoints}`.
  Unauthenticated: the adding Mac signs this key.
- Peer sync (`/v1/peers/sync`, `notify`, `files`, `file`; signed by a `mac` or
  `linux` member) and the mobile library API (`LibraryHost.mobilePrefixes`:
  `/v1/hello`, `/v1/snapshot`, `/v1/changes`, `/v1/mutations`, `/v1/commands`,
  `/v1/federation/…`, `/v1/calendar…`, `/v1/dictations`, `/v1/notes/…`,
  `/v1/assets/…`, `/v1/sessions/…`, `/v1/devices`, `/v1/providers`,
  `/v1/pending`, `/v1/workspace-read`, `/v1/sync/status`, `/v1/members`, `/mcp`; signed by an `ios` or `mac`
  member only, no bearer) are mounted with `LibraryHost.mount(prefix:_:)`.
  Sessions are not started through it (`unsupported`). Other paths return 404.
  Sync starts once both listeners are ready.

**Local API** (Unix socket, for this machine's Node server). Every request
carries `Authorization: Bearer <token file contents>`. Requests are HTTP/1.1,
one per connection, with `Host`; POST bodies are `application/json`.

- `GET /v1/health`: as above.
- `POST /v1/callers` registers a conversation as a local session so tool
  effects (notes, receipts, versions, mutation history) are attributed to it:
  `{"conversationID":"<uuid>","title":"…","runtimeKind":"default_agent","workingDirectory":"/home/…","enabledGroups":["notes","calendar"]}`
  (only `conversationID` is required) →
  `{"conversationID":"<uuid>","enabledGroups":"calendar,notes"}`.
- `POST /v1/mcp`: stateless MCP JSON-RPC (`initialize`, `ping`, `tools/list`,
  `tools/call`), the same messages the Node server sends a Mac's
  `/mcp/workspace` today. Headers: `X-Woven-Conversation-ID` (the caller, a
  UUID; registered on first use), `X-Woven-Enabled-Groups` (comma-separated,
  the caller's current selection; the Node server is the authority for its own
  sessions' tool policy), optional `X-Woven-Context-ID` and
  `MCP-Protocol-Version`. Served groups: `notes` (including spreadsheet and
  HTML note artifacts), `history`, `calendar`, `library` and `timers` (see
  "Timers on a library host"), plus
  `woven_context` and, from `sessions`, only `woven_sessions_folders`
  (`LibraryHost.servedTools`; folders are library rows). Other tools are not
  listed and are refused; `woven_html_render`
  needs the caller's active run and stays in the Node server until Linux
  session history is written into this library. A `tools/call` result's
  `structuredContent` is the `WovenMatterToolResponse`
  (`{success,result,error,code,requestID}`); errors use the usual codes
  (`tool_disabled`, `revision_required`, `revision_conflict`, `not_found`, …).
  Integer `after` cursors (and `nextCursor`) stay within 0…2^53−1
  (`WorkspaceToolExecutor.maximumCursor`, also the newest-first start), since
  tool results carry numbers as Double and JavaScript callers parse them as
  one; a larger `after` is refused rather than rounded.

- Bot callers on `POST /v1/mcp`: instead of `X-Woven-Conversation-ID`, send
  `X-Woven-Caller: woven:bot:<machine-device-id>:<bot-id>` (use this host's
  member device ID from `/v1/identity`), `X-Woven-Bot-ID: <bot-id>` (must
  match), `X-Woven-Bot-Name` (percent-encoded) and `X-Woven-Enabled-Groups`.
  The bot is an app-wide caller (`WovenMCPCaller.isAppWide`), registered on
  first use; its tools are this library's `botMCP` groups (synced Woven
  settings) intersected with the served groups and the server's selection.
  `woven_context` is not offered to bots.

Membership, publishing and bot routes on the local API
(`remote/src/library-host.mjs` calls them):

- `GET /v1/identity`: as on loopback.
- `GET /v1/members` → `{revision, adopted, members: [{deviceID, kind, name, publicKey
  (base64), endpoints, addedBy, revoked}]}` (see "Membership"). `revision` is
  an opaque string that changes whenever the resolved list changes; `adopted`
  is true once this host anchored a Mac, and stays true.
- `POST /v1/members/adopt` (`LibraryMemberAdoption`) → the member list, or 400
  `invalid_member` or `already_adopted` (see "Adding").
- `POST /v1/members/self {name?, endpoints}` updates this machine's own
  entry; the server sends it (`{name: hostname, endpoints: [<published
  library route>]}`) after each Serve publish so peers use that address.
- `POST /v1/members/sign {method, target, bodySHA256, audience}` →
  `{headers: {X-Woven-Member-Device, X-Woven-Member-Audience,
  X-Woven-Member-Time, X-Woven-Member-Nonce, X-Woven-Member-Signature}}`:
  signs one outgoing request of the Node server with this machine's member
  key. `target` is the path with query exactly as sent (an absolute,
  printable ASCII target of at most 8 KiB), `bodySHA256` the body's lowercase
  hex SHA-256 and `audience` the destination member's lowercase device ID
  (not this machine's, an active member of the kind the route is for); only
  the method and route pairs listed under "Node signs through its library
  host" are signed, anything else is 403 `not_signable`. Only
  the socket serves it: on loopback every `/v1/members/…` path is 404, and
  mounts match whole path segments. `remote/src/member-client.mjs` requires
  `audience` on every request (`macs()` entries and registry rows carry it).
- `GET /v1/workspaces` → `{workspaces: [ExecutionWorkspace]}`: the
  synced execution workspace registry (every Mac, Linux and iPhone
  workspace this library knows, deleted ones left out), which the server
  routes cross-workspace sessions with.
- `GET /v1/sync/status` → `LibrarySyncStatus`.
- `POST /v1/timers/due` (`{}`) → `{occurrences: [{timerID, deliveryID, target,
  kind: "session"|"bot", botID?, text}], nextFireAt?}` and `POST
  /v1/timers/settle {timerID, deliveryID, outcome: "accepted"|"retry"|"cancelled",
  reason?}` (`LibraryHostTimers`); see "Timers on a library host".
- `POST /v1/publisher/{journal,retained/settle,association,artifacts/register,artifacts/chunk,artifacts/commit}`:
  this machine's execution history and saved artifacts, written into this
  library copy (the only way a Linux host publishes history). The workspace is the one the entries (or the artifact
  manifest, or `association`'s body `workspaceID` / `X-Woven-Workspace-ID`)
  name; it must be a Linux execution workspace this library knows (its
  descriptor arrives with the adding Mac's records; until then 403
  `wrong_owner`), and history is attributed to its execution device. A batch
  may carry this library's ID or the workspace's (the adding Mac's) library
  ID; the reply keeps the caller's.
- `POST /v1/bots/{botID}/entries`: a runtime conversation batch (`{bot,
  conversations, entries}`, see "Runtime host API"), recorded with
  `WorkspaceDatabase.recordBotConversation(machineID:_:)` under this host's
  member device ID → `{conversations, entries, added}`.
- `DELETE /v1/bots/{botID}/conversations`: the bot was deleted; marks its
  conversations deleted with `WorkspaceDatabase.deleteBotConversations(machineID:botID:)`
  under this host's member device ID (entries stay) → `{deleted: true}`.

**Node server supervision** (`remote/src/library-host.mjs`, wired in
`server.mjs`). On native Linux hosts the server starts
`<release>/host/library/linux-<arch>/wovenmatter-library --data-root <Woven data
root> --port P --socket <root>/run/library.sock --token-file
<root>/run/library-api.token --harness-catalog <release>/harnesses/catalog.json`,
so the library lives at `<data root>/library/workspace.sqlite`. It creates the
token first, keeps the loopback port in `<state>/library/host.json` so the
Serve route stays valid, waits for the ready line (or `library.json`),
restarts a crash with backoff up to 30 s and stops it on SIGTERM. After each
start it publishes the loopback port with `tailscale serve --bg --https=<port>
--set-path=/wovenmatter` (the first of 8443, 10000, 8444, 8445 with no TCP
route, as a Mac chooses; the recorded route is updated in place, never
Funnel; recorded in `<state>/library/serve.json`, removed by uninstall), and
writes `<state>/library/identity.json` (`{deviceID, kind, name, publicKey,
endpoints, libraryEndpoint, updatedAt}`, 0600), which `remote-host.sh inspect`
and `status` return as `memberIdentity` for the Mac that creates this
machine's member entry; `/v1/health` reports it too. `remote-host.sh
install|update` runs `--migrate-only` after stopping the old service and
before switching releases. **Host updates** then commit in two steps. The new
service first starts with `WOVENMATTER_LIBRARY=0` for the health check and
browser selftest, so nothing serves or synchronizes the migrated database
yet; a failure up to here (migration included) restores the database files
and the previous release. Restarting with the library host on commits the
update: once it may have served peers or phones, restoring the old change
log, clock and cursors would make peers skip this host's next writes and lose
acknowledged phone mutations, and the old release cannot be assumed to open
the migrated schema. So nothing is rolled back after that point; a later
failure (`host_health_failed`, "the migrated library was kept") is reported
with the new version left installed. Isolated tests use
`WOVENMATTER_LIBRARY_BINARY`, `WOVENMATTER_LIBRARY_DATA_ROOT`,
`WOVENMATTER_LIBRARY_SERVE=0` or `WOVENMATTER_LIBRARY_HTTPS_PORT`;
`WOVENMATTER_LIBRARY=0` turns it off.

The server sends a session's notes, history, calendar, library and timer tools to
`POST /v1/mcp` (registering it with `POST /v1/callers` first), so they work
with every Mac offline. History the caller may
read only through its managed sessions, and all history while the library host
is down, comes from the Node journal. Databases, `woven_context` and
`woven_html_render` stay in Node, and so do sessions on other workspaces
("Sessions across devices"). `woven_sessions_folders` goes to `/v1/mcp`.
Bot callers' library tools go to `/v1/mcp` as app-wide callers (above), with
`X-Woven-Caller` built from this host's member device ID.

Tools that only a Mac serves (usage, which is the Mac's own provider usage
data, HTML preview, which needs a Mac's renderer, and a scheduled task's tool
policy, which the Mac that holds the schedule decides) go to any Mac member, signed with this host's key: `POST
<mac endpoint>/mcp/workspace` (and `/mcp/workspace/prepare` with the task
proof) with `X-Woven-Protocol: 3`, `X-Woven-Workspace-ID: <this workspace>`,
`X-Woven-Conversation-ID`, `X-Woven-Enabled-Groups` and
`MCP-Protocol-Version`, and no bearer (`createMemberMacDelegate`). Macs are
tried in sync-status order, online first; another Mac is tried only when the
request never reached one or was refused before any effect (401, 403, 404,
426, 503). The Mac accepts the call when the signer serves that non-deleted
Linux workspace (its execution device, or the member `MemberAudience.serving`
names) and the conversation belongs to it. A scheduled task's caller record
(`device_scheduled_mcp_callers`, written by `/mcp/workspace/prepare`) is not
synced, so another Mac refuses the task's calls until the session's own row
reaches it. The Node delegate therefore sends a task's calls to the Mac that
last prepared it first, and prepares any other Mac (the same idempotent
request) before asking it, so prepare and call always land on the same Mac. Bots
never use this route (a Mac's `/mcp/workspace` binds every call to a
conversation), so a Linux bot has no Mac-only tools. Its notes, calendar,
history, library and timers come from this host's library copy, and its
session tools run on this server. A Mac accepts `/mcp/workspace` only as a
signed request from a Linux member; no Mac issues a library MCP or publisher
grant. Without a running library host nothing is published and Mac-only tools
are unavailable. Session history is published to the local publisher routes,
and bot conversation batches go to `/v1/bots/{botID}/entries`, waiting in the
outbox while the host is down.

**Timers on a library host.** Timers (`workspace_session_timers`) are not in
the paired sync table set: each lives in the library copy of the machine that
fires it, so a Linux session's or bot's timers keep firing with every Mac off.
The timers group is served by `POST /v1/mcp` like the other library groups.
A bot without `session` (Node catalog) or `sessionID` (an app-wide caller on a
Mac or the library host, `WovenMCPServer.handle(botCaller:)`) sets its own
timers, whose target is its principal `woven:bot:<machine>:<bot>`; no caller
may set another bot's. `woven_timers_list` without a session lists the bot's
own schedule, which its idle check reads. The table has no foreign key to
conversations (migrated in place); timers of a missing conversation are never
listed or fired, and a paused, revoked or disabled bot's are skipped.
- Firing (`remote/src/library-timers.mjs`, started by `server.mjs`): the Node
  server asks `POST /v1/timers/due`, which reserves and claims each due
  occurrence as a `timer` delivery whose ID is stable across retries, and
  returns the occurrences of this machine's sessions and of bots whose
  principal names this host's member device ID. A session occurrence becomes
  a `send` (or `steer` when the harness can, else queued until the turn ends)
  with command IDs derived from the delivery ID; a bot occurrence is the bots
  runtime's `message.send {botId, text, deliveryId}` over the loopback `/ws`
  (`bots-service.mjs` `deliver`), which accepts each delivery ID once. The
  server then settles it: `accepted` advances a repeating timer or ends a
  one-shot one; `retry` (runtime down, library busy) offers it again after 30
  s; `cancelled` (a session this workspace does not run, or a refused
  command) ends that occurrence. It sleeps until `nextFireAt` (at most 60 s,
  30 s after a failure) and is woken by every timer change made through Woven
  MCP and whenever the library host becomes ready. There is no other polling.
- On a Mac the app's agent tool tick fires the Mac's own timers as before and
  now also delivers a bot's own timers to it (`deliverBotNotification` accepts
  `timer` deliveries). Its UI shows a bot's timers in that bot's conversation
  header, by the bot's name (`WorkspaceAgentToolsModel.timers(forBot:on:)`);
  session views never list them.

Tool execution is `WorkspaceToolExecutor` in `WovenMatterDashboardStore`, the
same code the Mac app's `WorkspaceAgentToolsModel` now delegates to. Note edits
go to `WorkspaceDatabase.readNoteForEditing` / `applyNoteEdits`, so a Linux
edit stores the same `NoteDocument` bytes a Mac stores for the same edit.

**Linux build.** `scripts/build-linux-library.sh` builds
`remote/host/library/linux-{x86_64,aarch64}/wovenmatter-library` (static musl,
any distribution) in the pinned Swift image with the pinned Static Linux SDK
and SQLite amalgamation (`remote/library/build-version.json`) and packs it as
`wovenmatter-library.gz` (`gzip -9 -n`) beside `wovenmatter-library.sha256`, the
uncompressed binary's SHA-256 (`--uncompressed` also keeps the binary for local
runs). Anything under `remote/host/` is a host bundle input, so a Mac app built
with those files present ships them to every host install and update; the bundle
manifest verifies the `.gz`, and `remote-host.sh` unpacks it to
`<release>/host/library/linux-<arch>/wovenmatter-library` (0700) and checks the
recorded SHA-256 before the migration runs (`library_verification_failed`
otherwise; a release with a plain binary is used as is). Every host holds a
library copy, so the binary is required: `remote-host.sh install|update` fails
with `library_missing` before changing anything when the release has none for
the machine's architecture, and a Mac refuses to send a host bundle without one
(`RemoteHostLibrary`: the host's architecture from `inspect`, or any while it is
unknown). Development builds get theirs from `scripts/build_and_run.sh`, which
builds missing architectures with Docker (see docs/DEVELOPMENT_BUILDS.md). Starting and
supervising it is the Node server's job. `scripts/test-linux-library.sh` builds
and tests the portable targets on Linux; the manual validation workflow
(`linux` scope) runs both and keeps the binaries as an artifact. The release
workflow's `linux-library` job (ubuntu, Docker) builds both architectures and
hands them to the macOS job, which checks them with
`scripts/verify-linux-library.sh` before `xcodebuild`.

## Sessions across devices

- Every Mac's and every Linux host's agents can create sessions on every Mac
  and Linux workspace through Woven MCP. The iPhone is never a target: it
  runs only its own Quick Chats.
- Workspaces are named explicitly by ID (or an unambiguous name) from the
  synced execution workspace registry. `local` (and, on Linux, `current`)
  is no longer accepted as a destination; the error lists the valid IDs.
  Omitting `workspace` means the caller's own workspace.
- `woven_sessions_harnesses` lists this workspace's harnesses with its real
  ID and name first, then every other Mac and Linux workspace's (`harness`,
  `workspace`, `workspaceName`, `workspaceKind`, `ready`, `online`); a
  workspace that does not answer is one row with `online: false`.
- A session on another workspace is created directly on that workspace's
  execution API with signed requests, so it works with every other Mac
  offline: `GET <endpoint>/v1/execution/providers`, then `POST
  <endpoint>/v1/execution/commands` with `createSession` (the destination's
  saved defaults apply; its `title`, trimmed to 256 characters, names the
  session as it is created and is kept by the first message), a `workspace`
  rename to the same title (for destinations older than `title`), and
  `send`. A session created on its own Mac (Woven MCP or the backend RPC
  `createSession`) takes its `title` the same way; without one it is
  "New <harness> chat" until its first message. `deviceID` is the caller's member device ID,
  and `libraryID`/`workspaceID` are the destination's. Command IDs derive
  from the caller, request ID and destination, so a retry replays receipts.
  The reply is `{session: {id, title, harness, workspace, workspaceName,
  workspaceKind}, independent: true, receipt}`: the caller does not
  coordinate it. Linux: `remote/src/member-sessions.mjs`; Mac:
  `ApplicationModel+MemberSessions.swift`. A copied owner (`retainedHistory`)
  is never a destination or listed by `woven_sessions_harnesses`, as on the
  iPhone; the Mac never signs, grants or enrolls for one.
- **Managing them (Linux and Mac).** The Linux server remembers each session a caller
  created on another workspace (`member_sessions` in its execution database;
  on a Mac, the local, unsynced `member_tool_sessions` table of its library),
  so these tools name it by `id` alone, or by `id` plus `workspace` for one it
  did not create. The Mac's catalog (`WovenMCPCatalog`) is the source of
  `remote/src/woven-mcp-tools.json` (regenerate it with `WovenMCPCatalogExport`;
  `WovenMCPTests` checks that they agree). On a Mac,
  `WorkspaceToolHandlers.memberSession` sends a call for a remembered or named
  member session to `ApplicationModel+MemberSessions.swift`, which signs it
  through `CentralExecutionClient` (`SignedExecutionWorkspaceTransport`); a
  session on that Mac stays local; a Linux host's sessions, the adding Mac's
  included, are reached with signed calls to that host. Each is one or more signed calls to the destination's
  execution API (`GET v1/execution/conversations`, `…/conversations/<id>/transcript`,
  `…/capabilities`, `GET v1/execution/interactions`, `POST v1/execution/commands`):
  - `woven_sessions_status {id, workspace?, before?}` → `{session: {id, title,
    harness, workspace, workspaceName, workspaceKind, state:
    running|idle|needsInput, runID?}, pending: [{id, kind, title, detail?,
    runID, options, questions}], transcript: {messages (latest 20, 4000
    characters each), before?}}`; `before` pages older messages.
  - `woven_sessions_send {id, text, workspace?}`: `send` when idle; `steer`
    when running and the harness can, otherwise 409 (send when idle).
  - `woven_sessions_stop {id, workspace?}` (new): `stop` of the current run.
  - `woven_sessions_respond {id, interaction, optionID?, answers?, cancelled?,
    workspace?}` (new): `respond` to one pending question or approval.
  - `woven_sessions_list {workspace}`: that workspace's sessions; without
    `workspace`, a bot gets every session it created, each with its live state.
  Command IDs derive from the caller, request ID, workspace and session, so a
  retry replays the receipt. Reading a session the caller did not create needs
  Conversation history. `stop` and `respond` on this workspace apply only to
  sessions the caller created or coordinates. The caller does not poll: it
  waits with `woven_sessions_wait`, and it is woken when a session it created
  finishes or needs input (see "Streaming", agent to agent).
- **Bots** get `woven_sessions_create`, `_send`, `_status`, `_list`, `_stop`,
  `_respond` and `_harnesses` from the Node server itself (no Mac): a bot's
  sessions on its own machine's workspace go through that workspace's own
  execution commands, as another member's would; coordination tools
  (`manage`, `release`, `notifications`, `receipts`) bind a conversation and
  stay unavailable to bots. On a host with no workspace enrolled the same
  tools reach only other workspaces: `_harnesses` lists theirs, and a
  session without `workspace` is refused, saying either that the machine
  runs only bots or, when it has the workspace role, that its workspace is
  not enrolled yet (its Mac enrolls it on reaching the host). A Mac's bots, which are app-wide callers there,
  get the same tools from the Mac; `woven_sessions_list` without `workspace`
  lists a bot's sessions on other workspaces.
- The iPhone connects directly to every Mac and Linux workspace with its own
  member key. It has no home Mac.
- **Folder owners.** A folder's `execution.workspaceID` names the workspace
  whose files it is bound to: `device:<id>` (an iPhone, or a library client's
  secondary Mac, whose registry id is that `<id>`), `remote:<id>` (a Linux
  workspace, registry id `<id>`), or, for the central Mac,
  `device:<dashboard device id>`, which is neither its registry id (a random
  per-library value) nor its `hostDeviceID`. The central Mac's registry row
  therefore names that value as `folderOwnerID` (optional, `device:<UUID>`,
  `.mac` rows only; the library rejects anything else). Devices group a
  folder under the registry row whose own id matches, else under the live row
  that names it as `folderOwnerID`
  (`ExecutionWorkspace.displayOwner(of:in:)`). This is display and
  routing-choice grouping only; stored folder bindings are never rewritten, so
  existing folders appear under their Mac once it republishes its row (each
  registry refresh). A row without the field (an older Mac) leaves its
  folders out of that Mac's section on the iPhone; they stay in All
  Workspaces and Recents.
- **Listed workspaces.** The iPhone's Home, Folders, New Chat and Calendar
  list Quick Chat plus only the Mac and Linux workspaces that are paired and
  reachable now (`MobileModel.workspaceIsActive`, `agentGroupIsActive`):
  the workspace's own connection answered its last refresh, it is the library
  host the phone is synced with, or one of its agents can start now through
  that host. A registry row or saved agent catalog alone never lists a
  workspace, and nothing stored is removed; the next refresh that reaches it
  lists it again. A copied snapshot owner (`retainedHistory`) is never
  listed or used as an agent source, even when its copied endpoint answers;
  its chats stay readable in All Workspaces and Recents. Within a listed workspace, an agent the workspace reports as
  not ready stays listed, dimmed. Settings → Workspaces keeps every saved
  workspace with its connection state. Other Apple devices are never
  connections; their synced Quick Chat history and folders stay listed.
- **Order and names.** Quick Chat comes first, then the library host, the
  other Macs and the Linux workspaces, each listed once under its registry
  name with its own agents (`AgentGroup.list`). Every Mac that hosts
  a library advertises `history.central.v1`, so the central agent list
  ("This Mac", from `GET /v1/providers`) belongs only to the registry row of the
  library host the phone syncs with, matched by its device ID
  (`MobileModel.centralExecutionWorkspace`); any other Mac lists its own
  agents from its own endpoint. A library host's agent that its central list
  reports as not ready is offered through its own endpoint when that reports
  it ready.
- **Agent freshness.** The phone asks the library host for its agent list on
  the first refresh after launch, after a failed refresh (reconnect), when it
  becomes active or the network returns, when the library host changes, when
  the New Chat menu opens,. Each reachable
  workspace's own list is fetched on each of its refreshes, and opening New
  Chat refreshes every workspace at once. The saved agent catalog only fills
  the lists until those answers arrive; a deleted workspace's saved list is
  dropped.
- **Sending.** A message to a Mac or Linux session (direct or central) shows in
  the chat immediately (`PendingSend`), the composer clears, and a
  quiet caption says "Sending to <workspace>…" until the workspace accepts it,
  then "Starting on <workspace>…" until its transcript shows the message and
  its turn. The phone then refreshes that workspace at once and every two
  seconds while the turn starts. A failed send removes the message and puts
  the text back in the composer; the saved draft is cleared only once the
  workspace accepts the message.

### iPhone reach

- **Identity.** On first pairing the phone creates a Curve25519 signing key
  in its Keychain (`MobileMemberKeyVault`, service
  `com.wovenmatter.wovenmatter.member`, this device only), bound to its library
  device ID, and sends it as `PairRequest.memberPublicKey`. A re-pair
  presents the same key. The Mac adds the phone when the pairing is
  confirmed, so the phone probes it (a signed `GET /v1/hello`) only after
  confirming: a signed 401 then means the Mac did not add it (`rejected`,
  never taken as acceptance), and the phone keeps its grant and shows "Pair
  again" (`MobileMembershipState.memberRejected`). A backup restored onto
  another device brings `membership.json` but not the this-device-only key;
  finding the key missing, the phone marks that membership refused instead of
  signing with a key no Mac knows, and pairing again replaces the key on the
  Mac. Whether to keep the replica (same library set) comes from
  `PairResponse.libraryIDs`, before any signed request works.
- **Signed requests.** `HTTPSLibraryTransport(host:identity:)` and
  `HTTPSExecutionWorkspaceTransport(workspace:identity:)` sign every request
  (`MobileRequestSigning`: the target is the percent-encoded path and query as
  sent, `/wovenmatter` included) and send no bearer. A signed 401 means "this
  host does not know this phone yet" (`memberUnknown`, skipped like an offline
  host); a host that has not loaded its member list yet answers that it does
  not accept member requests, which is retried like any other failure; 409
  `update_required` becomes `updateRequired`. A phone that is not a member
  (the Mac refused its key) syncs nothing and asks to pair again.
- **Members.** The mobile API serves `GET /v1/members` (the resolved member
  list, as on the library socket) on every Mac and Linux host. The phone
  learns it from whichever host it syncs with, when the host changes and at
  most every five minutes, with `GET /v1/sync/status` alongside. It is kept in
  `membership.json` beside the phone's library (`MobileMembershipState`).
  Endpoints are used only when they are HTTPS on the paired endpoint's
  tailnet (`<tailnet>.ts.net`), normalized to `/wovenmatter`; a Mac without a
  member endpoint is reached at its registered `.mac` execution workspace
  address (the same server).
- **Host choice and failover.** Each synchronization tries hosts in order (the
  last one that worked, the paired Mac, other Macs, then Linux hosts) with one
  short signed `GET /v1/hello` each, and syncs every lane with the first that
  answers. There is no extra timer: the existing foreground, change-driven
  cadence is unchanged.
- **Moving to another host.** Each host has its own library ID, revisions and
  change cursors, but the same records under the same IDs. When the chosen
  host's library ID differs from the replica's, the phone rebinds without
  re-uploading: the host's snapshot replaces revision baselines; a pending note
  edit is acknowledged (already there), resent (the host has its base), kept
  as a conflict with both versions (the host has another version) or created
  there (the host never got it). A note the host has only as a deletion
  answers that create with `notFound` and `LibraryMutationResult.deleted`,
  and an unchanged phone copy is then deleted instead of becoming a conflict;
  calendar edits are rebased on the next
  snapshot the same way; the journal keeps all history, resets its cursor and
  offers this phone's own records again (the host keeps those it has);
  dictation and artifact cursors restart. The phone's device workspace is
  re-registered in the new host's library at that host's revision.
- **Sessions.** "Central" means the library host the phone is syncing with;
  its own sessions use the mobile API, and every other workspace with an
  endpoint (each Mac's own and each Linux workspace) gets a signed direct
  client. No execution grant is issued, stored or presented.
- **Inference.** A Mac's inference host (`/v1/inference/catalog`,
  `/v1/inference/stream`, `InferenceHost`) accepts signed `ios` and
  `mac` members: the principal is the member's device ID, a named
  `X-Woven-Workspace` / `X-Woven-Library` / `X-Woven-Device` must match it and
  this Mac, and removal is checked before credentials are prepared and again
  before a stream starts. The phone saves hosted connections
  with `InferenceHostScope.hostDeviceID` (the workspace's `executionDeviceID`)
  and no credential, and `MobileInferenceService` signs them through
  `InferenceMemberSigning` (installed with the phone's member key); a
  connection saved without `hostDeviceID` signs for its workspace's serving
  member. No inference grant is presented, and the Mac accepts none.
- **Analytics.** Only Macs record product analytics (a Linux host answers
  `unsupported`). Each synchronization picks the analytics connection again
  (`MobileLibraryHosts.analyticsTransport`): the current host when it is a
  Mac, otherwise the preferred Mac from `candidates` (the paired Mac, then
  other Macs). Pairing and host changes therefore re-bind it without a
  relaunch, and an unpaired phone has no analytics connection at all.
- **Migration.** Existing phone data stays. A phone that is not a member
  shows "Pair again with any Mac"; pairing with a Mac of the same
  library set (its registry holds the phone's previous library) keeps the
  replica and rebinds on the next sync instead of the destructive library
  change.

## iPhone Quick Chat

- Pi Durable runs on the phone in full access.
- Its tools: notes, web search and read (with the provider connected in
  Connections: Exa, Brave or Firecrawl), asking the user a question, timers
  and reminders, and calendar.
- There is no shell, no file tools, no embedded Python and no background
  execution. A timer fires as a local notification, and any agent work it
  needs runs when the user opens it. Recurring agent work becomes a scheduled
  task on a Mac or Linux workspace.
- Other devices see Quick Chats as read-only synced history.

### iPhone without a Mac

- The iPhone and iPad app is complete with no Mac or Linux device paired
  (`MobileModel.isStandalone`: no pairing credential and no bound library).
  Provider sign-in and web search keys live in Settings → iPhone Connections;
  Quick Chat, notes and folders, calendar, timers and reminders, and dictation
  all run on the device. Nothing waits on a host: with no credential there is
  no sync engine, so there is no connection banner, no network retry and no
  analytics send (the 15-second lifecycle tick only reads local state).
- Home offers "Connect your Mac" with one caption saying what pairing adds
  (workspaces, agents on your computers, sync) and that local data is kept.
  Pages that only a Mac or Linux workspace serves (Scheduled tasks, Databases)
  are left out until paired; Library and Folders explain pairing instead of
  showing an outage. On a phone that has never been paired, a note is
  deleted on the phone itself (`MobileModel.canDeleteNoteLocally`). Once a
  phone has been paired, notes go to the library's Trash; after an unpair,
  deleting waits until it pairs again, because a note may already be in the
  library even before its create was answered.
- **Pairing later** keeps everything. A first pairing binds the empty replica
  to the Mac's library (`MobileStore.prepareForPairing` with no previous
  library moves nothing) and registers the phone's device workspace; the next
  synchronization then sends each local item once: one `createFolder` and one
  `createNote` per item with its latest writing (edits made before pairing
  collapse into the create, and a note deleted before pairing is never sent),
  the Quick Chat journal (its entries were written for the device workspace
  before it was registered and publish once it is), calendar events and timer
  reminders, and dictations. Local notes the Mac does not have are kept, and
  Quick Chats stay owned by the phone. Pairing with a Mac of another library
  later still takes the explicit library-change path above.

## Streaming

Every live view of a session streams. Nothing polls an execution workspace
whose stream is connected; the iPhone's no-stream fallback is under "Clients".

- **Who is the server.** Each machine's one Woven server (the Mac background
  server, the Linux Node server) owns its sessions and serves the stream. Every
  user interface, on any device, is a client of every server it uses. On a
  Mac the member key and command journal live in its
  background server, so that server holds the one WebSocket to each other Mac
  and Linux machine on behalf of its windows, and a window holds one
  connection to its own server, which carries the live items of local and
  remote sessions alike. The iPhone holds one WebSocket to each server.
  Servers also connect to each other, only for agent-to-agent waiting. Harness
  processes stay ACP children of their own machine's server.
- **What moves where.** History moves only by library sync. The live view of a
  session (its transcript as it is written, run state, questions and
  approvals, capabilities) and commands move on the stream. Older history
  pages, attachments (`GET v1/execution/attachments/<sha256>`), the browser screencast, inference, bots and library sync
  stay on their signed HTTP routes.

### Endpoint and authentication

- `GET /v1/stream?protocol=1`, upgraded to a WebSocket. A Mac serves it under
  its `/wovenmatter` mount; a Linux host under its execution endpoint
  (`…/wovenmatter-execution/<id>/v1/stream`). The workspace descriptor's
  `capabilities` includes `stream.v1`.
- The upgrade `GET` is member-signed exactly like any other member request
  (`woven-member-v2`, headers only, empty body, the target including
  `?protocol=1`). It is the whole credential: no ticket, bearer or grant.
  Allowed member kinds are those of `/v1/execution/*`: `mac`, `ios`, `linux`.
  A live host's loopback development listener accepts the same upgrade signed
  by a Dev stream key instead (see "Client-mode Dev builds").
  A Mac window has no key; it asks its own server to sign each attempt
  (`BotsCommand.signSocket`, widened to `/v1/stream`). Every reconnect signs
  afresh.
- Refusals happen before the upgrade, as JSON HTTP errors: `426`
  `{code:"protocol_unsupported", supported:[1]}`; `401`
  `{code:"member_time_stale", serverTime}` when the signature time is outside
  the window, so the UI says the device clock is wrong; `401` `unauthorized`;
  `403` `browser_request` when the request carries `Origin` or `Cookie`;
  `503` `unavailable` while the workspace is not enrolled yet, the server is
  stopping, or a Linux host has no member registry yet. Every refusal also carries a `message`, an `X-Woven-Error` header
  with its code (`URLSessionWebSocketTask` cannot read a refused upgrade's
  body), and a `Date` header. A client reads `X-Woven-Error` first; without
  it, a `401` whose `Date` is outside the signature window is reported as a
  stale clock.
- Each server keeps a registry of open sockets by member device ID. When its
  member list changes it closes every socket whose member was removed, or is no
  longer an allowed kind, with close code `4401`. A socket registered after such
  a change (its member was authenticated before it) is checked against the list
  once more and closed the same way. A close the server starts is a closing
  handshake: it ends the connection once the client answers with its own close
  frame (or after 2 s on a Mac, 5 s on Linux), so nothing the client wrote meanwhile meets a closed
  socket whose reset could cost it the code. A client does not retry after
  `4401` until its own member list changes. The same registry closes the
  `/v1/bots/ws` relays on both Mac and Linux. The Linux bots upgrade accepts
  signed members, and the installer bearer only on the installing Mac's SSH
  tunnel (how it reaches a bots-only host that is not in the registry); device
  grants no longer open it, and the bearer never works through Tailscale Serve.
  The Linux relay sends `4401` to a removed member's bots socket; the Mac relay
  carries raw bytes, so it closes the connection and that client sees an
  abnormal close (`1006`), after which its signed upgrade is refused. A Mac's
  library server answers `403` to any request carrying `Origin` or `Cookie`,
  not only upgrades.

### Frames

JSON text frames, one message per frame, at most 8 MiB (normal frames are far
smaller); a server refuses client frames over 1 MiB (close `1009`). Liveness
uses WebSocket ping and pong control frames: both sides ping every 25 s and
answer the other's pings, and the server closes a socket (`1001`) after 60 s
in which it heard nothing from it, neither a pong nor any frame. Binary frames and invalid JSON close the socket with `4400`. The Swift types live in `shared/Sources/WovenMatterShared/StreamProtocol.swift`;
`shared/Tests/WovenMatterSharedTests/StreamProtocolFixtures.json` holds one
example of every frame and item, and the Swift and Node test suites both
decode and re-encode every fixture.

| Direction | Frame | Meaning |
|---|---|---|
| server | `{t:"hello", protocol:1, deviceID, libraryID, workspaceID, serverTime, capabilities:[…], maxFrameBytes}` | First frame after the upgrade. `deviceID` is the server's member ID; `libraryID` and `workspaceID` are its registered execution workspace's, and a client closes a stream whose `hello` names another. |
| client | `{t:"req", id, method, params}` | A call. `id` is unique per socket. |
| server | `{t:"res", id, result}` or `{t:"res", id, error:{code, message, retryable}}` | Exactly one per `req`. |
| client | `{t:"sub", id, stream, params}` | Open a subscription. |
| server | `{t:"item", id, kind, seq?, data}` | One subscription item. |
| server | `{t:"end", id, error?}` | The server closed a subscription. |
| client | `{t:"cancel", id}` | Close a subscription or abandon a call. |

Unknown frame types and unknown item kinds are ignored. A subscription the
client cancels gets no `end`. A socket holds at most 64 subscriptions and 64
calls in progress (a cancelled call no longer counts); another is refused with
a retryable `unavailable` `end` or `res`. Error codes:
`unauthorized`, `not_found`, `invalid`, `unavailable`, `conflict`, and
`resync` (the subscription fell behind: subscribe again). A subscription
ended by a store or server error, not a refusal, ends with a retryable
`unavailable` on both servers, so its client subscribes again after the
backoff. Close codes: `1000`
normal, `1001` server stopping or sleeping, `1009` client frame over 1 MiB,
`4400` protocol violation, `4401` member removed.

### Streams

- **`workspace`** `{after?}`, one per server per client:
  - `conversations` `{conversations:[LibraryConversation], snapshot}`: the
    full list on subscribe (`snapshot: true`), then changed summaries.
    `deletedConversationIDs` lists removals.
  - `pending` `{interactions:[PendingInteraction]}`: the whole list for the
    workspace whenever it changes, and on subscribe.
  - `journal` `{entry: ExecutionJournalEntry}`, `seq` = its `originSequence`:
    only from a server with an execution journal (a Linux host, a secondary
    Mac), only when the client passed `after`. The server replays every entry
    after `after`, then sends new entries as they are written; a sequence jump
    means a gap and the client subscribes again with its last cursor. A Mac
    never asks for it: history reaches a Mac only by library sync (a Linux host
    writes its sessions into its own library copy through `/v1/publisher/*`).
    The iPhone feeds it to its `WorkspaceJournal`, a run of consecutive
    entries as one write and one projection restore (up to 256 entries, at
    most 50 ms after the first, or when any other item arrives). A write that
    fails subscribes again from the cursor it holds.
  - `library` `{cursor}`: the server's mobile library change cursor
    (`device_sync_changes`, what `GET v1/changes` pages), on subscribe and then
    whenever a change a phone syncs commits, at most every 300 ms
    (`LibraryChangeAnnouncer`). Calendar, dictation, registry
    (`execution_workspaces`) and saved-artifact rows add wake-only entries,
    which change pages skip. Transcript and agent-list entries do not move the
    cursor, so it may trail the feed's newest entry. A phone compares it only
    with the cursor it holds for that same server, matched by `hello.deviceID`.
    On a Linux host the library host prints `{"event":"library","cursor":N}`
    on stdout after its ready line, and the Node server streams the latest
    value.
  - `synchronized` `{}` after the initial snapshot and replay.
- **`conversation`** `{conversationID}`, one per open chat:
  - `transcript` `{transcript: LibraryTranscript, snapshot}`: first the latest
    window (what `GET …/transcript` returns) with `snapshot: true`; then
    upserts of the messages and activities that changed, each whole, with the
    transcript's `activeRunID`, `runs` and `removedMessageIDs`. The client
    replaces entities by ID. Live text is the whole message so far, never an
    appended piece. Changes are found within the latest window (80 messages on
    a Mac); an edit to an older message reaches the client through history,
    not live. A snapshot or single entity too large for one frame ends the
    subscription with a non-retryable `unavailable`, so the client does not
    loop.
    Each activity carries its compact `AgentRunActivity` projection in
    `projectionJSON` (title, detail and content to 280 characters, file
    changes as line counts, no raw data, plus `detailsAvailable` and
    `detailVersion`), its `sequence` (its position in the conversation) and
    `createdAt`. Assistant text written before a new piece of work becomes an
    `assistant` activity at its position. Runs carry `startedAt`,
    `completedAt`, `userMessageID` and `assistantMessageID`; a Linux host keeps
    its latest 32. The full projection is read when its disclosure opens:
    `GET v1/execution/conversations/<id>/activity?id=<activity>&run=<run>`
    (Mac and Linux; a library host also answers `GET v1/sessions/<id>/activity`)
    returns a `LibraryActivity` with the complete projection. A Linux host
    journals a settled activity's full projection as a
    `wovenmatter.activity.v2` native record named in `detailsRecordID`, so
    history discloses it too.
  - `capabilities` `{capabilities: HarnessCapabilities}` on subscribe and when
    they change.
  - `session` `{settings: SessionSettings}`: exactly what the `session`
    workspace read (`POST v1/execution/workspace-read` `.session`) returns:
    model, thinking, permission, enabled tools, goal and `canConfigure`. Sent
    on subscribe, before `synchronized`, and whenever it changes; an unchanged
    value is not sent again. A client of a `stream.v1` workspace does not read
    session settings. On Linux the stream reads them again when the record's
    runtime configuration, run, goal or tools change and after every settings
    action, because a runtime may keep its settings outside the record.
    `commands` lists the harness's slash commands (`{name, detail?,
    argumentHint?}`) from ACP `available_commands_update`.
  - `synchronized` `{}` after the first snapshot.
- **Coalescing.** A server sends a conversation's changes at most every 50 ms
  while every changed message is 8 KB or smaller (measured on the message's
  encoded JSON), and at most every 200 ms once one is larger. Durable state is never coalesced away: the last update
  always reflects the stored state.
- **Backpressure.** Each socket has a bounded outbound queue (512 items or
  8 MiB). Updates to the same entity supersede queued ones. A subscription that
  still overflows ends with `resync`; nothing is lost, because a new
  subscription starts from a snapshot or a journal cursor.
- **Mac change source.** A Mac has no execution journal. Triggers on its
  conversation, local session, message, run, activity, session goal and
  session tool tables append to
  `execution_stream_changes(sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id, entity_kind, entity_id)` (`entity_kind` is `conversation`,
  `message`, `run`, `run_event`, `activity` or `session`) in the same
  transaction, only for
  conversations this Mac runs (not history synchronized from other machines).
  Entries are pointers; the server reads the current rows when it sends. The
  sequence is gap-free, so the stream tail never misses a change. Entries
  older than the newest 10,000 are deleted. Opening the database rewrites a
  trigger only when its stored definition differs. A read that fails without
  ending a subscription (its session settings, or a read the source cancelled)
  is tried again after 1 s, doubling to 30 s, so the subscription never stalls.

### Methods

- `execution.command` `{command: LibraryCommand}` → `LibraryCommandReceipt`.
  The same handler as `POST v1/execution/commands`, with the same idempotent
  command IDs. Commands are never replayed automatically: a command whose
  `res` was lost becomes `outcomeUnknown` in the client's command journal and
  is resolved with `execution.receipt` after reconnecting.
- `execution.receipt` `{commandID}` → `LibraryCommandReceipt` or `null`.
- `POST v1/execution/commands` and the read routes stay for server-to-server
  calls and Woven MCP. `POST v1/execution/commands` also serves a workspace
  without `stream.v1`, one request per command.

### Clients

- One `StreamConnection` per (client, server) owns reconnection: backoff from
  1 s to 30 s with jitter, starting again from 1 s only once a connection has
  stayed open 30 s (a server that greets and closes keeps backing off), an
  immediate attempt on wake, network path change and app foreground, and no
  attempts while Tailscale is down. An attempt whose `hello` has not arrived
  30 s after it started fails; a ping whose pong has not arrived in 20 s
  drops the socket, even when the transport never reports the ping, and one
  probe runs per socket at a time. Subscriptions resume after a reconnect;
  commands do not. A `resync` end subscribes again at once, a repeated one
  (within 30 s of the last) after the backoff; an end whose error is
  `retryable` subscribes again after the backoff and is not reported. Only an
  end without an error or with a non-retryable one reaches the subscriber,
  and that subscription is gone.
- A Mac's background server opens a stream to every registered workspace that
  serves one when it starts, and opens or closes streams when the registry or
  member list changes (a registry refresh, a peer sync that applied rows).
  Nothing reads a workspace on a timer. A machine the Mac holds no stream to,
  or one not connected, shows the history library sync brought, with an
  offline notice. Its live state, questions, approvals and settings come only
  from its stream; no device keeps a per-machine cache of another machine's
  history.
- **Client-mode Dev builds** stream from their live library host with a Dev
  stream key, never a member key. Each client instance keeps an Ed25519 key in
  its own Keychain namespace and sends only the public half on the host's
  same-user Unix socket, with `development.connect` and again with
  `development.stream` before every attempt, both authenticated by its current
  Dev device credential. The host keeps the key in an in-memory roster (never
  SQLite, the signed member list or anything synchronized) and refuses a device
  ID that is a library member. The key opens only the host's loopback
  development listener (`ws://127.0.0.1:<port>/v1/stream?protocol=1`), a
  separate port Tailscale Serve never exposes that serves `GET /v1/stream`
  only and accepts only roster keys signed for the host's member ID; the
  library's own listener refuses it. Its sockets are outside the member socket
  registry and answer no call; commands go through the library API with the
  Dev credential. Disconnecting (as quitting does), unpairing the Dev identity,
  or that credential no longer being current revokes the key and closes its
  sockets with `4401`; a host restart forgets the roster and the client admits
  its key again. The client's background server subscribes to `workspace` and
  to a `conversation` stream for each host chat its windows hold open and
  relays them to the window; a `library` item ahead of its cursor starts one
  library sync. Without a stream (an older host) library sync falls back to
  15 s, 2 s during a run. Other machines' sessions show library history, read
  on open, after an action and after each library sync.
- **Mac window to its own server.** The window opens an ordinary RPC
  connection on its server's socket and sends `backend.stream` as its first
  request (readiness advertises `window.stream`). After the reply both ends
  exchange the stream's frames on that connection, each a 4-byte big-endian
  length and its JSON. Unix socket permissions and peer credentials
  authenticate it, as for every call there; there is no upgrade, signature or
  ping (a closed socket ends the read). Commands stay on the server's own
  command call.
  - `server.state`: on subscribe, `synchronized`, meaning "read everything
    again from the projection"; then `{scopes, conversationIDs?}` for each
    invalidation. The window reads named conversations again unless it follows
    them on a `conversation` subscription.
  - `conversation` serves sessions this Mac runs from its own tables, as for
    members. For a session another machine runs, it relays what this server
    holds for it from its stream to that machine. A relayed session's stream
    also carries `pending` (that session's questions and approvals) and
    `owner` `{online, error?}` (whether this server reaches that machine), on
    subscribe and when they change.
  - Live text of a message the window already shows is applied from the
    items; anything else is read from the projection. The window keeps reading
    bulk history and lists from its read-only SQLite projection. After a
    reconnect it resubscribes and starts again from snapshots.
  - A session another machine runs renders in the same conversation view as
    this Mac's own sessions, from its relayed transcript
    (`RemoteConversationRecords`). Older pages come from `earlier`, and an
    activity's details from the background command `federatedActivityDetails`
    (once per `detailVersion`). The background server keeps every chat a window
    holds subscribed, and at most 8 chats read for other reasons, closing the
    least recently viewed first; viewing one subscribes it again. A chat that
    ran over SSH and could not move is read-only history: the window learns
    why with its session metadata (`readOnlyReason`) and shows no composer.
- **iPhone.** Connects to every listed server while the app is in the
  foreground: `workspace` on each, `conversation` only for the open chat. It
  closes cleanly when the app goes to the background and resumes on return.
  Nothing is live while the app is in the background. The library host's
  stream also carries the central route (its own sessions, unassigned in its
  library): its `conversations` summaries keep the library's identity,
  `pending` is the central questions and approvals, and `conversation` follows
  an open central chat. The phone reads no central transcript, questions,
  capabilities or session settings over HTTP; central commands stay on the
  mobile API's `POST v1/commands`. A chat whose subscription the server ends
  is read once and not resubscribed on that connection. A `workspace`
  subscription the server ends for good is not asked for again on that
  connection either; the next connection subscribes again, and meanwhile the
  workspace counts as not streamed. Lost central replies
  are resolved by receipt once per connection to the host. An expanded
  activity is read once from its owner's details route; a journaled summary
  is used only when it is complete. While the stream of the library host it
  syncs with carries `library` items, the phone has no library timer: an item
  whose cursor differs from the one it holds synchronizes at once (ahead: a
  change; behind: the host's library was restored or reset), and a refresh asked for during one
  runs once more afterwards. Without that stream (an older host, the stream
  down, another host) the 15 s foreground timer runs. It also syncs once on
  foreground, network return and connection.
  A route counts as streamed only while its stream is connected and serves
  `workspace`, not because the workspace advertises `stream.v1`. For a route
  without one (no `stream.v1`, the stream down or ended), the same 15 s
  foreground tick reads the live view the phone shows: the central questions
  and the open central chat over the mobile API while the library host's
  stream is not connected, and the open chat of another workspace with its
  questions over that workspace's signed HTTP routes. It reads nothing for a
  route whose stream is connected, and runs no timer when every shown view
  streams. When the host's stream stops, its copy of the central questions
  is dropped for the one read.

### Agent to agent

- `woven_sessions_wait {id, workspace?, until: "idle"|"needsInput"|"either",
  timeoutSeconds}` (1 to 50, below harness tool-call limits). States are
  `woven_sessions_status`'s: `needsInput` while any question or approval is
  pending, else `running` during a run, else `idle`. It reads the status,
  returns at once if the state is there, otherwise waits for a change of that
  session on the stream and reads again to confirm, and reads once more at the
  timeout. The reply is the status body plus `state` and `timedOut` (true
  exactly when `state` does not reach `until`). Nothing polls.
- **Wake-ups.** A session the caller created (a `member_sessions` /
  `member_tool_sessions` row) is watched once the caller makes it run or reads
  it running or needing input. Becoming idle (finished) or needing input with
  new pending interactions queues one wake-up per session. A newer state
  replaces it; running again, or any status, wait, send or respond by the
  caller on that session, drops it; a stop by the caller ends the watch. On a
  Mac, a watch made after its session's stream already showed the run the
  caller saw end, or a question in the run the caller started, still queues
  that wake-up. The caller's server delivers it only while the calling
  conversation is idle, as a send (never a steer) whose source is that session (`senderKind:
  notification`, a coordination notification), with the text of
  `SessionWakeUp.text` (`shared/Sources/WovenMatterShared/SessionWakeUp.swift`,
  fixtures shared with Node). At most 10 per calling run: the count belongs to
  the caller's latest run a wake-up did not start, and the tenth says it is the
  last. A refused delivery is tried again as a new attempt at the caller's next
  idle moment or after 30 s; on a Mac that wait doubles with each refusal in a
  row, to 4 minutes, a wake-up refused 20 times in a row is dropped, and a
  delivery cancelled because the caller may no longer receive it (it lost the
  Sessions tool) is recorded once and not tried again.
  Bots get theirs through the bots runtime, and a bot's count restarts
  when it creates a session. IDs derive from caller, session and state, so each
  is delivered once; watched sessions and pending wake-ups survive a restart
  (Linux: `remote/src/session-watch.mjs`). On Linux a wake-up refused every
  time backs off and is dropped after 20 attempts (one refused as invalid or
  not found at once), and sessions on a workspace gone from the registry stop
  being watched; one not reachable yet, or listed without an endpoint, is
  retried with a backoff.
- Behind both, the caller's server holds one stream to each destination server
  while it watches or waits on a session there, subscribed to its `workspace`
  stream and filtered on the caller's side to those sessions; its own
  workspace's sessions come from in-process changes. A Linux host answers its
  scheduled tasks' waits itself; a Mac watches through its
  `CentralExecutionClient` streams and stores watches and pending wake-ups
  unsynchronized in its library (`member_session_watch`,
  `member_session_wakeups`, `member_session_wakeup_counts`).

### Linux sessions

Every device, the Mac that added the host included, reaches a Linux host's
sessions through that host's server and its stream. The Linux server owns
them; its durable channels (`remote/src/durable-acp.mjs`) keep runs alive.
SSH is for install, update and repair only: there is no SSH agent launch and
no stdio relay.

- **Creating.** `createSession` takes `sessionOptions {workingDirectory,
  model, thinking, permission, enabledTools}`; unset values use the
  destination's saved defaults, and a model or thinking level the harness does
  not offer keeps its native value. A `folderID` bound to this workspace
  (`remote:<workspace id>`, from the host's library copy) runs in its root and
  `workingDirectory` must match it; a folder bound elsewhere is refused; an
  unbound or not-yet-synchronized folder only groups. Without a folder the
  session gets its own scratch folder, unless the caller names an existing
  directory: a Mac any directory, other members one inside the workspace.
  `initialConfiguration` stays internal to agent-to-agent creation.
- **Messages.** Files are uploaded first (`PUT
  v1/execution/attachments/<sha256>?name=&mimeType=`, 25 MiB each, stored under
  `.wovenmatter/attachments/<sha256>/<name>`), then named in `send` or `steer`
  `attachments` (8 files, 50 MiB) and checked again before delivery. The
  store has no lifetime cap; an upload that would leave the host with less
  than 2 GiB of free disk space is refused with `507`, and a digest folder that is not
  a real directory inside the store is refused with `403`. Images and
  UTF-8 text are inlined up to 5 MiB per message; other files, and anything
  past that, are linked and listed by path. `promptContext` (visible notes and
  pages, references) follows the message to the harness and is not in the
  transcript; `noteID` is the note shown when sending, which `woven_context`
  returns. `GET v1/execution/attachments/<sha256>?name=` returns the bytes
  with their type, under the execution reads' authorization, up to 25 MiB,
  only for a regular file directly in `.wovenmatter/attachments/<sha256>/`,
  reached without a link and still matching its digest (otherwise 403, 404 or
  409). A Mac serves the same route for files of sessions it runs. A Mac
  window opens a remote session's attachment through its background server,
  which reads it once and keeps it after it matches its digest; the phone
  reads it from the workspace, caches it and previews it with Quick Look.
- **Background execution** governs scheduled tasks only. Sessions, their goals
  and timers run with it off.
- **Pi Durable.** Provider credentials stay in the host's encrypted vault, and
  its key stays on the Mac that set it up. A locked refusal has code
  `default_agent_locked`; a Mac unlocks with `POST v1/default-agent/unlock
  {workspace, unlockKey}` (or `v1/default-agent/configuration`) and retries.
  Settings, sign-in and the model catalog use `POST v1/default-agent/control`
  and `v1/default-agent/control-sessions`, which run the control helper on the
  host.
- **Without a session.** `GET v1/execution/providers/<id>/options` returns
  `SessionSettings` (empty `conversationID`) from a short-lived native session
  with no Woven tools.
- **Titles.** The host titles a chat from its first message with its own
  Codex (the Mac's instructions); a failure keeps the first-message title, and
  a rename wins.
- **Library files.** A Mac retains an agent's file with `POST
  v1/execution/library-file {conversationID, path}`: inside the session root,
  `/tmp` or `/mnt/data`, no final symlink, 25 MiB.
- **Adoption.** A chat that ran over SSH before moves to its host's server
  when this Mac first opens, refreshes or sends to it. Runs it left unsettled
  are interrupted, each with its assistant message, saying the run was on
  that host and the update interrupted it (a run still running or uncertain
  when the Mac starts is settled the same way); the adoption is fenced in the
  library (`execution_adoptions`), and `POST v1/execution/adopt` carries
  `transcript`: the newest messages and activities that fit in 6 MiB, at
  most 10,000 of each (the host's limits); an entry left running, queued,
  uncertain or streaming arrives interrupted. The host reopens a stopped or
  missing durable channel with `session/load` and leaves no process behind
  when that fails. A channel left interrupted by an ungraceful exit, which no
  process of the host's server holds, is recorded stopped and reopened the
  same way; one whose process still runs is refused. A retry resends the
  same adoption. A chat that
  cannot move (its host is no longer set up or not yet enrolled, it never
  started a native session, or the host refuses) stays in the library as
  read-only history, and sending to it says why.
- **The adding Mac** creates its chats on the host with `createSession`
  (`sessionOptions`, `folderID`, `title`), sends files and context as every
  member does, applies later choices with `workspace` `configureSession`,
  reaches OpenCode through the signed `/v1/workspace-instances/opencode/api/*`
  proxy, and pushes Pi Durable credentials with
  `v1/default-agent/configuration`, signed once the host is enrolled.

## Bots

### Runtime

- The bots runtime is a Node package in `bots/`, ported from Pi Bot's server
  (pinned `wovenmatter/pi-bot` at `6571bb4`) without its web UI. It runs Node
  26 directly; TypeScript runs through Node's built-in type stripping, so
  there is no build step. Its npm lockfile follows `docs/DEPENDENCIES.md`.
- The Woven server on the bot machine supervises it as a child process. It
  listens only on a loopback port and serves Pi Bot protocol 1, with
  additions, over WebSocket at `/ws`. Woven apps reach a remote machine's bots
  through that machine's Woven server at `/v1/bots/ws`, authenticated as a
  member, which then proxies to the loopback socket.
- Each bot's agent loop runs in the runtime on the host, and its tools run
  inside its container through the in-container helper (`bots/helper/`: Pi
  Bot's env agent plus a supervisor, browser and preview forwarder). The
  helper is mounted read-only at `/opt/woven-bot` from a content-versioned
  volume (`woven-bots-helper-<hash>`) that the runtime fills from its own
  install through the Engine API, so a Mac VM needs no file sharing and
  runtime updates need no image change. A bot picks up a new helper on
  Update or Rebuild. Provider keys and
  sign-ins never enter a container. The runtime gets provider credentials the
  same way the machine's default agent does
  (`docs/architecture/DEFAULT_AGENT_CREDENTIALS.md`), and bots use the
  provider connections in Woven settings. Pi Bot's own credential store and
  configuration editor are dropped.
- Woven MCP: each bot gets its own key from the machine's Woven server. The
  principal is `woven:bot:<machine-device-id>:<bot-id>`, with attribution,
  per-bot revoke and pause-all. The existing `WorkspaceToolSettings.botMCP`
  toggles (Settings → Woven MCP → Bots) decide which tool groups bots get. Session management reaches only
  Woven workspaces, under those workspaces' own permissions. Bot schedules
  are Woven MCP timers delivered back to the bot.
- Bot conversations are written into the machine's library copy as
  conversations, so they sync everywhere.

#### Runtime config

`node bots/src/cli.ts serve --config <file>` reads one JSON file that the
Woven server writes (mode 0600). Unknown keys are refused.

```json
{
  "dataDir": "/abs/path",
  "listen": { "host": "127.0.0.1", "port": 4317 },
  "runtimeToken": "≥32 random characters",
  "engine": { "socket": "/run/wovenmatter/docker.sock", "kind": "linux-dockerd" },
  "image": { "tag": "wovenmatter-bots" },
  "limits": { "botMemoryBytes": 4294967296 },
  "host": { "url": "http://127.0.0.1:<port>/", "token": "bearer for the host API" },
  "machine": { "deviceID": "<member device id>", "name": "Studio" },
  "claude": { "executable": "/abs/path/to/claude" }
}
```

- `listen.host` must be loopback (`127.0.0.1`, `::1`, `localhost`). Every HTTP
  request and WebSocket upgrade needs `Authorization: Bearer <runtimeToken>`;
  `Host` and `Origin`, when present, must be loopback.
- `engine.kind` is `linux-dockerd` or `mac-vm`. `image.tag` without a tag
  (`wovenmatter-bots`) gets the content hash of `bots/image` as its tag and is
  built through the Engine API when missing; a tagged name is used as is.
- `limits.botMemoryBytes` is each container's memory limit (`Memory` and
  `MemorySwap`); `null` means no cap.
- `claude` is optional: `executable` (absolute) is the Claude runtime binary
  the machine's default agent ships, passed to the Claude Agent SDK as
  `pathToClaudeCodeExecutable`, so the bots package carries no copy of its
  own. A Mac passes `<Resources>/default-agent/node_modules/@anthropic-ai/claude-agent-sdk-darwin-<arch>/claude`
  and a Linux host `<release>/default-agent/node_modules/@anthropic-ai/claude-agent-sdk-linux-<arch>[-musl]/claude`.
  `scripts/prepare-bots.sh` drops the bots package's own
  `claude-agent-sdk-<platform>` packages (and refuses lockfiles that select
  different Claude Agent SDK versions for `bots/` and `default-agent/`), and
  `remote-host.sh` removes them after `npm ci`; the default agent's copy keeps
  its signature check.
- `host.url` must be loopback `http`. The runtime keeps its own state under
  `dataDir`: `bots.sqlite` (bots, threads, Pi Durable tables, memory, limits,
  cached Woven tool lists, previews), `settings.json` (model profiles, title
  model, memory extraction, compaction, bot-to-bot limits; no secrets) and
  `claude-agent/` (the Claude Agent SDK's private scratch directory).
- Exit on SIGTERM/SIGINT is graceful. Containers keep running across a runtime
  restart and are picked up by the next start.

#### Runtime host API

Served by the machine's Woven server at `host.url`, `Authorization: Bearer
<host.token>`, JSON bodies. Non-2xx means failure; the runtime never shows the
reply body. Replies are at most 1 MiB.

| Request | Body | Reply |
| --- | --- | --- |
| `POST /v1/bots-host/mcp-keys` | `{botID, botName}` | `{endpoint, token}`: the bot's Woven MCP key, principal `woven:bot:<machine.deviceID>:<botID>`. The same bot may ask again (after a restart, or a 401 from MCP); the host returns its current key or rotates it. |
| `DELETE /v1/bots-host/mcp-keys/{botID}` | none | 2xx. Sent when the user purges a bot. The host drops the key and marks the bot's library conversations deleted. |
| `POST /v1/bots-host/previews` | `{botID, port, containerPort}` | `{url}`. `port` is the runtime's loopback activity proxy; the host publishes `http://127.0.0.1:<port>` with Tailscale Serve (its own HTTPS port, inbound only, never Funnel). Idempotent for the same `(botID, port)`; sent again after a runtime restart. |
| `DELETE /v1/bots-host/previews/{botID}/{port}` | none | 2xx. |
| `POST /v1/bots-host/inference-credentials` | `{provider}` | `{credential}`, where `credential` is `null` (not connected), `{type: "api_key", key}`, `{type: "oauth", access, expires, accountId?}` (access only; `expires` epoch ms; the host renews, the runtime asks again a minute before expiry), or `{type: "native", configDir, secureStorageDir?}` (Claude subscription: the machine's native Claude runtime directories, which the default agent uses, passed to the Claude Agent SDK as `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR`; no token material). `provider` is a Woven connection id: `openai-codex`, `openai`, `openrouter`, `opencode-go`, `xai`, `xai-api`, `claude-subscription`, `anthropic`, `exa`, `brave`, `firecrawl`, or `web-search`, which also returns `searchProvider` (`exa`, `brave` or `firecrawl`, the selected web search provider) with that provider's key. |
| `POST /v1/bots-host/conversations/{botID}/entries` | `{bot: {id, name}, conversations: [{conversationId, kind: "main"\|"thread", parentConversationId?, forkedAt?, title?, pinned?, createdAt?}], entries: [{id, conversationId, role: "user"\|"assistant", text, error?, stopped?, createdAt}]}` | 2xx. The host writes them into its library copy, upserting entries by `(botID, id)` and conversations by `(botID, conversationId)`. Entry ids are unique per bot and never reused. `id`, `conversationId`, `parentConversationId` and `forkedAt` are non-negative integers (the runtime's own ids; the library host decodes them as integers), and the server refuses a batch with any other type. `conversations` always lists the bot's main channel and every thread; a batch may have no entries when only metadata (a title, a pin, a rename) changed. Batches hold at most 200 entries, in id order; the runtime resends after a failure. |

The runtime caches credentials in memory only (keys 60 s, "not connected"
15 s) and never stores them. A credential change in Woven settings takes
effect within that window.

#### Runtime protocol

Pi Bot protocol 1 over WebSocket at `/ws`: JSON text frames, each request
`{id, type, …}` answered by `{type: "result", id, data}` or `{type: "error",
id?, message}`. `hello` carries `version`, `protocol: 1`, `installationId`,
`capabilities` and `environment` (`none`, `linux-dockerd` or `mac-vm`).
Capabilities: `groups`, `woven.mcp`, `message.context`, plus the additions
`bots.environment`, `runtime.update` and `previews`. `GET /health` returns the
same identity with `ok: true`.

Kept from Pi Bot, with their wire shapes: `bots.list`, `bots.create`,
`bots.delete`, `bots.listDeleted`, `bots.restore`, `bots.purge`,
`bots.rename`, `bots.setManager`, `bots.setTeam`, `bots.replaceManager`,
`bots.setOrchestrator`, `bots.setGroup`, `bots.setProfile`, `groups.list`,
`groups.create`, `groups.rename`, `groups.delete`, `groups.reorder`,
`onboarding.status`, `onboarding.setMainModel`, `profiles.list`,
`profiles.save`, `profiles.delete`, `profiles.setDefault`, `memory.list`,
`memory.add`, `memory.update`, `memory.delete`, `account.notes`,
`account.setNotes`, `conversation.open`, `conversation.close`,
`conversation.abort`, `message.send` (with `context` and `deliveryId`),
`thread.fork`, `thread.setPinned`, `threads.list`, `models.catalog`,
`models.setRoles` (now live: `restartRequired` is always `false`).

Changed:

- `woven.status` → `{state, toolCount, error?, bots: {<botId>: {state,
  toolCount}}}`, aggregated over the bots' own keys. `woven.connect` and
  `woven.disconnect` are gone: keys come from the host API.
- `settings.accounts` is read-only: `{accounts: [{id, label, group, method,
  configured}], search: {provider, providers: [...]}}`, with Woven connection
  ids.
- No model is assumed. A fresh profile set has a `default` profile with no main
  model (`main: ""` on the wire) and no title model (titles then use the default
  profile's main model). `onboarding.status` reports `needed` until Admin Bot's
  profile has a signed-in main model; the app's chooser lists every connected
  model, newest first, and saves the user's pick with `onboarding.setMainModel`,
  which then starts Admin Bot's greeting once (a hidden input, only while its
  main channel is empty). A bot whose profile has no main model refuses
  `message.send`. Bot messages may link to `wovenmatter://settings/accounts` and
  `wovenmatter://settings/bots/profiles`, which open those pages in the app.
- Chat entries carry `issue` (`signIn` or `limit`) when a failed reply has a fix
  in Settings; the app shows Subscriptions & API Keys and Change model there.
  Claude subscription is offered to bots only while a Claude account is signed
  in to Subscriptions & API Keys.

Dropped: `credentials.set`, `credentials.remove`, `login.start`,
`login.respond`, `login.cancel`, `config.get`, `config.validate`,
`config.save`, `config.update`, `github.get`, `github.setSshKey`,
`github.generateSshKey`, `github.removeSshKey`, `github.setIdentity`,
`server.restart`, and the `login` push. Sign-ins and keys are Woven
connections; bots set up their own git and SSH inside their containers.

Added requests:

| Request | Reply |
| --- | --- |
| `bots.environment {botId}` | `{environment: {botId, state: "missing"\|"running"\|"stopped"\|"unavailable", busy?, lastActivity?, services?, previews: [{port, url}]}}`. `busy` says why a running bot is not idle now; `services` is the restart list with each service's state. |
| `bots.stop {botId}` | `{stopped: true}`. The next tool call starts the container again. |
| `bots.rebuild {botId}` | `{rebuilt: true}`. A clean container from the current image and helper; storage, restart list and browser profile stay. |
| `previews.list {botId?}` | `{previews: [{botId, port, url}]}` for one bot or all (`port` is the container port). |
| `previews.stop {botId, port}` | `{stopped: boolean}`. |
| `runtime.update {botIds?}` | `{started: true}` at once; the update runs for all bots (or the listed ones), one at a time. |
| `runtime.status` | `{version, environment, bots}`. |

Added pushes:

- `{type: "runtime.update", botId?, phase, error?}` with `phase` `stopping`,
  `updating`, then `updated`, `rolledBack` or `skipped` per bot, and one final
  `done` (with `error` if the run itself failed).
- `{type: "bots.environment.changed", botId, state}` after stop, rebuild and
  update.

Bot tools added by the runtime: `keep_running {name, command, cwd?}`,
`keep_running_list`, `keep_running_remove {name}`, `keep_running_logs {name,
lines?}`, `browser {action: navigate|read|screenshot|click|type|tabs|new_tab|
close_tab, url?, tab?, selector?, text?, label?, value?, submit?, fullPage?,
maxChars?}`, `share_preview {port}`, `stop_preview {port}`, `list_previews`.
Pi Bot's Admin Bot config tools (`read_config`, `update_config`,
`restart_server`) are gone; `settings_status` reports connections and models.

#### Container layout

- Container `woven-bot-<botId>`, storage volume `woven-bot-<botId>-workspace`
  at `/workspace`, snapshot `woven-bot-<botId>-snapshot` (volume) and
  `woven-bot-snapshot:<botId>` (image). Labels `woven.bot=<botId>`,
  `woven.bots.machine=<deviceID>` and `woven.bots.helper=<helper volume>`; the
  runtime only ever touches containers with its own machine label.
- User `bot` (passwordless sudo), `tini` as PID 1, the supervisor as its
  child, restart policy `no` (the runtime decides when bots run), 512 MiB
  `/dev/shm` for Chromium, no published ports, no host mounts, no Docker
  socket. `CapDrop: [NET_RAW, MKNOD]` (`DROPPED_CAPABILITIES`): no raw
  sockets (no packet forging or ARP spoofing on the bot network; `ping` does
  not work) and no device nodes; sudo, apt and headless Chromium (Playwright
  launches it without its sandbox) keep Docker's other default capabilities.
  Existing containers pick this up when an update recreates them.
- Bot state the runtime owns lives in the storage volume under
  `/workspace/.woven/`: `services.json` (restart list), `logs/<name>.log`,
  `browser/profile/` (Chromium profile) and `browser/tabs.json` (open tabs,
  saved on every change and on stop).

### Engine

- The runtime talks to a Docker Engine API over a Unix socket; no `docker`
  CLI is required. The engine is never the user's own Docker.
- **Linux:** Woven installs its own `dockerd` instance (unit
  `wovenmatter-docker.service`) with its own socket
  (`/run/wovenmatter/docker.sock`), data root, exec root and bridge. Installing
  it needs sudo once.
- **Mac:** a Woven-managed Linux VM (Virtualization framework) runs Docker
  Engine. Its socket is forwarded over vsock to a Unix socket under the app's
  support directory. The VM stays running so a wake only starts a container.
  Virtualization never takes back memory a guest once touched, so the balloon
  caps the guest at what it uses plus headroom from boot on, and the helper
  restarts the VM when no container has run for a while and it holds much
  more than that (see Mac VM, Resources).

#### Mac VM

The VM belongs to `WovenMatterVMHelper`, a per-user launch agent bundled at
`Contents/Helpers/WovenMatterVMHelper` (Apple silicon only; signed with
`com.apple.security.virtualization`, built by `scripts/build-vm-helper.sh`).
Its job is `~/Library/LaunchAgents/<bundle id>.vm.plist`, label
`<bundle id>.vm`, with `KeepAlive: {SuccessfulExit: false}`: a crash or kill
restarts it, a clean stop leaves it stopped. Killing the helper reboots the
guest, like a power cut: containers, images and volumes survive, containers
with a restart policy come back, and writes not yet synced in the last few
seconds may be lost (the guest writes back dirty data within about 2 s and
commits the data disk's journal every 2 s; fsync'd data is durable). The helper is started on demand by the app; it then also starts at
login until `stop()`.

- **Files.** Everything lives in `<support directory>/WovenVM`, where the
  support directory is the app's workspace folder (`Woven Matter`, or the
  Dev instance's folder): `disk.img` (16 GB sparse root), `data.img` (sparse
  data disk as large as the volume, holding `/var/lib/docker` and
  `/var/lib/containerd`), `efi-vars.fd`, `seed.iso`, `config.json`,
  `state.json`, `console.log`, `helper.log` and `snapshot/`. Sockets are
  `docker.sock` and `control.sock` in the same folder (0600, folder 0700),
  or in `/private/tmp/wovenmatter-vm-<uid>-<digest>/` when that path would
  exceed `sun_path`. The helper creates that folder 0700 and refuses to
  listen, and the app to connect, unless `lstat` shows a real directory owned
  by this user (`WovenVMPaths.preparePrivateDirectory`); a wider mode is
  tightened. Always read the socket path from the API, never build it.
- **Guest.** The pinned Ubuntu 26.04 LTS arm64 cloud image
  (`app/VMHelper/guest-version.json`), converted from QCOW2 to a raw disk on
  first run, EFI boot, cloud-init NoCloud seed. First boot purges
  unattended-upgrades, snapd and SSH, masks the apt timers, formats the data
  disk and installs the pinned Docker Engine from Docker's signed apt
  repository (packages held). The guest changes only through Woven's update.
  It has no user, password or SSH key; the Mac reaches it over vsock only,
  and the guest agent accepts only the host CID.
- **Provisioning steps.** `provision.sh` runs each step under its own time
  limit (first boot: turning off automatic updates 15 min, the bot disk 15,
  installing Docker Engine 30, network rules 5, starting Docker Engine 5;
  the update adds guest packages 60 and removing unused packages 15). A step
  that hangs is ended with its whole process group and fails as "<step> did
  not finish within N minutes". The guest's status records the step, its
  limit and the boot ID. The helper follows it through the agent's `status`,
  which answers at once: it asks Docker Engine (2 s at most) only once the
  guest is provisioned. The helper enforces the same limits 2 minutes later,
  for a guest too stuck to report. It also fails when the agent stops
  answering for 5 minutes, when the guest never answers within 10, or when a
  provisioned guest's Docker Engine does not answer within 5. A failure
  writes the guest's diagnostics to `helper.log` and names a guest kernel
  fault if there was one. The helper then reboots the VM once and lets
  provisioning resume, since it runs on every boot until it succeeds. A
  second failure leaves the VM `failed` with the reason, still running for
  `GET /v1/diagnostics`. Measured on a MacBook Air (M4, macOS 27.2): in the
  first incident, a slab fault in the guest kernel (Ubuntu 7.0.0-38) while
  loading `overlay` wedged every later module load, so containerd never
  started. The guest reported the failure within three minutes, but the
  helper missed it: the agent's `status` waited 10 s on a Docker Engine that
  was still starting, and the helper gave up after 5 s, so it saw no answer
  for 21 minutes.
- **Disk caching.** All three disks attach with `cachingMode: .cached` and
  `synchronizationMode: .full`, so every guest flush is still durable on the
  Mac. With `.automatic`, 4 of 16 first boots on the MacBook Air from a root
  disk the helper had just converted hit guest kernel faults in unrelated
  subsystems (slab, seccomp, PSI, the scheduler); one also corrupted ext4.
  None of 11 boots from an APFS clone of the same disk faulted. Others
  report that `.automatic` corrupts sparse virtio disks. With `.cached`, 3
  of 3 fresh first boots under host CPU load were clean, a sample too small
  to prove the fix. Healthy first boots provision in about 1 to 2 minutes.
- **Engine socket.** `docker.sock` carries the Docker Engine API to the
  guest's dockerd (vsock 2375). It is byte-transparent: HTTP upgrade and
  hijack (attach, exec) work, and each direction ends independently, so an
  exec whose stdin closed still returns all its output. Before the VM is
  ready it answers `503 {"message": ...}`.
- **Egress.** Inside the guest, `WOVEN-EGRESS` (from `DOCKER-USER`, all
  Docker bridges) rejects container traffic to 100.64/10,
  fd7a:115c:a1e0::/48, RFC 1918, link-local, ULA, loopback, multicast and
  every address of the Mac (pushed by the helper), and `WOVEN-INPUT` rejects
  container traffic to the guest itself. DNS to the NAT gateway is the one
  exception. Containers on one bridge reach each other only through
  `br_netfilter`, which `egress.sh` loads before setting
  `bridge-nf-call-iptables`, so the private-range rejects stop that too.
  Each iptables call waits at most 30 s for the xtables lock. Containers have no `CAP_NET_ADMIN` in the guest namespace and
  cannot open vsock sockets. The bots runtime must never create
  privileged or host-network containers, or mount the socket.
- **Resources.** The VM boots with the RAM pool (no cap: all RAM), which is
  the hard limit. A change applies fully at the next VM restart, which the
  helper performs by itself when no container runs; until then a lower pool
  is applied through the balloon, which the guest may deflate under memory
  pressure (Virtualization's balloon offers deflate-on-OOM).
- **Memory on the Mac.** Measured on macOS 27.2: Virtualization's balloon
  never discards the pages a guest puts in it (no free page reporting or
  hinting either), so the VM process's footprint is the high-water mark of
  the memory the guest ever touched, and only a VM restart lowers it.
  Ballooning memory the guest has used gives nothing back. Ubuntu's kernel
  also zeroes every page it allocates, including pages for the balloon,
  which made inflating it cost the Mac those pages (an idle 8 GiB VM went
  from 1.3 to 7.2 GB footprint when the balloon closed to 2 GiB). Apple
  silicon cannot run 64 KiB-page guests and Ubuntu ships no 16 KiB kernel,
  so larger guest pages are no way out. What works:
  - The guest boots with `init_on_alloc=0` (provisioning and Woven's update
    set it in GRUB; the helper reboots a guest once when it is ready without
    it). Ballooned pages are then never touched and cost nothing.
    The helper uses the balloon only on a guest whose `/proc/cmdline`
    (guest agent `status`) shows it; for any other guest it stays open.
  - The balloon caps the guest from boot (`state.json`
    `guestLeavesBalloonUntouched` remembers the last guest's kernel): it
    starts at 1 GiB plus the headroom (3 GiB for an 8 GiB pool) and follows
    the guest's demand, so Linux cannot spread page cache over memory it does
    not need. Demand
    is used memory (MemTotal - MemAvailable) minus what the balloon really
    holds (`balloon_inflate - balloon_deflate` from `/proc/vmstat`) plus
    dirty and writeback pages; clean page cache counts as free. The target is
    demand plus headroom (the larger of 1 GiB and a quarter of the pool), at
    least 1.5 GiB, at most the pool.
  - Every second the helper reads the guest's memory. It raises the target
    at once when demand grows. It opens the balloon fully when the guest is
    under memory pressure: stalls of 1% or more (`/proc/pressure/memory`
    `some`), page cache read back at 8 MiB/s or more
    (`workingset_refault_file`), available memory below half the headroom,
    or no answer from the guest agent within a second. It lowers only after
    demand stayed lower for 30 seconds and the guest has had no pressure for
    60, by at most 1 GiB every 5 seconds, so the first sign of pressure
    stops it; stalls within 3 seconds of a step are the balloon's own
    reclaim and do not count. An allocation faster than the headroom can
    stall for about a second until the balloon opens; it is not killed.
  - When the guest has been idle for 10 minutes (no running container and a
    load average below 0.5, since an image build runs no listed container;
    the RAM pool restart uses the same idle test) and the footprint exceeds the
    current target by more than 1 GiB, the helper restarts the VM (at most
    every 30 minutes), which returns everything the guest touched; stopped
    bots lose nothing. Running containers keep the footprint at its
    high-water mark until they stop.
  - `vmMemoryFootprintBytes` is the VM process's `phys_footprint` (what
    Activity Monitor shows), `guestMemoryUsedBytes` the demand above and
    `balloonTargetBytes` the cap in effect.
  - Measured on the Mac Mini, macOS 27.2 (8 GiB pool, guest idle at about
    0.6 GiB). Before: the first image build ended at 8.2 GB footprint and
    stayed there idle. After, in two runs from a fresh disk: boot 1.3 GB;
    the first image build (3.3 and 4.3 minutes, capped at 3 GiB until a
    stall opened it) 5.3 GB; one bot through the real-engine test 3.5 GB
    from an idle-restarted VM (its snapshot commit re-read evicted cache and
    opened the balloon), 5.6 GB right after the build; the idle restart 10
    minutes later back to 1.3 GB, capped at 2.6 GiB.
- **Limits and disk.** Per-container memory limits (`Memory`, `MemorySwap`)
  are enforced by the guest kernel (cgroup v2). The disk cap is enforced inside the guest by a
  reserve file of unwritten extents on the data disk, so raising and lowering both apply at
  once while running; lowering stops at what is used. Freed blocks are
  trimmed back to the Mac every ten minutes.
- **Time.** The helper sets the guest clock on wake
  (`NSWorkspace.didWakeNotification`) and every minute.
- **Updates.** `update()` shuts the guest down, saves APFS clones of the
  disks to `snapshot/` (one kept), boots, upgrades guest packages and the
  pinned Docker Engine (also delivering the bundle's current guest files),
  reboots and health-checks Docker. On failure it restores the clones and
  reports `updateFailure`. A new image pin affects new installs only.

**Swift API** (`WovenMatterClient`, `WovenVMController`):

| Call | Meaning |
| --- | --- |
| `WovenVMController.forApp(supportDirectory:)` | Nil on Intel or without the helper |
| `ensureRunning()` | Install/refresh the launch agent, start the helper, return status |
| `status()`, `waitUntilReady(timeout:progress:)` | `WovenVMStatus`: `phase` (`stopped`, `downloading`, `preparing`, `booting`, `provisioning`, `ready`, `updating`, `failed`), `detail`, `failure`, `progress`, `engineSocket`, `resources`, `guest`, `forwards`, `updateFailure`, `snapshotAvailable` |
| `diagnostics()` | `WovenVMDiagnostics`: the status, the ends of `helper.log` and `console.log`, and the guest agent's report as text (`provision`, `update`, `provision_log`, `kernel_alerts`, `kernel_log`, `failed_units`, `jobs`, `processes`, `load`, `uptime`, `cloud_init`), or `guestError` when the guest does not answer |
| `engineSocket` | Docker Engine API Unix socket for the bots runtime |
| `applyResources(WovenVMResources(memoryBytes:diskBytes:))` | `nil` means no cap |
| `forwardPreview(WovenVMForwardRequest(container:port:hostPort:))` | Optional; the runtime carries previews over Engine API exec streams and does not use it. Returns `WovenVMForward` with the `127.0.0.1` `hostPort`; idempotent; resolved by container name at connect time; survives restarts |
| `unforwardPreview(id:)`, `forwards()` | |
| `update()`, `restart()` | |
| `stop()` | Shut down, stop the helper, remove the launch agent |
| `uninstall()` | `stop()`, then delete every VM file |

`resources` (`WovenVMResourceReport`) gives the Mac's total RAM, disk total
and free, the VM's boot memory, physical footprint, guest memory in use,
balloon target, the effective disk cap, the disk images' real allocation,
guest disk use, and `restartPending`.

**Control API** for other processes: HTTP/1.1, JSON,
one request per connection on `control.sock` (e.g.
`curl --unix-socket <control.sock> http://vm/v1/status`):
`GET /v1/status`; `GET /v1/diagnostics` (up to a minute while the guest
answers); `PUT /v1/resources`; (optional forwards) `GET /v1/forwards`;
`POST /v1/forwards` with `{"container": "<name or id>", "port": 3000}` (or
`"address"` instead of `"container"`, optional `"hostPort"`) returning
`{"id", "hostPort", ...}` with 201; `DELETE /v1/forwards/<id>`;
`POST /v1/update`, `/v1/restart`, `/v1/stop` (202). Errors are
`{"error": "..."}`.

- **Image:** Ubuntu 26.04 LTS with Chromium and Playwright, git, Node, Python,
  build tools and tini. A bot runs as a user with passwordless sudo, which
  gives it full root inside its container.
- **Network:** the container has internet access. Outbound traffic to the
  tailnet (CGNAT 100.64/10, fd7a:115c:a1e0::/48), private and link-local ranges
  and the host is blocked by the engine host: iptables on the Woven bridge on
  Linux, and inside the guest on a Mac. No container port is published, not
  even for previews (see Previews). The Docker socket is never mounted into a
  bot.

#### Linux engine and host wiring

- **Install.** `scripts/remote-host.sh` runs `remote/host/bots-engine.py` with
  the account's existing `sudo -n` once (`install` with the `bots` role, or
  `bots-enable`). It copies itself to `/usr/local/lib/wovenmatter-bots/bots-engine`
  (root-owned) and installs Docker's official static binaries, pinned with
  SHA-256 in `remote/host/runtime-versions.json`. No distribution package and
  no sudoers rule is added. Everything is named from one instance
  (`wovenmatter`; isolated tests set `WOVENMATTER_BOTS_INSTANCE`).
- **Units.** `wovenmatter-docker.service` (`dockerd --config-file
  /etc/wovenmatter-bots/daemon.json`, socket `/run/wovenmatter/docker.sock`,
  root `0660`, group = the account's primary group, which must have no other
  members), `wovenmatter-containerd.service` (its own containerd at
  `/run/wovenmatter/containerd/containerd.sock`; dockerd would otherwise join
  a system containerd and share the user's Docker `moby` namespace),
  `wovenmatter-bots-firewall.service`, `wovenmatter-bots-apply.path`/`.service`,
  and `wovenmatter-bots.slice` (`MemoryMax` = RAM pool, `infinity` for no cap).
  The engine and every container (`cgroup-parent`) run in the slice. Data root
  `/var/lib/wovenmatter-bots/docker`: a sparse ext4 image (`disk.img`) mounted
  by `var-lib-wovenmatter\x2dbots-docker.mount` when there is a disk cap, a
  plain directory when there is none.
- **Network.** Bridge `br-wovenbots` on a free private /24 (the first of
  `10.237–251.0.0/24` that overlaps no route or address; the bridge is `.1`).
  dockerd hands containers addresses from the bridge's own network, so the
  recorded `subnet` and every rule that names it (the drop of bridge traffic
  from any other source, the masquerade, and the `WOVENMATTER-BOTS` accept)
  use that /24; an engine whose record still says /16 is filtered as its /24
  and rewritten on the next install or update. dockerd runs with
  `iptables`/`ip6tables`/`ip-forward` off and never touches the user's chains. The Woven nftables table `inet
  wovenmatter_bots`, replaced atomically on every engine start and after
  `nftables.service` reloads, drops all IPv6, all traffic from the bridge to
  the host itself, new connections into the bridge, and forwarded traffic to
  0/8, 10/8, 100.64/10 (tailnet and MagicDNS), 127/8, 169.254/16, 172.16/12,
  192.168/16 and the other special-use ranges; it masquerades the rest. A
  Woven iptables chain (`WOVENMATTER-BOTS`, jumped first from `FORWARD`) only
  accepts what that table allowed, for hosts whose `FORWARD` policy is DROP.
  Bot containers cannot reach each other: the table `bridge
  wovenmatter_bots` drops every frame bridged between two ports of
  `br-wovenbots` (`meta ibrname/obrname`), without loading `br_netfilter` or
  affecting any other bridge; bots need no path to each other, since the
  runtime reaches them through the engine's exec API. (dockerd refuses
  `icc=false` while `iptables` is off, so the engine does not set it.)
- **Forwarding.** Bots need host-wide IPv4 forwarding. When the engine is
  the one turning `ip_forward` on (marker `/run/wovenmatter/forwarding-enabled`
  until the next boot), it also owns what that means for the host's other
  interfaces: it sets the iptables `FORWARD` policy to DROP, as dockerd does
  when it enables forwarding (Docker, libvirt and VPNs add their own accepts
  there), or, with no iptables, drops all non-bot forwarding in its own inet
  table. A host that already forwarded (the user's Docker, a VPN, a router)
  is left to its owner. `state.json` records `forwardPolicy` (`iptables`,
  `nftables` or `null`).
  Containers use Cloudflare's and Google's public resolvers. Bots use only the
  default bridge: the runtime creates no networks, and the engine sets no
  `default-address-pools` (with them, dockerd deletes the host's `docker0` on
  every restart).
- **Settings.** The server, which has no sudo, writes
  `{revision, poolBytes, diskBytes}` (bytes or `null` for no cap) to
  `/var/lib/wovenmatter-bots/requests/settings.json`; the path unit applies it
  as root and records `appliedRevision` in `/var/lib/wovenmatter-bots/state/state.json`.
  Pool changes and disk growth are immediate; shrinking stops the engine and
  stops at the space in use; switching between a cap and no cap migrates the
  data. `remote-host.sh bots-configure ID POOL DISK` uses the same request.
- **Uninstall.** `bots-disable` (workspace kept) or `uninstall` removes the
  units, slice, mount, image, data, bridge, nftables tables and iptables chain,
  and restores `ip_forward` if Woven turned it on.

#### One server, roles

- `remote-host.sh install|update ID PORT MODE FINGERPRINT [ROLES]` takes
  `workspace`, `bots` or `workspace,bots` (default: the recorded roles, or
  `workspace`). Roles only grow on update; a bots-only server skips the host
  Chromium. The installation record gains `roles`; the service environment
  gains `WOVENMATTER_WORKSPACE_ENABLED`, `WOVENMATTER_BOTS_ENABLED`,
  `WOVENMATTER_BOTS_INSTANCE`, `WOVENMATTER_BOTS_DATA` (`<data root>/bots`)
  and `WOVENMATTER_DATA_ROOT`. With the workspace off the server answers
  workspace routes (execution commands, schedules, projects, harnesses,
  browser, databases) with `409 workspace_disabled` and starts no scheduler.
- `remote-host.sh inspect [MODE] [ROLES]` adds `bots`: `state` (`no_server`,
  `server_without_bots`, `bots_ready`), `engine`, `memoryTotalBytes`,
  `diskTotalBytes`, `diskFreeBytes` (the filesystem holding
  `/var/lib/wovenmatter-bots`), `defaultPoolBytes`, `defaultDiskBytes` and
  `blockingIssues`. `status` adds `roles` and `botsState`.
- Host releases ship `bots/package.json`, `bots/package-lock.json`,
  `bots/src/**`, `bots/helper/**` and `bots/image/**` when the checkout or app
  has them, and run `npm ci --omit=dev --ignore-scripts` in `bots/` on the
  host. Nothing else under `bots/` ships.

#### Server side

- The server supervises `node bots/src/cli.ts serve --config
  <state>/bots/runtime.json` (0600), regenerating `runtimeToken`, the
  loopback port and the host bearer on every start, and restarting a crash
  with backoff up to 30 s. It starts the runtime once the engine is
  installed. `image.tag` is `wovenmatter-bots`; `machine.deviceID` is the
  library host's member identity, or, without a library host,
  `WOVENMATTER_DEVICE_ID` or `<data root>/identity/device-id` (0600, created
  once).
- It implements the runtime host API under `/v1/bots-host/` with that bearer.
  Previews publish `http://127.0.0.1:<port>` (the runtime's proxy) with
  `tailscale serve --bg --https=<17000–17999>`, never Funnel, verify the
  route, and remove only routes they recorded (`<state>/bots/previews.json`).
  Credentials come from the default agent's store, access-only. Bot MCP keys
  are stored as digests; bot callers get only library-delegated tools, with
  `x-woven-caller`, `x-woven-bot-id` and `x-woven-bot-name` attribution.
  Pause-all is `botMCP.isEnabled = false`.
- Conversation batches go through `library.writeBotEntries(botID, {bot,
  conversations, entries})` (`remote/src/bots-library.mjs`). Adapters upsert
  by entry and conversation id. The library adapter posts each batch to the
  library host's `POST /v1/bots/{botID}/entries`; while the host is down or
  refuses, it appends the batch as one JSON line to
  `<data root>/bots/library-outbox/<botID>.jsonl` (0600) and replays that
  outbox, in order, when the host is ready again.
- App-facing routes, authenticated as a member (or, during the transition,
  administrator bearer or device grant; `authorizeClient` in
  `remote/src/bots-service.mjs`):
  `GET /v1/bots/status`, `GET /v1/bots/resources` (`memory {totalBytes,
  poolBytes, botBytes, usedBytes}`, `disk {path, totalBytes, freeBytes,
  capBytes, imageBytes, usedBytes}`, `warnings`), and `GET /v1/bots/ws`
  (WebSocket, proxied to the runtime's `/ws` with the runtime token; any
  `Origin` header is refused, since only native apps connect: the Mac's
  `URLSessionWebSocketTask` sends none, which `PiBotHandshakeTests` checks).
  Administrator only: `POST /v1/bots/enabled {enabled}`, `POST /v1/bots/resources {resources: {poolBytes?,
  perBotBytes?, diskBytes?}}` (a missing field stays; a pool below per-bot
  RAM lowers it), `GET|POST /v1/bots/mcp {isEnabled?, groups?}` (the `GET`
  adds `revoked: [{botID, revokedAt}]`), `DELETE /v1/bots/mcp/keys/{botID}`
  and `POST /v1/bots/mcp/keys/{botID}/reinstate`. That DELETE is the user's
  revoke and sticks, as on a Mac (`WovenMCPHost`): the bot is recorded in
  `mcp_bot_revocations`, and the runtime's `POST /v1/bots-host/mcp-keys`
  for it answers `403 {error: "revoked"}` until reinstated. The runtime's
  own `DELETE /v1/bots-host/mcp-keys/{botID}` (a bot it deleted) drops the
  key without that record and, as on a Mac, marks the bot's library
  conversations deleted: `library.deleteBot(botID)` calls the library host's
  `DELETE /v1/bots/{botID}/conversations` after the bot's outbox has drained,
  or appends `{"deleteBot": true}` to the outbox while the host is down, so a
  replayed batch cannot bring them back. `GET /v1/bots/status` and the
  resources reply use the shape in "Woven server routes for bots" below,
  plus `workspaceEnabled`, `runtimeAvailable`, `engine`, `runtime` and
  `settings`. On Linux `versions.app` is the Woven Matter version that shipped
  the host release (the bundle manifest's `releaseVersion`, which
  `remote-host.sh` passes as `WOVENMATTER_RELEASE_VERSION`; `null` for older
  releases), `versions.fingerprint` is the release fingerprint,
  `versions.librarySchema` is the library host's paired-library schema hash
  once its ready line carries `schema` (`null` until then), `versions.runtime`
  is the bots package version and `paused` is `botMCP.isEnabled == false`.
  `GET /v1/health` carries the same as `release {version, fingerprint,
  librarySchema}`. A Mac treats a Linux host whose fingerprint differs from the
  host release it would install (`RemoteWorkspaceSSHClient.bundledHostFingerprint()`)
  as `needsUpdate`, whatever version it names.
  `/v1/execution/mcp-settings` also carries `botMCP {isEnabled, groups}`.

### Resources

- **RAM pool:** default 8 GB per machine. It may be set anywhere from 1 GB to
  the device's total RAM, or to no cap. Show the device's total RAM, and warn
  when the pool leaves the device less than 4 GB.
- **Per-bot RAM:** default 4 GB. It may be set anywhere up to the pool, or to
  no cap.
- **Disk:** one total cap for all bots, default 50 GB. It may be set up to the
  disk's total size, or to no cap. Show the disk's total size and free space,
  and warn when the cap exceeds free space.
- **Enforcement on Linux:** a cgroup slice (`MemoryMax`) for the engine and a
  sparse disk image for its data root. On a Mac: the VM's memory and its
  sparse disk. Per-bot RAM is the container memory limit. Raising the disk
  cap is immediate; lowering it stops at what is already used.

### Idle and wake

- A bot stops fully after 15 minutes idle. The period is fixed.
- A bot is idle when it has no turn running, no command running, no timer due
  soon, no one viewing its chat, and no preview traffic during the period.
  - "No command running": no tool call in flight and no process in the
    container besides PID 1, the supervisor and everything under it (the
    restart list and the browser, which come back on wake), env agents and
    preview forwarders. Children of an env agent and orphaned background jobs
    count. A process check that fails counts as busy.
  - "No timer due soon": none of the bot's Woven timers (`woven_timers_list`
    through its own MCP key) fires within 5 minutes. When that can't be told
    (no timer tool, Woven unreachable) it doesn't block the stop: a due timer
    reaches the bot as `message.send`, which wakes it anyway.
  - Activity that restarts the period: a tool call, `conversation.open`,
    `message.send`, and each preview connection or byte.
  - Stopping sends SIGTERM with 20 seconds' grace: the supervisor saves open
    tabs, closes the browser profile and stops the restart list.
- On wake, the agent loop is already running in the runtime, so it can reply
  immediately. The container starts on the first tool call. After that, the
  restart list and the browser come back in the background.
- **Restart list:** the bot registers long-running services with a Woven
  tool, `keep_running` (name, command, directory). The helper supervises them
  inside the container and starts them on every container start.
- **Browser:** Woven owns a persistent Chromium profile in the bot's storage.
  Tabs, cookies and sign-ins survive a stop, and open tabs reopen on wake.
  Bots get a browser tool built on Playwright inside their container.

### Previews

- The bot asks to share a container port (`share_preview`). The runtime runs
  a small activity-counting TCP proxy on a loopback port of the engine's host
  machine and asks the host API to publish that proxy with Tailscale Serve on
  the host's tailnet name using its own HTTPS port. The bot gets back the URL
  to give the user. HTTP and WebSockets pass through unchanged.
- The proxy reaches the container port over the Engine API: each connection
  is a Docker exec of the helper's forwarder (`/opt/woven-bot/forward.mjs
  <port>`) with the bytes on its hijacked stdio. Docker cannot add a port
  binding to an existing container without recreating it, and this works
  the same through a Mac VM's forwarded socket, so no container port is ever
  published and the Mac VM needs no port forwarding. A preview connection
  starts a stopped container, and the forwarder retries a refused port for up
  to 20 seconds, so the request that woke the bot reaches its service once the
  restart list has started it. The transport is a replaceable hook
  (`PreviewTransport` in `bots/src/environment/previews.ts`, passed as
  `previewTransport` to `startRuntime`) should a host integration want a
  direct path.
- Previews are inbound only and never use Funnel.

### Updates

- The UI offers "Update everything" across all devices. Each part can also be
  updated on its own: this Mac's app, a Linux host, or bots from the Bots
  page.
- Clicking Update stops running work immediately. Woven snapshots each bot
  (container filesystem and storage), updates it in place, runs a health
  check, and rolls back to the snapshot on failure. Only the snapshot from the
  last update is kept. Afterwards it restarts from the restart list and tells
  the bot that its last turn was interrupted.
- **Rebuild** recreates a bot from a clean image while keeping its storage.
- In the runtime (`runtime.update`): running turns are aborted first, then for
  each bot, one at a time: stop the container, commit it to
  `woven-bot-snapshot:<botId>` and copy its storage volume into
  `woven-bot-<botId>-snapshot` (replacing the previous snapshot), recreate the
  container from that commit with the current helper and limits, start it,
  run `apt-get update && apt-get -y upgrade` as root, and health-check it
  (`node --version`, `sudo -n true`, writable `/workspace`, the supervisor
  answering). On any failure the container is recreated from the snapshot
  with its previous helper and the storage copied back. The supervisor starts
  the restart list and the browser on every start. Each conversation whose
  turn was aborted then gets a message saying the environment was updated and
  the last turn stopped part-way, so the bot can continue.

### Discovery and UI

- **Install on another device**, on the Bots page, lists every
  online Linux and macOS tailnet peer and its state:
  - a Linux machine with no server, or whose server has no bots: install bots
    (sudo once). A Woven server is not a bots host until it says so: for a host
    this Mac added the state is `remote-host.sh inspect`'s `bots.state`
    (`bots_ready` is ready), for one another Mac added its `GET /v1/bots/status`
    `enabled`. A check that fails shows its error, with Install bots to retry;
  - a Mac without the app: "Install Woven Matter on this Mac first", with the
    steps (download, open, pair in Apple Devices, finish the setup card);
  - ready.
- **Install bots** (`installBots`) inspects the peer first. No server: `prepare`
  and `install` with the `bots` role, a new bots-only server this Mac records. A
  server without bots (a workspace host, or one whose engine step failed):
  `prepare` for its roles plus `bots`, then `update` with the `bots` role, which
  keeps its workspace, its bearer and its record wherever it lives. A bots-only
  server this Mac has no record of (an install that never reported back) is
  installed again with a new bearer.
- **Long commands are jobs.** A window reaches the background server in one
  request that waits at most 30 s (`BackendRPCClient.maximumWait`), and an
  install or a Linux host update takes minutes. So `installBots` and
  `updateLinuxHost` start a job there and answer at once. Each job's step and,
  when it fails, its error travel in every bots snapshot (`BotsCommandResult.jobs`;
  an install also shows as its device's `installing` or `failed` state, an update
  as the machine's `updating`) until the next run for that target, and every
  change refreshes the windows. "Update everything" follows a host's update job
  to its end. A fresh Find devices clears finished installs.
- The native SwiftUI bot UI and settings come from PR #226, adapted to this
  runtime and to Woven's provider connections.

### Woven servers and apps

The runtime's config, host API and protocol are above (Runtime). These are the
other interfaces between Woven servers and apps.

**Supervision on a Mac.** The background server writes the runtime config to
`<support>/Bots/runtime.json` with `dataDir` `<support>/Bots/data`,
`engine.kind` `mac-vm`, `image.tag` `wovenmatter-bots` and `limits.botMemoryBytes`
from the machine's per-bot RAM, and runs the runtime with the Node the app ships
(`<Resources>/default-agent/bin/node <Resources>/bots/src/cli.ts`). It serves the host
API on its own loopback port. Previews are published from the runtime's loopback
proxy port with Tailscale Serve, path `/`, on their own HTTPS port. Inference
credentials are the coordinator snapshot Pi Durable gets; `claude-subscription`
returns the default agent's native directories (`~/.wovenmatter/default-agent/claude-runtime`
and `claude-keychain`) once they exist. `DELETE /v1/bots-host/mcp-keys/{botID}` also
marks that bot's library conversations deleted.

**Bot conversations in the library** are two paired-library tables, not chats:
`bot_conversations(id = "<machine>:<bot>:<conversationId>", machine_id, bot_id,
bot_name, conversation_id, kind, parent_conversation_id, forked_at, title, pinned,
created_at, updated_at, deleted_at)` and `bot_conversation_entries(id =
"<machine>:<bot>:<entryId>", conversation, entry_id, role, text, error, stopped,
created_at)`. A resent row that has not changed is not rewritten, so it adds no sync
traffic. Regular chat lists never show them. The Swift entry point is
`WorkspaceDatabase.recordBotConversation(machineID:_:)`, which a Linux library daemon
can call with the same batch.

**Woven server routes for bots.** Every Woven server that hosts bots answers these,
under `/wovenmatter` when reached through Tailscale Serve:

| Route | Reply |
| --- | --- |
| `GET /v1/bots/status` | `{ machine: { deviceID, name, kind }, enabled, state, message?, versions: { app, runtime, protocol, fingerprint?, librarySchema? }, resources, capacity: { memoryBytes, diskTotalBytes, diskFreeBytes, diskUsedByBotsBytes? }, paused, updating?, engineUpdateFailure? }` (`updating` and `engineUpdateFailure`: a Mac's VM update) |
| `POST /v1/bots/engine/update` (Macs) | starts the Mac's VM update and returns the status at once; follow `updating`, then `engineUpdateFailure` |
| `POST /v1/bots/resources` `{ resources: { poolBytes, perBotBytes, diskBytes } }` | the status after applying; `null` is no cap (Linux also leaves a missing field as it is) |
| `POST /v1/bots/enabled` `{ enabled }` | turns bots on or off on this machine and returns the status. Bots run on one machine: choosing one in Settings → Bots turns them off everywhere else. Bots, their files and conversations stay. A Linux host saves `botsOff` with its bots settings and refuses `enabled: true` until bots are installed |
| `GET /v1/bots/ws` (WebSocket upgrade) | proxied to the runtime's `/ws` with the runtime's own bearer |

A Mac reaches every other member's bots with signed requests
(`ApplicationModel.botsClient(for:)`, a `MemberSignedHTTPClient` addressed to the
workspace's `executionDeviceID`): every Mac and Linux workspace in the synced
registry, whichever Mac added it, at `<endpoint>/v1/bots/*` (a Linux host's execution
endpoint `…/wovenmatter-execution/<id>/`, a Mac's `…/wovenmatter`). The status reply
must name that device. The socket is `BotSocketEndpoint.signed(url, audience:)`: the
window asks the process that holds the member key for fresh upgrade headers before
every connection attempt (`BotsCommand.signSocket(url:audience:)`, which signs only a
member's `…/v1/bots/ws` on a `.ts.net` address), and `PiBotClient(authorize:)` sends
them instead of a bearer. A Linux host this Mac added that is not in the registry (a
bots-only server) is still reached through its SSH tunnel with the installer's
bearer. A Mac's server accepts only signed members on `/v1/bots/*`.

**Linux bots-only install.** The Mac runs `remote-host.sh prepare AUTHORIZED
<access-mode> bots`, then `remote-host.sh install <workspace-id> <port> <access-mode>
<fingerprint> bots` with the same stdin as any install (token line, then bundle); see
"One server, roles". Both use the SSH account's existing noninteractive sudo. The
Mac records a bots-only host with workspace id `bots`. Adding the workspace later
keeps that record (its id, token, port and access level) and runs `remote-host.sh
install <real-id> … workspace` (`RemoteHostInstallMode.addWorkspace`): the script lets
the first workspace install take over a bots-only `bots` record once, on the same
server and data root with bots kept, and records `previousIDs: ["bots"]` so uninstall
also removes routes published under the old id. Any other id change is still
`host_workspace_conflict`.

**Mac engine.** The bots host codes against `BotEngineHost`
(`app/App/Services/BotEngineHost.swift`): `ensureRunning(resources:)` returns the
Docker socket once the VM answers, `apply(resources:)`, `diskUsedByBots()`, `status()`,
`update()` (the VM's update; returns when it is ready again, throws if it was rolled
back), `stop()` and `onStatusChange` (download, first-boot and update progress, and
failures with their reason). Previews need no VM port forward: the runtime carries them
over Engine API exec streams. `BotEngineHostFactory.make(<support directory>)` returns
`WovenVMBotEngineHost` over `WovenVMController.forApp(supportDirectory:)`: the RAM pool
is the VM's memory and the disk cap its disk cap (at least 1 GB and 10 GB; no cap stays no
cap), and per-bot RAM stays in the runtime config. Where the VM cannot run (Intel, or no
helper) it returns an engine that says why. "Update everything" updates each Mac's VM
before its bots (`BotUpdatePlan.Step.engine`, `BotsCommand.updateEngine`).

## Out of scope

- TestFlight preparation (its own PR).
- The `wovenmatter/pi-bot` repository and its workstation preview, which stay
  untouched.
- Outside-agent MCP on Linux or the iPhone.
