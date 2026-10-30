# Paired libraries and execution workspaces

This is the storage, execution and synchronization contract for Woven Matter.

## Equal Macs

Each paired Mac owns a complete local SQLite library, runs the normal desktop
app, and accepts local edits while disconnected. Paired Macs exchange changes in
both directions over Tailscale. There is no designated central database, promotion,
handoff, or replacement authority. The Mac used to pair two other Macs does not
need to remain online for those Macs to synchronize with each other.

A Mac can add remote workspaces and pair additional Apple devices. Workspace
identities and connection membership propagate through the paired graph. Each
new connection requires the existing explicit approval. Discovery does not grant
access. A learned Mac address must prove possession of an existing device
verifier before it receives a bearer credential. Revocation propagates when peers
reconnect and remains effective across stale membership replay and re-pairing.

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
synchronization. A local upgrade can import a former node's native database on
the same physical Mac; that path is never available over the network.

Workspace administrator and provider credentials stay with their installation.
Every requesting device receives its own scoped direct-execution credential.
Once enrolled, it can use a reachable workspace independently of the Mac that
added it. Initial enrollment of a newly added remote workspace still needs the
Mac holding that workspace's management credential to be reachable. Owning that
execution capability does not confer library authority.

## Offline changes and reconnection

A SQLite trigger records each shared edit in the same transaction as the content.
Replica identity is a persistent device UUID. Record identities remain stable
across reconnects, and network addresses are separate routing information.
Causal vectors distinguish subsequent edits from concurrent edits. Concurrent
changes converge deterministically; conflicting values remain recoverable.
Concurrent deletion wins over an edit to the same identity, while the live
writing gets a deterministic recovered copy. A later explicit restore can be a
new causal edit. Tombstones and pending large records survive restart.

Receive cursors commit with durable acceptance, including a durable pending
record for a value whose bytes are still downloading. Push acknowledgement covers
only the exact submitted page. Retries cannot duplicate commands or recovered
notes. Changes are relayed with their original identity and causal context, so
connected peers converge without choosing a central Mac. Background retries are
bounded and ordinary disconnection is quiet.

Settings → Apple Devices presents this Mac, pairing, a shared device roster and
one workspace inventory. It has no database-role selector. Notes with concurrent
writing have visible **Recovered edit** copies. Existing pre-upgrade writing and
original databases are preserved; see [upgrade and recovery](PAIRED_MAC_LIBRARIES.md#upgrade-and-recovery).

Mobile devices retain their existing offline replicas and connect to an approved
Mac for library synchronization. Their authenticated workspace registry can contain
execution workspaces from other paired Macs, retaining each workspace's actual
credential namespace. Native device inference sign-ins remain device-only.

## Pi Durable on iOS and iPadOS

Pi Durable executes on the iOS device. Its SDK owns the agent loop, submissions, tools, checkpoints and recovery. Inference is exclusively through supported cloud connections or an inference service on another Tailscale device. On-device inference is outside scope for all versions.

The reviewed SDK is bundled with the app and hosted through JavaScriptCore. Native bridges provide durable storage, network streams, credentials, cancellation and mobile tools. The mobile workspace exposes only supported local capabilities. Mac/Linux workspace operations require an explicit target; a suspended local run is never silently moved elsewhere.

Provider connections are independent of Apple-device pairing. ChatGPT and Grok use native device-code sign-in; Claude uses native PKCE sign-in with the provider’s returned code. API-key connections, including OpenCode Zen and Go, save their keys on the device. Access and refresh tokens stay in the device-only Keychain, and refresh calls the provider directly. Native Claude requests identify Woven Matter and retain Pi’s actual prompt and tool names; they do not claim to be Claude Code. Real provider authorization and inference acceptance require user testing. An explicitly selected hosted connection can still use an authenticated inference-only adapter. That adapter may translate model requests but cannot execute the phone's tools or own its agent loop. The selected adapter's availability is a model-connection dependency, separate from library synchronization.

Accepted work and tool intent are persisted before display/dispatch. iOS background execution is opportunistic: interruption recovery uses native checkpoints and tool receipts. User cancellation remains cancellation after restart. Ambiguous external effects are reconciled or surfaced rather than blindly replayed.

## Compatibility and acceptance

Every desktop Mac runs its full local app and background server. Former node
preferences are upgrade input, rather than a role selector. Both Macs must
advertise `library.peers.v1` before a new Mac pairing completes. Existing mobile
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

The upstream Pi desktop/remote dependencies still contain and eagerly import their
own provider baseline (about 951 KB in Pi 1.1.0). Woven's provider catalogs and
selected-label UI no longer depend on it. Removing those upstream bytes requires
an SDK packaging change and is outside this cleanup. The actual iOS Pi Durable
runtime bundle and `harnesses/catalog.json` installation manifest are retained.

OpenRouter catalog entries that declare the dynamic-router unavailable-price sentinel are omitted; their prices are never replaced with zero. Normal chat entries remain available, and destination/header validation still runs before exclusion.
