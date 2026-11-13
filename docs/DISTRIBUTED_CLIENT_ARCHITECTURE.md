# Paired libraries and execution workspaces

This is the storage, execution and synchronization contract for Woven Matter.

## Equal members

Each paired Mac owns a complete local SQLite library, runs the normal desktop
app, and accepts local edits while disconnected. Each Linux host keeps the same
complete library through the `wovenmatter-library` executable. Macs and Linux
hosts exchange changes peer-to-peer in both directions over tailnet HTTPS.
There is no designated central database, promotion, handoff, or replacement
authority. The Mac used to pair two other devices does not need to remain
online for them to synchronize with each other.

A Mac can add Linux hosts and pair other Macs and iPhones. Every device has a
long-lived signing key, and the member list is a signed record set that syncs
to every device (see [Woven everywhere](architecture/WOVEN_EVERYWHERE.md),
"Membership and device keys" and "Trust model"). Each new device needs explicit
approval on a Mac; discovery does not grant access. Library sync and execution
requests between members are signed with the caller's device key, and no
bearer is issued for them. Bearers remain only for the pairing handshake
(`join/prepare`, `join`), `/v1/peers/usage`, `/v1/peers/credential`, phones
paired before member keys existed, and the installing Mac's administrative
link to a Linux host. Removing a device is a signed revocation that each device
applies as soon as it syncs; it stays effective across stale membership replay,
concurrent removals and re-pairing.

## Shared storage and local execution

The shared library includes notes and versions, folders and workspace bindings,
conversations and complete exposed execution history, saved library files,
artifacts, dictation history, library settings, workspace inventory and paired
device membership. Each Mac retains those downloaded bytes locally. Large row
values and file bytes transfer separately with content digests and resumable
chunks; interrupted large values do not block independent writing.

A conversation and run still have one execution workspace. Native runtime
checkpoints, command queues, receipts, timers and active delivery state stay on
that workspace. Replaying shared observations cannot execute a command, resume a
foreign agent, manufacture a second native history event, or run another Mac's
schedule. Workspace roots, repositories, dependencies, caches and ordinary working
files follow [the workspace data model](WORKSPACE_DATA_MODEL.md), outside library
synchronization.

Workspace provider credentials stay with their installation. Macs and Linux
hosts reach every other Mac and Linux workspace with signed member requests
(see [Woven everywhere](architecture/WOVEN_EVERYWHERE.md), "Membership and
device keys"): nothing is issued or enrolled, so any Mac uses, and manages, a
Linux host whichever Mac added it, and a Linux host creates sessions on
another Linux host with every Mac offline. The Mac that added a Linux host
keeps its SSH link only for first install and as an update fallback. Phones
that still pair with a bearer receive their own scoped direct-execution
credential, which any Mac can request from a Linux host. Owning execution
does not confer library authority.

## Live sessions on other machines

A session's history moves only by library sync: a Mac's sessions are in its
library natively, and a Linux host writes its sessions into its own library
copy, which synchronizes with every Mac and phone. The live view of a session
on another machine (its transcript as it is written, run state, questions and
approvals, capabilities and session settings) and the commands sent to it move
on that machine's stream, `GET /v1/stream?protocol=1`, a member-signed
WebSocket (see [Woven everywhere](architecture/WOVEN_EVERYWHERE.md),
"Streaming"). On a Mac the background server holds the one stream to each
other machine and relays it to its windows over their connection to it;
other Macs' and Linux hosts' sessions render in the normal conversation view.
Nothing polls an execution workspace. When a machine is unreachable its
sessions show the history the library holds, with an offline notice, and the
stream reconnects by itself. There is no SSH agent path: SSH installs,
updates and repairs a Linux host only.

## Offline changes and reconnection

A SQLite trigger records each shared edit in the same transaction as the content.
Replica identity is a persistent device UUID. Record identities remain stable
across reconnects, and network addresses are separate routing information.
Causal vectors distinguish subsequent edits from concurrent edits. Concurrent
changes converge deterministically; conflicting values remain recoverable.
Concurrent deletion wins over an edit to the same identity, while the live
writing gets a deterministic recovered copy. A later explicit restore can be a
new causal edit. Tombstones and pending large records survive restart.

Each identity keeps its causal frontier, so every Mac chooses the same winner
regardless of arrival order. Receive cursors commit with durable acceptance,
including a durable pending record for a value whose bytes are still downloading. Push acknowledgement covers
only the exact submitted page. Retries cannot duplicate commands or recovered
notes. Changes are relayed with their original identity and causal context, so
connected peers converge without choosing a central Mac. Background retries are
bounded and ordinary disconnection is quiet.

Settings → Apple Devices presents this Mac, pairing and the devices paired with
this Mac; Settings → Workspaces holds the workspace inventory. It has no database-role selector. Notes with concurrent
writing have visible **Recovered edit** copies. Existing pre-upgrade writing and
original databases are preserved; see [upgrade and recovery](PAIRED_MAC_LIBRARIES.md#upgrade-and-recovery).

iPhones (beta) are signed members too. A phone keeps its offline replica and
syncs with whichever Mac or Linux host answers first: the last host that
worked, then the Mac it paired with, other Macs, then Linux hosts. The Mac it
paired with is only a starting point and is never required. The phone reaches
each Mac and Linux workspace directly with signed requests (see
[Woven everywhere](architecture/WOVEN_EVERYWHERE.md), "iPhone reach"). Quick
Chat's provider sign-ins remain device-only.

## Quick Chat on iPhone and iPad (beta)

The iPhone app is a TestFlight beta. Its Quick Chat runs Pi Durable on the
device; the SDK owns the agent loop, submissions, tools, checkpoints and
recovery. Inference is exclusively through supported cloud connections or an
inference service on another Tailscale device. On-device inference is outside
scope.

The reviewed SDK is bundled with the app and hosted through JavaScriptCore.
Native bridges provide durable storage, network streams, credentials,
cancellation and the phone's tools: notes, web search and read, questions to the
user, timers and reminders, and calendar. There is no shell, file tools,
Python, code mode, subagents, goals, browser or computer automation. Quick Chat
rejects any target other than the phone; work on a Mac or Linux workspace is a
session on that workspace. See [Quick Chat lifecycle](IOS_CONTINUED_EXECUTION.md).

Provider connections are independent of Apple-device pairing. ChatGPT and Grok use native device-code sign-in; Claude uses native PKCE sign-in with the provider’s returned code. API-key connections, including OpenCode Zen and Go, save their keys on the device. Access and refresh tokens stay in the device-only Keychain, and refresh calls the provider directly. Native Claude requests identify Woven Matter and retain Pi’s actual prompt and tool names; they do not claim to be Claude Code. Real provider authorization and inference acceptance require user testing. An explicitly selected hosted connection can still use an authenticated inference-only adapter. That adapter may translate model requests but cannot execute the phone's tools or own its agent loop. The selected adapter's availability is a model-connection dependency, separate from library synchronization.

Accepted work and tool intent are persisted before display/dispatch. Quick Chat
runs only in the foreground: when the app backgrounds, a short allowance saves
and interrupts an in-flight response, and resuming is explicit. Interruption
recovery uses native checkpoints and tool receipts. User cancellation remains
cancellation after restart. Ambiguous external effects are reconciled or
surfaced rather than blindly replayed. Other devices see Quick Chats as
read-only synced history.

## Compatibility and acceptance

Every desktop Mac runs its full local app and background server. Both Macs must
advertise `library.peers.v2` before a new Mac pairing completes. Existing mobile
pairing and execution protocol identifiers remain compatible; a workspace keeps
its original library namespace and execution scope when its inventory is shared.

Acceptance covers independent offline edits, three-Mac synchronization with the
joining Mac unavailable, conflict recovery, deletion races, restart/replay,
resumable file integrity, local-only execution queues, propagated revocation, and
new remote-workspace/device membership added on any Mac. Real-device testing is
the final acceptance step; fixture results do not claim live Tailscale or provider
acceptance. See [the paired Mac test plan](PAIRED_MAC_LIBRARIES.md#review-and-device-test-plan).

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

OpenRouter catalog entries that declare the dynamic-router unavailable-price sentinel are omitted; their prices are never replaced with zero. Normal chat entries remain available, and destination/header validation still runs before exclusion.
