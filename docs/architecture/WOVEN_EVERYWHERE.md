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
  desktop app installed by hand and be connected on the Mac connections page
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
  (`companion_library_identity.host_device_id`, the sync clock's origin). On
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
    `memberPublicKey` (raw 32 bytes) in `CompanionPairRequest` gets an `ios`
    entry from the Mac it pairs with, signed when the phone confirms the
    pairing (`POST /v1/pair/confirm`), before its grant is issued; a pairing
    that is never confirmed adds no member. `POST /v1/pair` first checks that
    the Mac can add that key (`MemberDirectory.checkAdd`) and otherwise answers
    409 with the reason (`member_key_changed`) before the code is spent; it
    also returns `CompanionPairResponse.libraryIDs` (the libraries in its
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
    Mac's ID from `CompanionPairResponse.hostDeviceID`. `GET /v1/identity`
    is used only by the Mac that is about to sign that host's entry. A
    workspace or host without a known device ID is not signed for
    (`member_audience_unknown`); the caller treats it as not reachable yet.
  - The shared test vectors in
    `shared/Tests/WovenMatterCompanionTests/MemberSignatureVectors.json`
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
  `CompanionHostController.authenticateMember`). On a Mac, signed requests are
  accepted on peer sync (`mac`, `linux`), the mobile API and `/mcp` (`ios`,
  `mac`), `/v1/execution/*` (`mac`, `ios`, `linux`; no execution grant
  needed), `/mcp/workspace` and `/mcp/workspace/prepare` (`linux`, in place
  of the single-Mac library grant; see "Sessions across devices") and
  `/v1/bots/*` (`mac`, `ios`; signed only, no grant). The inference host
  takes signed `ios` and `mac` members too ("iPhone reach"). Grants for
  phones paired before members keep working on the mobile, execution and
  inference routes.
- Swift clients sign with `MemberSignedHTTPClient(endpoint:signer:audience:)`
  (`app/Sources/WovenMatterClient`): the target is the exact path sent, so a
  Mac endpoint (`https://<mac>.<tailnet>.ts.net:<port>/wovenmatter`, no
  trailing slash) signs `/wovenmatter/…` and a Linux execution endpoint
  (`…/wovenmatter-execution/<id>/`) signs its full path. The Mac app's
  `SignedExecutionWorkspaceTransport` replaces execution grants for every
  other Mac and Linux workspace with a known `executionDeviceID`; a signed
  refusal is final ("does not recognize this Mac yet" until the member lists
  synchronize), with no saved-grant fallback, and nothing is provisioned
  (`/v1/peers/credential` no longer requires the workspace's owner Mac). A
  workspace without an `executionDeviceID` still uses a saved grant. A phone grant for a Linux workspace is issued by that host
  (signed `POST /v1/execution/devices`) from any Mac.
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
  Linux host in the synced registry (Settings > Remote workspaces, "More
  Linux hosts") and manages it with these signed routes
  (`RemoteHostAdministrationClient`): status, logs, restart, bots-configure
  and update, which uploads this Mac's host bundle and polls `GET
  /v1/host/update`. Nothing says which Mac added a host. "Update everything"
  (`BotUpdatePlan.Step.linuxHost`) updates every Linux host in the registry
  this way (`RemoteWorkspacesModel.runSharedHost(_:.update)`); SSH is only
  the fallback for a host this Mac added. A Linux host's sessions use any
  Mac's `/mcp/workspace` once the session's `companion_execution_conversations`
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
    to it at once; the reply is `{rotated: true}`, plus `bearer` only for the
    installer on its own tunnel. A Mac that removes another Mac queues a
    rotation (durably, retried with pending revocations,
    `companion.execution.pending-installer-rotations`) on every Linux host in
    the registry whose `ownerDeviceID` is the removed Mac. Publisher and MCP
    grants at rest are keyed by `WOVENMATTER_SERVICE_SECRET`, the first
    install's bearer, which installs and rotations keep, so rotation never
    orphans them.
  - Outside-client and session MCP bearers (`/mcp`, agent tool sessions),
    bot MCP keys (bots are not members), the runtime host API
    (`/v1/bots-host/*`) and runtime token, and the library socket's local
    bearer: none of these is a call between members.
  - Grants for phones paired before members: the Mac's mobile API pairing
    credential and execution and inference grants
    (`CompanionExecutionAuthentication`), Linux device grants
    (`POST /v1/execution/devices`, issued from any Mac), and the phone's
    saved grants for workspaces too old for signatures.
  - The Linux host's single-Mac library MCP grant and publisher grant, issued
    by the Mac that added it: only a fallback for a host without a library
    host or with no Mac member answering.
  - A Mac's saved execution grant for a workspace with no `executionDeviceID`
    (a library client's secondary execution workspace).

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
    `CompanionWorkspaceAPI` and `CompanionFederationAPI`), so a phone can sync
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
    `after`; repeated until neither has more), `POST /v1/peers/notify
    {deviceID, cursor}` (the receiver pulls when `cursor` is past what it has),
    `POST /v1/peers/files` and `POST /v1/peers/file` (content-addressed files,
    as before). A device sends only to advertised endpoints that are tailnet
    HTTPS (`LibraryPeerSync.isTailnetEndpoint`: `https://<name>.ts.net`, no
    credentials, query or fragment), as Node and the phone do.
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
    A Linux host (any sender but a Mac) writes `companion_execution_workspaces`
    only for the workspace it serves itself (`MemberAudience.serving`, before
    and after the change), `companion_execution_conversations` only for that
    workspace's sessions, owner rows (`paired_*_owners`,
    `companion_calendar_owners`, `companion_calendar_run_owners`) only naming
    itself, and never `paired_mac_routes` or `paired_remote_workspaces`. Other
    such rows it relays are skipped; they arrive from a Mac directly.
  - HTTP deadlines (both the Mac listener and `CompanionSocketHTTPServer`,
    `CompanionHTTPParser.Deadlines`): the request head within 15 s; then the
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
  rejects a mismatch). When peers disagree, every device shows which part
  needs updating and offers "Update everything". There is no compatibility
  layer. A mismatched exchange answers 409 `{code: "update_required",
  message, version, schema}`; `LibrarySyncStatus` (`{deviceID, version,
  schema, peers: [{deviceID, name, kind, state: online|offline|updateRequired|failing,
  version, lastSynchronized, lastContact, error}], conflicts, quarantined}`,
  `updateRequired`) is on the Mac's `CompanionHostSnapshot.librarySync`, the
  library socket's `GET /v1/sync/status` and, for phones, the mobile API's
  signed `GET /v1/sync/status` on every Mac and Linux host. On a Mac, a peer
  in `updateRequired` raises the same "Versions don't match" / "Update
  everything" notice as a bots version mismatch (`ApplicationModel+Bots.swift`).

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
- `GET /v1/workspaces` → `{workspaces: [CompanionExecutionWorkspace]}`: the
  synced execution workspace registry (every Mac, Linux and iPhone
  workspace this library knows, deleted ones left out), which the server
  routes cross-workspace sessions with.
- `GET /v1/sync/status` → `LibrarySyncStatus`.
- `POST /v1/timers/due` (`{}`) → `{occurrences: [{timerID, deliveryID, target,
  kind: "session"|"bot", botID?, text}], nextFireAt?}` and `POST
  /v1/timers/settle {timerID, deliveryID, outcome: "accepted"|"retry"|"cancelled",
  reason?}` (`LibraryHostTimers`); see "Timers on a library host".
- `POST /v1/publisher/{journal,retained/settle,association,artifacts/register,artifacts/chunk,artifacts/commit}`:
  the bodies and replies of a Mac's `/v1/federation/publisher/*`, written into
  this library copy. The workspace is the one the entries (or the artifact
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
with every Mac offline and no single-Mac library grant. History the caller may
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
(`companion_scheduled_mcp_callers`, written by `/mcp/workspace/prepare`) is not
synced, so another Mac refuses the task's calls until the session's own row
reaches it. The Node delegate therefore sends a task's calls to the Mac that
last prepared it first, and prepares any other Mac (the same idempotent
request) before asking it, so prepare and call always land on the same Mac. Bots
never use this route or the legacy grant (a Mac's `/mcp/workspace` binds every
call to a conversation), so a Linux bot has no Mac-only tools. Its notes,
calendar, history, library and timers come from this host's library copy, and
its session tools run on this server. The single-Mac grant
(`/v1/execution/mcp-library`, `mcp_library_connection`) is no longer
required for anything; it stays as a fallback when no Mac member answers and
for hosts without a library host. Session history is published to the local
publisher routes (the Mac grant is only a fallback without a library host),
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
otherwise; a release with a plain binary is used as is). Starting and
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
  saved defaults apply), a `workspace` rename to the title (kept by the
  first message), and `send`. `deviceID` is the caller's member device ID,
  and `libraryID`/`workspaceID` are the destination's. Command IDs derive
  from the caller, request ID and destination, so a retry replays receipts.
  The reply is `{session: {id, title, harness, workspace, workspaceName,
  workspaceKind}, independent: true, receipt}`: the caller does not
  coordinate it. Linux: `remote/src/member-sessions.mjs`; Mac:
  `ApplicationModel+MemberSessions.swift`.
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
  session on that Mac or on a Linux host it manages over SSH stays local. Each is one or more signed calls to the destination's
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
  sessions the caller created or coordinates. There are no notifications back
  to the caller; it polls `woven_sessions_status`.
- **Bots** get `woven_sessions_create`, `_send`, `_status`, `_list`, `_stop`,
  `_respond` and `_harnesses` from the Node server itself (no Mac): a bot's
  sessions on its own machine's workspace go through that workspace's own
  execution commands, as another member's would; coordination tools
  (`manage`, `release`, `notifications`, `receipts`) bind a conversation and
  stay unavailable to bots. A Mac's bots, which are app-wide callers there,
  get the same tools from the Mac; `woven_sessions_list` without `workspace`
  lists a bot's sessions on other workspaces.
- The iPhone connects directly to every Mac and Linux workspace with its own
  member key. It has no home Mac.

### iPhone reach

- **Identity.** On first pairing the phone creates a Curve25519 signing key
  in its Keychain (`MobileMemberKeyVault`, service
  `com.wovenmatter.companion.member`, this device only), bound to its library
  device ID, and sends it as `CompanionPairRequest.memberPublicKey`. A re-pair
  presents the same key. The Mac adds the phone when the pairing is
  confirmed, so the phone probes it (a signed `GET /v1/hello`) only after
  confirming: a signed 401 then means the Mac did not add it (`rejected`,
  never taken as acceptance), and the phone keeps its grant and shows "Pair
  again" (`MobileMembershipState.memberRejected`). A backup restored onto
  another device brings `membership.json` but not the this-device-only key;
  finding the key missing, the phone marks that membership refused instead of
  signing with a key no Mac knows, and pairing again replaces the key on the
  Mac. Whether to keep the replica (same library set) comes from
  `CompanionPairResponse.libraryIDs`, before any signed request works.
- **Signed requests.** `HTTPSCompanionTransport(host:identity:)` and
  `HTTPSExecutionWorkspaceTransport(workspace:identity:)` sign every request
  (`MobileRequestSigning`: the target is the percent-encoded path and query as
  sent, `/wovenmatter` included) and send no bearer. A signed 401 means "this
  host does not know this phone yet" (`memberUnknown`, skipped like an offline
  host); a host that answers that it does not accept member requests
  (`memberUnsupported`) keeps the phone on its bearer grant and shows "Update
  everything"; 409 `update_required` becomes `updateRequired`.
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
  answers that create with `notFound` and `CompanionMutationResult.deleted`,
  and an unchanged phone copy is then deleted instead of becoming a conflict;
  calendar edits are rebased on the next
  snapshot the same way; the journal keeps all history, resets its cursor and
  offers this phone's own records again (the host keeps those it has);
  dictation and artifact cursors restart. The phone's device workspace is
  re-registered in the new host's library at that host's revision.
- **Sessions.** "Central" means the library host the phone is syncing with;
  its own sessions use the mobile API, and every other workspace with an
  endpoint (each Mac's own and each Linux workspace) gets a signed direct
  client, with no execution grant. A workspace too old for signatures keeps
  its bearer grant.
- **Inference.** A Mac's inference host (`/v1/inference/catalog`,
  `/v1/inference/stream`, `CompanionInferenceHost`) accepts signed `ios` and
  `mac` members: the principal is the member's device ID, a named
  `X-Woven-Workspace` / `X-Woven-Library` / `X-Woven-Device` must match it and
  this Mac, and removal is checked before credentials are prepared and again
  before a stream starts. In member mode the phone saves hosted connections
  with `InferenceHostScope.hostDeviceID` (the workspace's `executionDeviceID`)
  and no credential, and `CompanionInferenceService` signs them through
  `InferenceMemberSigning` (installed with the phone's member key); a
  connection without `hostDeviceID` keeps presenting its grant.
- **Migration.** Existing phone data stays. A phone paired before members
  shows "Pair again once with any Mac"; pairing with a Mac of the same
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
  toggles decide which tool groups bots get. Session management reaches only
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
| `DELETE /v1/bots-host/mcp-keys/{botID}` | none | 2xx. Sent when the user purges a bot. |
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
  `bridge-nf-call-iptables`, so the private-range rejects stop that too. Containers have no `CAP_NET_ADMIN` in the guest namespace and
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
    stayed there idle. After: fresh boot 1.3 GB; the first image build (3.3
    minutes, capped at 3 GiB until a stall opened it) 5.3 GB; idle restart
    10 minutes later back to 1.3 GB, capped at 2.6 GiB; one bot through the
    real-engine test 3.5 GB (its snapshot commit re-read evicted cache and
    opened the balloon).
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
`GET /v1/status`; `PUT /v1/resources`; (optional forwards) `GET /v1/forwards`;
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
- **Network.** Bridge `br-wovenbots` on a free private /16 (first of
  `10.237–251.0.0/16`). dockerd runs with `iptables`/`ip6tables`/`ip-forward`
  off and never touches the user's chains. The Woven nftables table `inet
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
  Administrator only: `POST /v1/bots/resources {resources: {poolBytes?,
  perBotBytes?, diskBytes?}}` (a missing field stays; a pool below per-bot
  RAM lowers it), `GET|POST /v1/bots/mcp {isEnabled?, groups?}` (the `GET`
  adds `revoked: [{botID, revokedAt}]`), `DELETE /v1/bots/mcp/keys/{botID}`
  and `POST /v1/bots/mcp/keys/{botID}/reinstate`. That DELETE is the user's
  revoke and sticks, as on a Mac (`WovenMCPHost`): the bot is recorded in
  `mcp_bot_revocations`, and the runtime's `POST /v1/bots-host/mcp-keys`
  for it answers `403 {error: "revoked"}` until reinstated. The runtime's
  own `DELETE /v1/bots-host/mcp-keys/{botID}` (a bot it deleted) only drops
  the key. `GET /v1/bots/status` and the
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

- **Discover devices**, on the Bots page and on Mac connections, lists every
  online Linux and macOS tailnet peer and its state:
  - a Linux machine with no server: install bots (sudo once);
  - a Mac without the app: "Install Woven Matter on this Mac first", with the
    steps (download, open, connect on Mac connections, finish the setup card);
  - ready.
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
