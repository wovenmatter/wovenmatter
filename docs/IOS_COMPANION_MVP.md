# Native iOS companion

The iPhone uses the running Mac's canonical workspace. Provider execution,
credentials, SSH routes and concurrency remain on the Mac. PR #37 is integrated
with monorepo main `2033ae6850b094d9902a64a9b1ae48a1b4052ffd`.

## Implemented behavior

- Native Home, Folders, Content, Chat and Note tabs share the desktop's forest-green
  theme. Rich text edits preserve document/block identities, styling and tables.
  Unsupported attributes and future formats remain intact and read only.
- Ordinary notes and flat folders work offline. A protected local store commits
  immutable content blobs before replacing its durable index/outbox. Saved state
  is shown after persistence. Dirty writing is never evicted to meet a cache budget.
- Sync uses stable client IDs, integer revisions, conditional mutations, tombstones,
  replay cursors and immutable receipts. Conflicts retain base, iPhone and Mac
  writing; recovery creates a separate identity instead of resurrecting a deletion.
- Desktop autosave, mobile mutations and agent edits share the same revision rules.
  Desktop journal recovery retains unresolved writing and exact committed versions.
- Online chat uses the Mac's canonical provider/session service. All eight local
  and remote runtime selections, linked workspaces and configured OpenClaw Gateways
  use the current desktop routing and readiness checks. OpenCode uses its native
  server and Hermes uses its native Gateway; neither is simulated as an ACP agent. A note-bound send
  flushes and pins its exact canonical content/revision. The phone owns no providers.
- Creation and first send are separate durable commands. Lost acknowledgements
  recover by receipt; reconnect never automatically submits an unsent command.
  Stop/steer/answers carry stable conversation, run and interaction IDs. The first
  valid response wins across clients. Phone disconnect never cancels accepted runs.
  OpenCode acknowledges submission before its canonical run may be available, so
  the command receipt can omit a run ID until transcript synchronization supplies it.
  Native OpenCode does not expose steering; its pending approvals are available on
  the phone. Its richer forms, and Hermes secret entry, direct the user to the Mac;
  secret values are not accepted into the phone command journal.
- Recent transcript bodies are cached within 20 conversations/16 MiB. Clean note
  bodies use a 64 MiB budget; metadata remains discoverable and online opens fetch
  full bodies. Linked spreadsheet and HTML previews use the same registered data
  reader as the Mac, with explicit unavailable states and no preview writes.

## Components

`shared/` contains the Foundation-only document model and versioned wire contracts.
`WovenMatterDashboardStore` adds revisions, change journal, receipts, authentication,
HTTP transport and process supervision to the existing workspace SQLite store.
`app/App/Services` owns host lifecycle and canonical command routing. `ios/` contains
native SwiftUI/UIKit views, the portable mobile client/store and generated Xcode
project. `integration/` crosses those real client/server/store boundaries using fake
provider execution and controlled network failures.

## Pairing and transport

Settings → iPhone companion starts an IPv4 loopback listener and a dedicated
foreground Tailscale Serve HTTPS route at `/wovenmatter`. Unrelated routes are
preserved. The selected HTTPS port is retained for the workspace. Quit/crash ends
only the companion's owned Serve process; restart drains prior owned processes
before reusing the port. Sharing prevents idle sleep, but the Mac must remain
powered on, awake and running. Closing its window keeps access available.

The QR/deep link is `wovenmatter://pair?endpoint=...&token=...&version=2`. Its random
256-bit token expires after five minutes and is consumed once. One iPhone may be
paired; revoke it before replacing it. Only token hashes are persisted on the Mac;
the phone credential is stored in Keychain. Requests require matching protocol and
workspace headers as well as the credential. The client rejects redirects and the
server rejects browser origins, cookies, ambiguous framing and oversized requests.

Protocol 2 supports native pending interactions before the Mac has projected a
canonical run ID. Version-1 clients receive a version-mismatch response before
sync or command dispatch, so update both apps together. The existing credential
and local-note storage formats are unchanged; upgrading does not require clearing
the phone's writing or revoking its pairing. Route paths remain `/v1`; the protocol
header and pairing payload negotiate this wire-format version.

Routes are relative to the paired HTTPS endpoint:

- `POST /v1/pair`
- `GET /v1/hello`, `/v1/snapshot`, `/v1/changes?after=...&limit=...&wait=...`
- `POST /v1/mutations`, `/v1/commands`
- `GET /v1/command-receipts/{id}`, `/v1/providers`, `/v1/pending`
- `GET /v1/sessions/{id}/transcript?before=...`, `/v1/sessions/{id}/capabilities`
- `GET /v1/notes/{id}`, `/v1/assets/{id}`
- `GET /v1/assets/{id}/linked-data?tableID=...`

Linked preview requests accept a canonical document/table ID, not arbitrary paths
or queries. The stored link resolves through the Mac's confined database catalog.
SQLite previews limit execution time/instructions, cell size and total result size;
only one linked read per serving instance runs at once. HTML uses a nonpersistent,
network-isolated WebKit view and the desktop `window.wovenMatterData` contract.

## Validation and private test builds

Run `scripts/test-changes.sh --all` for cross-component validation, including the
native simulator app and fixture tests. CI companion changes run unsigned simulator
model tests and package/integration checks. Tests use isolated stores/simulators and
fake provider adapters; they must not consume provider services.

Coverage includes offline capture/restart, exact rich-body UIKit restart, unknown
formats and size bounds, simultaneous desktop/mobile editing, deletion/conflict
recovery, lost acknowledgements in both new-chat phases, concurrent receipt recovery,
first-valid interaction responses, captured navigation/drafts, workspace/version
rejection, revocation, real HTTP disconnect, and real helper parent-death cleanup.
The facade tests compile the real ApplicationModel and exercise local/remote provider
routing, session-default application, tool policy, atomic folder placement, immutable
note bindings and bounded history reads. Native OpenCode transport has separate
coordinator tests; it is not exercised through a fake ACP route.
They do not claim live provider execution or human acceptance.

`scripts/build-companion-desktop.sh run` builds an Apple Development-signed,
separately identified **Woven Matter Companion Test.app**. Both script launch and
opening that app directly use `~/Library/Application Support/Woven Matter Companion
Test`, so notes and pairing survive reopening. Shared production and Dev workspace
paths are rejected. `WOVENMATTER_COMPANION_TEST_WORKSPACE` is an explicit alternate test path;
launch with that same argument when intentionally overriding the default.

`scripts/build-ios.sh` creates an unsigned simulator build.
`WOVENMATTER_IOS_DEVICE_ID=<registered-device-id> scripts/build-ios.sh --device`
uses the configured Apple team for a development build. The iPhone bundle identifier
is `com.wovenmatter.companion.dev`; installing an updated build preserves its data
and Keychain pairing. See `ios/README.md` for the device test workflow.

These are private development test builds. PR review, merging, production release,
App Store distribution and human acceptance remain separate. APNs, hosted accounts,
multi-Mac authority, voice and mobile provider execution are outside this MVP.
