# Application and persistence ownership

This change starts from `main` at `51b592a61e99a10575516263bdd31dfb29646991`.
It re-evaluates PR54 (`a157a8c`) and PR56 (`f9a2f59`) as references, without
adopting their behavior changes or basing this branch on either PR.

## Ownership and contracts

`ApplicationModel` still owns application startup, workspace state, conversation
refresh, runtime/provider coordination and note editing. Its usage API delegates
to a private `ApplicationUsageModel`. That model owns the usage snapshot, errors,
refresh request identities/coordinators, provider preferences and explicit
credential actions. It has no reference back to `ApplicationModel`, its store,
its conversations or its runtimes.

The application-facing properties remain read-only. Their computed getters read
the nested observable model, so Observation tracks the underlying properties.
No snapshot copies, callbacks, extra tasks or additional refreshes bridge the two
models. Existing synchronous actions stay synchronous; existing async operations
are awaited. The moved methods retain the same MainActor isolation, guards,
request IDs, cancellation checks, task priorities and preference keys. The
existing standard-defaults usage range lookup is deliberately unchanged.

`WorkspaceDatabase` remains one public type and one connection. Its core file
owns the private SQLite connection and private `NSLock`, open/close, transactions,
statement/binding primitives and timestamp encoding. Domain extensions are
parts of that same persistence owner, not separate repositories or connections.
They keep public APIs and domain-specific private helpers together.

- `withLock` forwards directly to the original lock implementation.
- `transaction` retains `BEGIN IMMEDIATE`, commit and rollback in the same scope.
- `changedRowCountUnlocked` reads `sqlite3_changes` on that same private connection.
- Helpers ending in `Unlocked` require an existing lock/transaction scope.
- Cross-domain helper entry points are internal only where existing callers need
  them. Domain-only helpers, schema substeps and the connection/lock stay private.
- SQL, schema/index definitions, migration order, row decoding, public types and
  their constructors are preserved. Nothing moves to another package/module.

## Decisions from the prior PRs

| Prior idea | Decision and reason |
| --- | --- |
| PR56: nine ApplicationModel extension files | Replace only the independent usage responsibility with a state-owning model. The proposed Buzz, OpenClaw, Hermes, OpenCode, LocalACP, messaging, workspace and conversation-change extensions otherwise share application state and would widen many private setters/helpers. Keep these coupled operations together for now. |
| PR56: database domain extensions | Reuse the responsibility-based organization, extracting exact current-main implementations. Keep private lock/connection behind narrow primitives rather than exposing both across the module. |
| PR56: Agents includes surface preferences, Hermes results and ownership | Move surface/ownership operations to Workspace; give Hermes persistence its own domain. Agents owns identity, reconciliation and display metadata. |
| PR56: Notes includes folders/calendar, LocalACP includes mediated note editing | Group folders/calendar with workspace navigation and keep note recovery beside note editing. Session/run writes call the note-context helper inside their original transaction. |
| PR56: helpers and public value types remain in the database core | Move each beside its domain operations. Only the SQLite error type and shared low-level primitives remain in the core. |
| PR54: rendered-message/work caches, refresh throttling and state-based conversation rendering | Leave for the independent performance PR. They change update behavior, dependency tracking or presentation cost and need their own measurements. |
| PR54: markdown styling moves into the parsed document | Leave for performance evaluation; this adds SwiftUI/palette responsibility to a parsing model and changes plain-text derivation. |
| PR54: common POSIX lock/error helpers | Do not adopt. The generic lock adds `fchmod` to the note-journal path; process leases also have distinct nonblocking/lifetime rules. Preserve durability and error-capture semantics. A shared errno expression alone does not establish useful ownership. |
| PR54: public `String.shellQuoted` helper | Do not introduce a global public String API for the small call-site duplication in this PR. Note prompt construction also overlaps PR61's replacement transport. Existing quoting semantics remain intact. |
| PR54: unused provider/runtime/session APIs and remote JS exports removed | Preserve public contracts. Local call-site absence is insufficient evidence that a public/exported API should disappear in an organization-only change. |
| PR54: unused AppKit imports/display policy removed | Leave unrelated view cleanup out; several of these edits accompany changed conversation presentation rather than responsibility boundaries. |
| PR54: redundant message index removal | Leave for performance evaluation. Preserve the complete schema here. |
| PR54: Bash empty-array build fix | Operational fix, independent of code organization; leave to the manager/performance work if needed. |
| PR54: new conversation-state/shell helper tests | Do not carry tests for behavior/helpers not adopted here. Existing persistence/provider suites exercise the moved implementations; the new application usage probe covers the observable state boundary. |

## Integration with the active feature work

PR61 was inspected at `3429cc260256645ee54b83ed2a83756e6d2cb5a9`.
Its ApplicationModel agent-tools operations stay independent of usage. Its
`WorkspaceDatabase+AgentTools`, `+History`, `+Timers`, `+ToolAssets`,
`+SessionCreation`, `+Deliveries`, `+CoordinationAccess`, `+CoordinationEvents`
and `+ToolQueries` filenames do not collide with this map.

During integration, keep PR61's feature additions, then place edits to existing
methods using the map below. Its calls to the old exposed `lock.withLock` and
`sqlite3_changes(connection)` should use `withLock` and
`changedRowCountUnlocked`; helpers that PR61 newly needs must be internal at the
owning domain, rather than copied. Its schema additions belong in `+Schema`.
In particular, keep PR61's `adoptReservedSessionOriginUnlocked` call **after** the
local/remote ACP session-row insertion when resolving those method edits.

For the performance PR, apply changes to conversation read/projection methods
in `+Conversations` and indexes in `+Schema`. ApplicationModel's conversation
refresh/cache paths retain their names and bodies. This PR carries no rendering,
refresh policy, indexing, provider or transport optimizations.

## Exact symbol move map

All overloads of a listed name move together. Original method bodies are retained
except the explicitly documented access qualifiers and lock/row-count access.

`ApplicationModel` → `Models/ApplicationUsageModel.swift`:

- State: `localUsage`, `localUsageError`, `isRefreshingUsageAnalytics`,
  `isRefreshingUsageLimits`, `isRefreshingLocalUsage`,
  `isOpenRouterCredentialConfigured`, `signingInUsageProviders`,
  `hasAcknowledgedCredentialAccessDisclosure`, `enabledUsageProviders`,
  `codexUsageWorkspaces`, `selectedCodexUsageWorkspaceID`.
- Actions: `refreshLocalUsage`, `usageDestinationAppeared`,
  `usageAnalyticsSelected`, `saveOpenRouterAPIKey`, `deleteOpenRouterAPIKey`,
  `acknowledgeCredentialAccessDisclosure`, `isUsageProviderEnabled`,
  `enableUsageProvider`, `retryUsageProviderCredentialAccess`,
  `selectCodexUsageWorkspace`, `disableUsageProvider`, `signInUsageProvider`,
  `reconnectSelectedCodexUsageWorkspace`.
- Private implementation: `refreshUsageAnalytics`, `refreshUsageLimits`,
  `prepareUsageSnapshot`, `emptyUsageAnalytics`, `enableUsageProviderPreference`,
  `disableUsageProviderPreference`, `persistEnabledUsageProviders`,
  `usageProviderSignInCommand`, both refresh-key types and the sign-in command/error
  types; service/coordinators/request IDs and usage defaults constants follow them.
  `currentUsageRange` is read by the owner and the application facade.

`WorkspaceDatabase.swift` → domain files in `WovenMatterDashboardStore`:

### WorkspaceDatabase+Agents.swift

- `localCLIAgentID`, `remoteHarnessAgentID`, `deterministicAgentID`, `ensureRemoteHarnessAgentUnlocked`.
- `ensureRemoteHarnessAgent`, `ensureLocalCLIAgentUnlocked`, `reconcileLocalCLIAgentCatalog`, `dashboardAgents`.
- `renameOpenClawAgent`, `renameHermesAgent`, `renameOpenCodeAgent`, `agentRuntimeMetadata`.

### WorkspaceDatabase+Buzz.swift

Public value/error types: `BuzzWorkspaceDatabaseError`, `BuzzLocalAgentLaunchSource`.

- `upsertBuzzWorkspaceLink`, `upsertBuzzWorkspaceLinkUnlocked`, `buzzWorkspaceLinks`, `buzzWorkspaceLinksUnlocked`.
- `deleteBuzzWorkspaceLink`, `enrollBuzzWorkspaceAgent`, `buzzWorkspaceAgentEnrollments`, `removeBuzzWorkspaceAgentEnrollment`.
- `buzzWorkspaceSnapshot`, `buzzLocalAgentLaunchSource`, `buzzBoundLocalACPConversationIDs`, `buzzWorkspaceLink`.
- `buzzWorkspaceAgentEnrollment`, `reconcileBuzzWorkspaceAgentUnlocked`, `reconcileBuzzWorkspaceAgent`, `retireBuzzWorkspaceAgent`.
- `createBuzzLocalACPSession`.

### WorkspaceDatabase+Conversations.swift

- `dashboardRevision`, `markConversationRead`, `updateConversationTitleIfCurrent`, `moveConversation`.
- `conversationContent`, `conversationHistoryPage`, `messageAttachmentRecordsUnlocked`, `messageReferenceRecordsUnlocked`.
- `runActivityRecordsUnlocked`, `tracePayload`, `dictionary`, `traceString`.
- `traceJSONString`, `traceDetail`, `traceLocations`, `traceFileChanges`.
- `tracePlanEntries`, `decodeCanonicalRowsUnlocked`.

### WorkspaceDatabase+Hermes.swift

- `hermesResultConversation`, `hermesResultRoutes`, `setHermesResultRoute`, `validateHermesResultDestinationUnlocked`.
- `collectHermesResult`, `knownHermesSessionIDs`.

### WorkspaceDatabase+LocalACP.swift

Public value/error types: `LocalACPSessionDescriptor`, `LocalACPRunIdentifiers`, `LocalACPSteeringIdentifiers`, `LocalACPSessionDatabaseError`. The nested `WorkspaceDatabase.DeviceOwnedAssistantMutation` and `WorkspaceDatabase.DeviceOwnedGatewayProjectionResult` declarations move here as well.

- `knownSessionIDs`, `markSessionImportedUnlocked`, `createLocalACPSession`, `createLocalACPSessionUnlocked`.
- `createRemoteACPSession`, `createRemoteACPSessionUnlocked`, `localACPSession`, `localRunAuthorityUnlocked`.
- `updateLocalACPSessionID`, `updateLocalACPSessionConfiguration`, `beginLocalACPRun`, `insertMessageAttachmentsUnlocked`.
- `activeDeviceOwnedConversationIDs`, `beginLocalACPSteeringTurn`, `appendLocalACPAssistantChunk`, `replaceLocalACPAssistantMessage`.
- `completeLocalACPAssistantMessage`, `recordAssistantStreamBoundary`, `upsertDeviceOwnedRunActivity`, `appendDeviceOwnedGatewayTraceEvent`.
- `applyDeviceOwnedGatewayProjection`, `deviceOwnedGatewayTraceEvents`, `claimDeviceOwnedGatewayTraceEventUnlocked`, `gatewayTraceRecordID`.
- `assistantContentReplacingFinalSegmentUnlocked`, `mutateLocalACPAssistantMessageUnlocked`, `recordAssistantStreamBoundaryUnlocked`, `upsertDeviceOwnedRunActivityUnlocked`.
- `completeLocalACPRun`, `cancelLocalACPRun`, `recoverInterruptedLocalACPRuns`, `localAssistantPreviewUnlocked`.
- `localPreview`.

### WorkspaceDatabase+Notes.swift

Public value/error types: `WorkspaceNoteMutationError`, `PendingRemoteNoteEdit`.

- `insertNoteContextUnlocked`, `pendingRemoteNoteEdits`, `applyPendingRemoteNoteEdit`, `dismissPendingRemoteNoteEdit`.
- `dismissTerminalRemoteNoteEdits`, `createNote`, `updateNote`, `persistNoteDraft`.
- `readNoteForEditing`, `applyNoteEdits`, `applyNoteEditsUnlocked`, `nextNotePositionUnlocked`.
- `noteForEditingUnlocked`, `noteSnippet`.

### WorkspaceDatabase+OpenClawGateway.swift

- `saveOpenClawGatewayLink`, `openClawGatewayLinks`, `removeOpenClawGatewayLink`, `attachOpenClawGatewaySession`.
- `openClawGatewayConversationIDs`, `openClawGatewaySessions`, `importOpenClawGatewaySession`, `knownOpenClawSessionKeys`.
- `markOpenClawImportActivityUnlocked`, `importOpenClawGatewaySessionUnlocked`, `openClawToolActivityIDs`, `reconcileOpenClawAuditTool`.
- `reconcileOpenClawActivityMirrorsUnlocked`, `reconcileOpenClawActivitiesUnlocked`, `synchronizeOpenClawHistory`, `synchronizeOpenClawHistoryUnlocked`.
- `interruptedOpenClawRuns`, `openClawRunAssistantIDs`, `recordOpenClawInputUnlocked`, `openClawGatewaySession`.
- `updateOpenClawGatewaySessionPreferences`, `openClawResultRoutes`, `setOpenClawResultRoute`, `collectedOpenClawResultIDs`.
- `validateScheduledResultDestinationUnlocked`, `collectOpenClawResult`, `replaceOpenClawCronSnapshot`, `saveOpenClawRunsUnlocked`.
- `retainedOpenClawResult`, `retainOpenClawResult`, `openClawCronJobs`, `openClawCronRuns`.
- `emptyOpenClawCronTrash`.

### WorkspaceDatabase+OpenCode.swift

- `knownOpenCodeSessionIDs`, `openCodeLinks`, `attachOpenCodeSession`, `openCodeSnapshot`.
- `saveOpenCodeSnapshot`, `saveOpenCodeSnapshotUnlocked`, `saveOpenCodeSubmission`, `openCodeUncertainSubmissions`.

### WorkspaceDatabase+Schema.swift

- `createWorkspaceCacheTablesUnlocked`, `migrate`, `addCurrentColumnsUnlocked`, `createDashboardRevisionTrackingUnlocked`.

### WorkspaceDatabase+Workspace.swift

Public value/error types: `WorkspaceFolderMutationError`, `WorkspaceCalendarMutationError`.

- `bindDeviceOwnership`, `macSurfaceProfile`, `updateMacSurfaceProfile`, `surfaceProfileUnlocked`.
- `createFolder`, `renameFolder`, `setFolderPinned`, `moveFolder`.
- `deleteFolder`, `dashboardRecordCounts`, `calendarItems`, `createCalendarItem`.
- `workspaceOverview`, `canonicalWorkspaceOperatorIDUnlocked`, `localMutationOperatorIDUnlocked`, `validateFolderUnlocked`.
- `agentOrderJSON`, `agentOrder`.
