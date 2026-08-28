import Darwin
import Foundation
import WovenMatterClient
import WovenMatterCore

public struct DashboardRecordCounts: Equatable, Sendable {
  public let profiles: Int
  public let folders: Int
  public let notes: Int
  public let agents: Int
  public let conversations: Int
  public let messages: Int
  public let runs: Int
  public let calendarItems: Int
}

public struct DashboardStoreSnapshot: Sendable {
  public let agents: [WorkspaceAgent]
  public let workspace: WorkspaceSnapshot
  public let calendarItems: [WorkspaceCalendarItemRecord]
  public let recordCounts: DashboardRecordCounts
  public let revision: Int64
}

public struct WorkspaceConversationHistoryCursor: Equatable, Sendable {
  public let createdAt: String
  public let messageID: String

  public init(createdAt: String, messageID: String) {
    self.createdAt = createdAt
    self.messageID = messageID
  }
}

public struct WorkspaceConversationHistoryPage: Equatable, Sendable {
  public let conversationID: String
  public let messages: [WorkspaceMessageRecord]
  public let runs: [WorkspaceRunRecord]
  public let activities: [WorkspaceRunActivityRecord]
  public let attachments: [WorkspaceMessageAttachmentRecord]
  public let references: [WorkspaceMessageReferenceRecord]
  public let hasOlderMessages: Bool

  public var oldestMessageCursor: WorkspaceConversationHistoryCursor? {
    messages.first.map {
      WorkspaceConversationHistoryCursor(createdAt: $0.createdAt, messageID: $0.id)
    }
  }

  public init(
    conversationID: String,
    messages: [WorkspaceMessageRecord],
    runs: [WorkspaceRunRecord],
    activities: [WorkspaceRunActivityRecord] = [],
    attachments: [WorkspaceMessageAttachmentRecord] = [],
    references: [WorkspaceMessageReferenceRecord] = [],
    hasOlderMessages: Bool
  ) {
    self.conversationID = conversationID
    self.messages = messages
    self.runs = runs
    self.activities = activities
    self.attachments = attachments
    self.references = references
    self.hasOlderMessages = hasOlderMessages
  }
}

public struct DashboardConversationChange: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case content
    case terminal
  }

  public let conversationID: String
  public let runID: String
  public let phase: Phase

  public init(
    conversationID: String,
    runID: String,
    phase: Phase
  ) {
    self.conversationID = conversationID
    self.runID = runID
    self.phase = phase
  }
}

public actor DashboardStore {
  public nonisolated let database: WorkspaceDatabase
  public nonisolated let conversationChanges: AsyncStream<DashboardConversationChange>

  private let deviceIdentity: DashboardDeviceIdentity
  private let localSessions: LocalACPSessionCoordinator
  private let openClawGateway: OpenClawGatewayCoordinator
  private let localOpenClawGateways: OpenClawLocalGatewayLifecycle
  private let messageAttachments: MessageAttachmentStore
  private var localWorkspacePrepared = false

  public init(supportDirectory: URL) throws {
    try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    let database = try WorkspaceDatabase(url: supportDirectory.appending(path: "workspace.sqlite"))
    let usageRecorder = try UsageRunRecorder(
      databaseURL: supportDirectory.appending(path: "workspace.sqlite")
    )
    let localProcessLease = try LocalACPProcessLease(
      fileURL: supportDirectory.appending(path: "local-acp-process.lock")
    )
    try Self.recoverInterruptedLocalACPRuns(
      database: database,
      processLease: localProcessLease
    )
    let identity = DashboardDeviceIdentity(
      fileURL: supportDirectory.appending(path: "dashboard-device-id")
    )
    let changes = AsyncStream<DashboardConversationChange>.makeStream(
      bufferingPolicy: .unbounded
    )
    let publishChange: @Sendable (DashboardConversationChange) -> Void = {
      changes.continuation.yield($0)
    }
    self.database = database
    self.deviceIdentity = identity
    self.conversationChanges = changes.stream
    self.messageAttachments = try MessageAttachmentStore(supportDirectory: supportDirectory)
    self.localSessions = LocalACPSessionCoordinator(
      database: database,
      processLease: localProcessLease,
      onChange: publishChange,
      onUsage: { observation in
        try? await usageRecorder.record(observation)
      }
    )
    self.openClawGateway = OpenClawGatewayCoordinator(
      database: database,
      onChange: publishChange
    )
    self.localOpenClawGateways = OpenClawLocalGatewayLifecycle()
  }

  public func stageMessageAttachment(
    fileURL: URL,
    mimeType: String
  ) throws -> AgentMessageAttachmentDraft {
    .file(try messageAttachments.stage(fileURL: fileURL, mimeType: mimeType))
  }

  static func recoverInterruptedLocalACPRuns(
    database: WorkspaceDatabase,
    processLease: any LocalACPProcessLeasing
  ) throws {
    let acquisition = try processLease.acquire()
    if acquisition == .retained {
      processLease.release()
      return
    }
    guard acquisition == .acquired else { return }
    defer { processLease.release() }
    try database.recoverInterruptedLocalACPRuns()
  }

  public func prepareLocalWorkspace() async throws {
    guard !localWorkspacePrepared else { return }
    let deviceID = try await deviceIdentity.id()
    try database.bindDeviceOwnership(ownerDeviceID: deviceID)
    try database.reconcileLocalCLIAgentCatalog(ownerDeviceID: deviceID)
    localWorkspacePrepared = true
  }

  public func buzzWorkspaceSnapshot() throws -> BuzzWorkspaceSnapshot {
    try database.buzzWorkspaceSnapshot()
  }

  public func openClawGatewayLinks() throws -> [OpenClawGatewayLink] {
    try database.openClawGatewayLinks()
  }

  @discardableResult
  public func linkOpenClawGateway(_ link: OpenClawGatewayLink) async throws -> OpenClawGatewayLink {
    try database.saveOpenClawGatewayLink(link)
    _ = try await openClawGateway.reconnect(agentID: link.agentID)
    return try database.openClawGatewayLinks().first(where: {
      $0.agentID == link.agentID
    }) ?? link
  }

  public func unlinkOpenClawGateway(agentID: UUID) async throws {
    await openClawGateway.disconnect(agentID: agentID)
    await localOpenClawGateways.release(agentID: agentID)
    try database.removeOpenClawGatewayLink(agentID: agentID)
  }

  public func configureOpenClawGatewayTransport(
    agentID: UUID,
    endpoint: OpenClawGatewayEndpoint,
    requestHeaders: [String: String]
  ) async {
    await openClawGateway.configureTransport(
      agentID: agentID,
      endpoint: endpoint,
      requestHeaders: requestHeaders
    )
  }

  @discardableResult
  public func markOpenClawGateway(
    agentID: UUID,
    status: OpenClawGatewayConnectionStatus
  ) throws -> OpenClawGatewayLink {
    guard var link = try database.openClawGatewayLinks().first(where: {
      $0.agentID == agentID
    }) else {
      throw OpenClawGatewayClientError.invalidEndpoint
    }
    link.status = status.rawValue
    link.lastError = nil
    link.updatedAt = Date()
    try database.saveOpenClawGatewayLink(link)
    return link
  }

  public func prepareBuzzLocalOpenClawGateway(
    enrollmentID: UUID,
    workspaceLinkID: UUID,
    remoteAgentID: String
  ) async throws -> OpenClawGatewayEndpoint {
    let source = try database.buzzLocalAgentLaunchSource(
      workspaceLinkID: workspaceLinkID,
      agentID: remoteAgentID
    )
    let resolver = BuzzLocalAgentLaunchResolver()
    let initialPort = OpenClawLocalGatewayLifecycle.stablePort(for: remoteAgentID)
    var resolved = try resolver.resolveDirectGateway(
      agentID: remoteAgentID, in: source.link,
      port: initialPort
    )
    let identity = resolved.authoritativeStateRoot ?? "buzz:\(remoteAgentID)"
    let port = OpenClawLocalGatewayLifecycle.stablePort(for: identity)
    if port != initialPort {
      resolved = try resolver.resolveDirectGateway(
        agentID: remoteAgentID, in: source.link,
        port: port
      )
    }
    _ = try await localOpenClawGateways.ensure(
      agentID: enrollmentID, identity: identity,
      launch: resolved.launch, workingDirectory: resolved.workingDirectory
    )
    return OpenClawGatewayEndpointResolver.localAgentWorkspace(port: port)
  }

  public func prepareLocalWorkspaceOpenClawGateway(
    agentID: UUID,
    workingDirectory: URL
  ) async throws -> OpenClawGatewayEndpoint {
    guard let base = LocalACPRuntimeResolver().resolve(runtimeKind: .openclaw).launchConfiguration else {
      throw LocalACPSessionDatabaseError.runtimeUnavailable
    }
    let identity = "local-workspace:\(agentID.uuidString.lowercased())"
    let port = OpenClawLocalGatewayLifecycle.stablePort(for: identity)
    let launch = LocalACPRuntimeLaunchConfiguration(
      runtimeKind: .openclaw,
      executableURL: base.executableURL,
      arguments: [
        "gateway", "--port", String(port), "--bind", "loopback", "--auth", "none",
      ],
      environment: base.environment,
      environmentKeysToRemove: [
        "OPENCLAW_GATEWAY_PASSWORD", "OPENCLAW_GATEWAY_TOKEN", "BUZZ_PRIVATE_KEY",
        "NOSTR_PRIVATE_KEY",
      ],
      environmentKeyPrefixesToRemove: ["BUZZ_", "NOSTR_"]
    )
    _ = try await localOpenClawGateways.ensure(
      agentID: agentID, identity: identity, launch: launch,
      workingDirectory: workingDirectory
    )
    return OpenClawGatewayEndpointResolver.localAgentWorkspace(port: port)
  }

  public func attachOpenClawGatewaySession(
    conversationID: String,
    agentID: UUID,
    sessionKey: String
  ) throws {
    try database.attachOpenClawGatewaySession(
      conversationID: conversationID,
      agentID: agentID,
      sessionKey: sessionKey
    )
  }

  public func openClawGatewayConversationIDs() throws -> Set<String> {
    try database.openClawGatewayConversationIDs()
  }

  @discardableResult
  public func acceptOpenClawGatewayPrompt(
    conversationID: String,
    content: String,
    deliveryContent: String? = nil,
    noteContext: AgentNoteContext? = nil,
    onPermission: OpenClawGatewayCoordinator.PermissionHandler? = nil,
    onUpdate: OpenClawGatewayCoordinator.UpdateHandler? = nil
  ) async throws -> LocalACPRunIdentifiers {
    try await openClawGateway.accept(
      conversationID: conversationID,
      input: AgentMessageInput(text: content),
      deliveryContent: deliveryContent,
      noteContext: noteContext,
      onPermission: onPermission,
      onUpdate: onUpdate
    )
  }

  @discardableResult
  public func acceptOpenClawGatewayPrompt(
    conversationID: String,
    input: AgentMessageInput,
    deliveryContent: String? = nil,
    noteContext: AgentNoteContext? = nil,
    onPermission: OpenClawGatewayCoordinator.PermissionHandler? = nil,
    onUpdate: OpenClawGatewayCoordinator.UpdateHandler? = nil
  ) async throws -> LocalACPRunIdentifiers {
    try await openClawGateway.accept(
      conversationID: conversationID,
      input: input,
      deliveryContent: deliveryContent,
      noteContext: noteContext,
      onPermission: onPermission,
      onUpdate: onUpdate
    )
  }

  public func cancelOpenClawGatewayPrompt(conversationID: String) async throws {
    try await openClawGateway.cancel(conversationID: conversationID)
  }

  public func openClawGatewaySessionPreferences(
    conversationID: String
  ) async throws -> OpenClawSessionPreferences {
    try await openClawGateway.sessionPreferences(conversationID: conversationID)
  }

  public func patchOpenClawGatewaySession(
    conversationID: String,
    preferences: OpenClawSessionPreferences
  ) async throws -> OpenClawSessionPreferences {
    try await openClawGateway.patchSession(
      conversationID: conversationID,
      preferences: preferences
    )
  }

  @discardableResult
  public func restartOpenClawGateway(agentID: UUID) async throws -> OpenClawGatewayLink {
    try await openClawGateway.restart(agentID: agentID)
  }

  @discardableResult
  public func refreshOpenClawGatewayStatus(agentID: UUID) async throws -> OpenClawGatewayLink {
    try await openClawGateway.refreshStatus(agentID: agentID)
  }

  public func openClawGatewaySessionMetadata(
    conversationID: String
  ) async throws -> LocalACPSessionMetadata {
    try await openClawGateway.sessionMetadata(conversationID: conversationID)
  }

  public func renameOpenClawAgent(agentID: UUID, displayName: String) throws {
    try database.renameOpenClawAgent(id: agentID, displayName: displayName)
  }

  public func openClawHeartbeatConfiguration(
    agentID: UUID
  ) async throws -> OpenClawHeartbeatConfiguration {
    try await openClawGateway.heartbeatConfiguration(agentID: agentID)
  }

  public func updateOpenClawHeartbeat(
    agentID: UUID,
    configuration: OpenClawHeartbeatConfiguration
  ) async throws -> OpenClawHeartbeatConfiguration {
    try await openClawGateway.updateHeartbeat(
      agentID: agentID,
      configuration: configuration
    )
  }

  public func syncOpenClawCron(agentID: UUID) async throws {
    try await openClawGateway.syncCron(agentID: agentID)
  }

  public func openClawCronJobs(agentID: UUID? = nil) throws -> [OpenClawCronJob] {
    try database.openClawCronJobs(agentID: agentID)
  }

  public func openClawCronRuns(agentID: UUID? = nil) throws -> [OpenClawCronRun] {
    try database.openClawCronRuns(agentID: agentID)
  }

  public func emptyOpenClawCronTrash(agentID: UUID? = nil) throws {
    try database.emptyOpenClawCronTrash(agentID: agentID)
  }

  public func saveBuzzWorkspace(_ link: BuzzWorkspaceLink) throws {
    try database.upsertBuzzWorkspaceLink(link)
  }

  public func deleteBuzzWorkspace(id: UUID) async throws {
    try await prepareLocalWorkspace()
    let deviceID = try await deviceIdentity.id()
    for enrollment in try database.buzzWorkspaceAgentEnrollments(
      workspaceLinkID: id
    ) {
      try database.retireBuzzWorkspaceAgent(
        enrollmentID: enrollment.id,
        ownerDeviceID: deviceID
      )
    }
    try database.deleteBuzzWorkspaceLink(id: id)
  }

  public func discoverBuzzWorkspaceAgents(
    linkID: UUID
  ) async throws -> [BuzzWorkspaceAgentCandidate] {
    guard let link = try database.buzzWorkspaceLinks().first(where: {
      $0.id == linkID
    }) else {
      throw BuzzWorkspaceDatabaseError.workspaceNotFound
    }
    return try BuzzLocalAgentDiscovery().candidates(for: link)
  }

  @discardableResult
  public func enrollBuzzWorkspaceAgent(
    _ candidate: BuzzWorkspaceAgentCandidate
  ) async throws -> BuzzWorkspaceAgentEnrollment {
    try await prepareLocalWorkspace()
    let enrollment = try database.enrollBuzzWorkspaceAgent(candidate)
    if try database.buzzWorkspaceLinks().contains(where: {
      $0.id == enrollment.workspaceLinkID
    }), enrollment.runtimeKind != nil {
      let resolved = try? resolvedBuzzLaunch(
        workspaceLinkID: enrollment.workspaceLinkID,
        agentID: enrollment.agentID
      )
      let status: AgentRuntimeStatus = resolved?.launch.runtimeKind == enrollment.runtimeKind
        ? .ready : .offline
      try database.reconcileBuzzWorkspaceAgent(
        enrollment: enrollment,
        ownerDeviceID: try await deviceIdentity.id(),
        status: status
      )
    }
    return enrollment
  }

  public func removeBuzzWorkspaceAgentEnrollment(id: UUID) async throws {
    try await prepareLocalWorkspace()
    let deviceID = try await deviceIdentity.id()
    try database.retireBuzzWorkspaceAgent(
      enrollmentID: id,
      ownerDeviceID: deviceID
    )
    try database.removeBuzzWorkspaceAgentEnrollment(id: id)
  }

  public func reconcileBuzzWorkspaceAgents() async throws -> Set<UUID> {
    try await prepareLocalWorkspace()
    let deviceID = try await deviceIdentity.id()
    let linksByID = Dictionary(
      uniqueKeysWithValues: try database.buzzWorkspaceLinks().map { ($0.id, $0) }
    )
    var launchable: Set<UUID> = []
    for enrollment in try database.buzzWorkspaceAgentEnrollments() {
      guard let link = linksByID[enrollment.workspaceLinkID],
        enrollment.runtimeKind != nil
      else {
        continue
      }
      let resolved = try? resolvedBuzzLaunch(
        workspaceLinkID: enrollment.workspaceLinkID,
        agentID: enrollment.agentID
      )
      let isLaunchable = link.isEnabled
        && resolved?.launch.runtimeKind == enrollment.runtimeKind
      if isLaunchable { launchable.insert(enrollment.id) }
      try database.reconcileBuzzWorkspaceAgent(
        enrollment: enrollment,
        ownerDeviceID: deviceID,
        status: isLaunchable ? .ready : .offline
      )
    }
    return launchable
  }

  public func createBuzzWorkspaceLocalACPSession(
    enrollmentID: UUID,
    title: String
  ) async throws -> String {
    try await prepareLocalWorkspace()
    guard let enrollment = try database.buzzWorkspaceAgentEnrollments()
      .first(where: { $0.id == enrollmentID }) else {
      throw BuzzWorkspaceDatabaseError.enrollmentNotFound
    }
    let resolved = try resolvedBuzzLaunch(
      workspaceLinkID: enrollment.workspaceLinkID,
      agentID: enrollment.agentID
    )
    guard resolved.launch.runtimeKind == enrollment.runtimeKind else {
      throw BuzzWorkspaceDatabaseError.enrollmentRequiresRefresh
    }
    return try database.createBuzzLocalACPSession(
      enrollmentID: enrollmentID,
      title: title,
      ownerDeviceID: try await deviceIdentity.id(),
      model: resolved.model
    )
  }

  public func buzzBoundLocalACPConversationIDs() throws -> Set<String> {
    try database.buzzBoundLocalACPConversationIDs()
  }

  public func start() async {
    do {
      try await prepareLocalWorkspace()
    } catch {
      NSLog("Could not bind Mac dashboard device authority: %@", error.localizedDescription)
      return
    }
  }

  public func reconcileLocalCLIAgentCatalog(
    statuses: [AgentRuntimeKind: AgentRuntimeStatus]
  ) async throws {
    try await prepareLocalWorkspace()
    try database.reconcileLocalCLIAgentCatalog(
      ownerDeviceID: try await deviceIdentity.id(),
      statuses: statuses
    )
  }

  public func snapshot() async throws -> DashboardStoreSnapshot {
    return DashboardStoreSnapshot(
      agents: try database.dashboardAgents(),
      workspace: try database.workspaceOverview(),
      calendarItems: try database.calendarItems(),
      recordCounts: try database.dashboardRecordCounts(),
      revision: try database.dashboardRevision()
    )
  }

  public func snapshot(ifChangedFrom revision: Int64?) async throws -> DashboardStoreSnapshot? {
    let currentRevision = try database.dashboardRevision()
    guard revision != currentRevision else { return nil }
    return try await snapshot()
  }

  public func conversationContent(id: String) throws -> WorkspaceConversationContent {
    try database.conversationContent(id: id)
  }

  public func conversationHistoryPage(
    id: String,
    before cursor: WorkspaceConversationHistoryCursor? = nil,
    limit: Int
  ) throws -> WorkspaceConversationHistoryPage {
    try database.conversationHistoryPage(id: id, before: cursor, limit: limit)
  }

  @discardableResult
  public func markConversationRead(id: String) throws -> Bool {
    try database.markConversationRead(id: id)
  }

  @discardableResult
  public func moveConversation(id: String, toFolderID folderID: String?) throws -> Bool {
    try database.moveConversation(id: id, toFolderID: folderID)
  }

  @discardableResult
  public func createFolder(name: String) throws -> String {
    try database.createFolder(name: name)
  }

  public func renameFolder(id: String, name: String) throws {
    try database.renameFolder(id: id, name: name)
  }

  public func setFolderPinned(id: String, isPinned: Bool) throws {
    try database.setFolderPinned(id: id, isPinned: isPinned)
  }

  @discardableResult
  public func moveFolder(
    id: String,
    direction: WorkspaceFolderMoveDirection
  ) throws -> Bool {
    try database.moveFolder(id: id, direction: direction)
  }

  public func deleteFolder(id: String) throws {
    try database.deleteFolder(id: id)
  }

  @discardableResult
  public func createNote(
    folderID: String?,
    kind: NoteArtifactKind = .note
  ) throws -> String {
    try database.createNote(
      folderID: folderID,
      title: kind == .note ? "Untitled Note" : "Untitled \(kind.displayName)",
      kind: kind
    )
  }

  @discardableResult
  public func createCalendarItem(
    title: String,
    startsAt: Date,
    endsAt: Date?,
    allDay: Bool
  ) throws -> String {
    try database.createCalendarItem(
      title: title,
      startsAt: startsAt,
      endsAt: endsAt,
      allDay: allDay
    )
  }

  public func updateNote(id: String, title: String, content: String) throws {
    try database.updateNote(id: id, title: title, content: content)
  }

  public func handleNoteEditingRequest(
    _ request: NoteEditingRequest
  ) throws -> NoteEditingResponse {
    switch request.command {
    case .read:
      try database.readNoteForEditing(id: request.noteID)
    case .apply:
      try database.applyNoteEdits(request)
    }
  }

  @discardableResult
  public func updateConversationTitleIfCurrent(
    id: String,
    expectedTitle: String,
    title: String
  ) throws -> Bool {
    try database.updateConversationTitleIfCurrent(
      id: id,
      expectedTitle: expectedTitle,
      title: title
    )
  }

  @discardableResult
  public func createLocalACPSession(
    runtimeKind: AgentRuntimeKind,
    title: String
  ) async throws -> String {
    try database.createLocalACPSession(
      runtimeKind: runtimeKind,
      title: title,
      ownerDeviceID: try await deviceIdentity.id()
    )
  }

  @discardableResult
  public func createRemoteACPSession(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    title: String
  ) async throws -> String {
    try database.createRemoteACPSession(
      runtimeKind: runtimeKind,
      remoteWorkspaceID: remoteWorkspaceID,
      remoteWorkspaceName: remoteWorkspaceName,
      title: title,
      ownerDeviceID: try await deviceIdentity.id()
    )
  }

  @discardableResult
  public func ensureRemoteHarnessAgent(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String
  ) async throws -> UUID {
    try database.ensureRemoteHarnessAgent(
      runtimeKind: runtimeKind,
      remoteWorkspaceID: remoteWorkspaceID,
      remoteWorkspaceName: remoteWorkspaceName,
      ownerDeviceID: try await deviceIdentity.id()
    )
  }

  public func activeAgentConversationIDs() throws -> Set<String> {
    try database.activeDeviceOwnedConversationIDs()
  }

  public func macSurfaceProfile(
    bootstrap: SurfaceProfile
  ) async throws -> SurfaceProfile {
    let deviceID = try await deviceIdentity.id()
    return try database.macSurfaceProfile(
      ownerDeviceID: deviceID,
      bootstrap: bootstrap
    )
  }

  public func updateMacSurfaceProfile(
    _ profile: SurfaceProfile
  ) async throws -> SurfaceProfile {
    let deviceID = try await deviceIdentity.id()
    return try database.updateMacSurfaceProfile(
      profile,
      ownerDeviceID: deviceID
    )
  }

  public func dashboardDeviceID() async throws -> UUID {
    try await deviceIdentity.id()
  }

  @discardableResult
  public func acceptLocalACPPrompt(
    conversationID: String,
    content: String,
    deliveryContent: String? = nil,
    noteContext: AgentNoteContext? = nil,
    launch: LocalACPRuntimeLaunchConfiguration?,
    workspace: LocalACPWorkspaceLaunchConfiguration?,
    onPermission: LocalACPSessionCoordinator.PermissionHandler? = nil,
    onInteraction: LocalACPSessionCoordinator.InteractionHandler? = nil
  ) async throws -> LocalACPRunIdentifiers {
    try await acceptLocalACPPrompt(
      conversationID: conversationID,
      input: AgentMessageInput(text: content),
      deliveryContent: deliveryContent,
      noteContext: noteContext,
      launch: launch,
      workspace: workspace,
      onPermission: onPermission,
      onInteraction: onInteraction
    )
  }

  @discardableResult
  public func acceptLocalACPPrompt(
    conversationID: String,
    input: AgentMessageInput,
    deliveryContent: String? = nil,
    noteContext: AgentNoteContext? = nil,
    launch: LocalACPRuntimeLaunchConfiguration?,
    workspace: LocalACPWorkspaceLaunchConfiguration?,
    onPermission: LocalACPSessionCoordinator.PermissionHandler? = nil,
    onInteraction: LocalACPSessionCoordinator.InteractionHandler? = nil
  ) async throws -> LocalACPRunIdentifiers {
    let context = try localACPLaunchContext(
      conversationID: conversationID,
      directLaunch: launch,
      directWorkspace: workspace
    )
    return try await localSessions.accept(
      conversationID: conversationID,
      input: input,
      deliveryContent: deliveryContent,
      noteContext: noteContext,
      launch: context.launch,
      workspace: context.workspace,
      systemPrompt: context.systemPrompt,
      onPermission: onPermission,
      onInteraction: onInteraction
    )
  }

  @discardableResult
  public func sendActiveLocalACPPrompt(
    conversationID: String,
    content: String,
    deliveryContent: String? = nil
  ) async throws -> LocalACPSteeringIdentifiers {
    try await sendActiveLocalACPPrompt(
      conversationID: conversationID,
      input: AgentMessageInput(text: content),
      deliveryContent: deliveryContent
    )
  }

  @discardableResult
  public func sendActiveLocalACPPrompt(
    conversationID: String,
    input: AgentMessageInput,
    deliveryContent: String? = nil
  ) async throws -> LocalACPSteeringIdentifiers {
    return try await localSessions.sendActiveInput(
      conversationID: conversationID,
      input: input,
      deliveryContent: deliveryContent
    )
  }

  @discardableResult
  public func sendActiveOpenClawGatewayPrompt(
    conversationID: String,
    content: String,
    deliveryContent: String? = nil
  ) async throws -> LocalACPSteeringIdentifiers {
    try await sendActiveOpenClawGatewayPrompt(
      conversationID: conversationID,
      input: AgentMessageInput(text: content),
      deliveryContent: deliveryContent
    )
  }

  @discardableResult
  public func sendActiveOpenClawGatewayPrompt(
    conversationID: String,
    input: AgentMessageInput,
    deliveryContent: String? = nil
  ) async throws -> LocalACPSteeringIdentifiers {
    try await openClawGateway.sendActiveInput(
      conversationID: conversationID,
      input: input,
      deliveryContent: deliveryContent
    )
  }

  public func localACPSessionConfiguration(
    conversationID: String,
    launch: LocalACPRuntimeLaunchConfiguration?,
    workspace: LocalACPWorkspaceLaunchConfiguration?
  ) async throws -> LocalACPSessionConfiguration {
    let context = try localACPLaunchContext(
      conversationID: conversationID,
      directLaunch: launch,
      directWorkspace: workspace
    )
    return try await localSessions.configuration(
      conversationID: conversationID,
      launch: context.launch,
      workspace: context.workspace,
      systemPrompt: context.systemPrompt
    )
  }

  public func updateLocalACPSessionConfiguration(
    conversationID: String,
    model: String? = nil,
    thinking: String? = nil,
    launch: LocalACPRuntimeLaunchConfiguration?,
    workspace: LocalACPWorkspaceLaunchConfiguration?
  ) async throws -> LocalACPSessionConfiguration {
    let context = try localACPLaunchContext(
      conversationID: conversationID,
      directLaunch: launch,
      directWorkspace: workspace
    )
    return try await localSessions.updateConfiguration(
      conversationID: conversationID,
      model: model,
      thinking: thinking,
      launch: context.launch,
      workspace: context.workspace,
      systemPrompt: context.systemPrompt
    )
  }

  private func localACPLaunchContext(
    conversationID: String,
    directLaunch: LocalACPRuntimeLaunchConfiguration?,
    directWorkspace: LocalACPWorkspaceLaunchConfiguration?
  ) throws -> (
    launch: LocalACPRuntimeLaunchConfiguration,
    workspace: LocalACPWorkspaceLaunchConfiguration,
    systemPrompt: String?
  ) {
    let descriptor = try database.localACPSession(conversationID: conversationID)
    if let workspaceLinkID = descriptor.buzzWorkspaceLinkID,
       let buzzAgentID = descriptor.buzzAgentID {
      let resolved = try resolvedBuzzLaunch(
        workspaceLinkID: workspaceLinkID,
        agentID: buzzAgentID
      )
      return (
        resolved.launch,
        LocalACPWorkspaceLaunchConfiguration(
          rootURL: resolved.workingDirectory,
          repositoriesURL: resolved.workingDirectory.appending(
            path: "REPOS",
            directoryHint: .isDirectory
          )
        ),
        resolved.systemPrompt
      )
    }
    guard let directLaunch, let directWorkspace else {
      throw LocalACPSessionDatabaseError.runtimeUnavailable
    }
    return (directLaunch, directWorkspace, nil)
  }

  private func resolvedBuzzLaunch(
    workspaceLinkID: UUID,
    agentID: String
  ) throws -> BuzzLocalAgentLaunch {
    let source = try database.buzzLocalAgentLaunchSource(
      workspaceLinkID: workspaceLinkID,
      agentID: agentID
    )
    return try BuzzLocalAgentLaunchResolver().resolve(
      agentID: agentID,
      in: source.link
    )
  }

  public func cancelLocalACPPrompt(conversationID: String) async {
    await localSessions.cancel(conversationID: conversationID)
  }

  public func shutdownLocalACPSessions() async {
    await localSessions.shutdown()
    await localOpenClawGateways.shutdown()
  }

}

actor DashboardDeviceIdentity {
  private static let localLock = NSLock()

  private let fileURL: URL
  private var cached: UUID?

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func id() throws -> UUID {
    if let cached { return cached }
    let value = try Self.localLock.withLock {
      try withExclusiveFileLock {
        if let existing = storedID() {
          return existing
        }

        let created = UUID()
        try created.uuidString.lowercased().write(
          to: fileURL,
          atomically: true,
          encoding: .utf8
        )
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: fileURL.path
        )
        return created
      }
    }
    cached = value
    return value
  }

  private func storedID() -> UUID? {
    guard let value = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return nil
    }
    return UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func withExclusiveFileLock<T>(_ operation: () throws -> T) throws -> T {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let lockURL = directory.appending(path: ".dashboard-device-id.lock")
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { throw Self.currentPOSIXError() }
    defer { Darwin.close(descriptor) }
    guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw Self.currentPOSIXError()
    }
    guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
      throw Self.currentPOSIXError()
    }
    defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
    return try operation()
  }

  private static func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
