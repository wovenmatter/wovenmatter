# Central library and distributed workspaces

This is the implementation contract for the multi-client work in PR #37.

## Roles

One designated Mac owns the authoritative Woven Matter SQLite library. Its background service exposes the library API; closing the interface does not transfer authority. iOS, iPadOS, and other Macs use local replicas of the same library and synchronize durable changes.

Execution workspaces run on Macs, Linux containers, and iOS devices. A conversation has one execution workspace, and a run has one owner. A client is an interface to any authorized reachable workspace. Client disconnection does not cancel accepted execution. A central-library outage does not prevent direct workspace control after pairing/provisioning.

Tailscale carries inter-device connections. Woven Matter additionally authenticates individual devices and scopes their access. The central service provisions credentials only for the authenticated paired device. Workspace administrator secrets and provider refresh credentials are not part of content synchronization.

## Storage boundary

The central library consolidates notes, folders, conversations, complete exposed execution history, shared settings, and saved artifacts. Workspace files remain in their workspace: repositories, dependencies, build outputs, caches, and native runtime checkpoints are not mirrored wholesale. Saving an output to the library creates an explicitly synchronized artifact.

A client replica is separate from native runtime persistence. Cache eviction must never remove unsynchronized changes, active runtime state, or the only copy of locally originated history. Execution records retain origin identity and ordering even when multiple clients relay the same records centrally.

Library changes use conditional revisions and retained deletion/conflict state. Commands use stable IDs, immutable request identity and durable receipts. Replay imports observations; it never executes commands. Interrupted transfers resume by validated offsets and content digests. Acknowledgement is emitted only after durable acceptance. Histories exceeding a network page are paged or chunked without truncation.

## Pi Durable on iOS and iPadOS

Pi Durable executes on the iOS device. Its SDK owns the agent loop, submissions, tools, checkpoints and recovery. Inference is exclusively through supported cloud connections or an inference service on another Tailscale device. On-device inference is outside scope for all versions.

The reviewed SDK is bundled with the app and hosted through JavaScriptCore. Native bridges provide durable storage, network streams, credentials, cancellation and mobile tools. The mobile workspace exposes only supported local capabilities. Mac/Linux workspace operations require an explicit target; a suspended local run is never silently moved elsewhere.

Supported API-key connections can call providers directly. A provider integration requiring a desktop SDK can use an authenticated inference-only adapter. That adapter may translate model requests but cannot execute the phone's tools or own its agent loop. The selected adapter's availability is a model-connection dependency, separate from central-library availability.

Accepted work and tool intent are persisted before display/dispatch. iOS background execution is opportunistic: interruption recovery uses native checkpoints and tool receipts. User cancellation remains cancellation after restart. Ambiguous external effects are reconciled or surfaced rather than blindly replayed.

## Client roles and compatibility

A secondary Mac can switch explicitly to client mode after pairing. The transition flushes local writing, checks active work, and restarts with a separate ownership role. Its prior library is preserved. Optional local execution is a distinct workspace origin, not a second authority for the paired library.

The existing companion protocol remains compatible while new federation capabilities are negotiated explicitly. Persistent identities, pairing and unsynchronized writing survive migration. Older servers/clients receive explicit unavailable or version responses for unsupported capabilities.

## Required acceptance

- Real Pi Durable on iOS executes tools locally with a controlled inference fixture, preserves history and resumes safely after interruption.
- Cloud/provider and Tailscale inference routes preserve selected model/account identity; real account checks are reported separately from fixtures.
- With the central Mac offline, clients control reachable workspaces and retain local writing and execution history.
- Reconnection consolidates multiple clients and execution origins without duplicate sends, stale Stop/approval actions, missing output, or resurrected deletions.
- Saved artifacts synchronize with integrity checks and resumable transfers; workspace working files remain local.
- Secondary Mac client mode preserves both the paired replica and the prior local library, with safe failed-transition rollback.
- iPhone and iPad support the existing shared styles and canonical green cube app icon; simulator checks precede physical-device acceptance.

Implementation status and exact test evidence belong in the PR handoff; this document states the required contract and does not claim unperformed live acceptance.
