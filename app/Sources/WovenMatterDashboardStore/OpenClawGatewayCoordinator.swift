import Foundation
import WovenMatterClient
import WovenMatterCore

public actor OpenClawGatewayCoordinator {
  public typealias UpdateHandler = @Sendable (String) async -> Void
  public typealias PermissionHandler = @Sendable (LocalACPPermissionRequest) async -> String?
  public typealias ChangeHandler = @Sendable (DashboardConversationChange) -> Void
  typealias RunExecutor = @Sendable (
    _ runID: String,
    _ agentID: UUID,
    _ sessionKey: String,
    _ content: String
  ) async throws -> Void

  private struct ActiveRun {
    let runID: String
    let conversationID: String
    let agentID: UUID
    let sessionKey: String
    let onUpdate: UpdateHandler?
    let onPermission: PermissionHandler?
    var terminalStatesByRemoteRunID: [
      String: OpenClawGatewayEventProjection.TerminalState
    ] = [:]
    var eventFence = GatewayStreamEventFence()
    var assistantSource = GatewayAssistantStreamSource()
    var cancelRequested = false
    var fallbackSequence = 0
    var liveToolCallIDs: Set<String> = []
    var remoteRunIDs: Set<String>
    var lastRemoteRunID: String
    var assistantMessageIDsByRemoteRunID: [String: String]
  }

  private struct ActiveInputTask {
    let remoteRunID: String
    let assistantMessageID: String
    let task: Task<OpenClawGatewayEventProjection.TerminalState, any Error>
  }
  static let nativeRestartMethod = "gateway.restart.request"
  static let nativeRestartParameters: GatewayJSONValue = .object([
    "reason": .string("Woven Matter user request"),
  ])
  private static let modelsListParameters: GatewayJSONValue = .object([
    "view": .string("configured"),
    "preparedOnly": .bool(true),
  ])
  private var cronSyncAgents: Set<UUID> = []

  typealias ConnectClient = @Sendable (OpenClawGatewayClient) async throws -> OpenClawGatewayCapabilities
  private let connectClient: ConnectClient
  private var connectionGenerations: [UUID: UUID] = [:]
  private let database: WorkspaceDatabase
  private let runExecutor: RunExecutor?
  private let onChange: ChangeHandler?
  private var clients: [UUID: OpenClawGatewayClient] = [:]
  private struct ClientTransport: Sendable {
    let endpoint: OpenClawGatewayEndpoint
    let headers: [String: String]
    var password: String? = nil
  }
  private var clientTransports: [UUID: ClientTransport] = [:]
  private var pendingClientConnections: [
    UUID: Task<OpenClawGatewayClient, any Error>
  ] = [:]
  private var activeRuns: [String: ActiveRun] = [:]
  private var runTasks: [String: Task<Void, any Error>] = [:]
  private var activeInputTasksByRunID: [
    String: [ActiveInputTask]
  ] = [:]
  private var approvalTasks: [String: Task<Void, Never>] = [:]
  private var approvalRunIDs: [String: String] = [:]
  private var steeringLocks: Set<String> = []
  private var steeringWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var promptReadyRunIDs: Set<String> = []
  private var promptReadyWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
  private var pausedGatewayEventRunIDs: Set<String> = []
  private var bufferedGatewayEventsByRunID: [
    String: [(OpenClawGatewayEvent, UUID, UUID)]
  ] = [:]
  private var contentPublicationTasks: [String: Task<Void, Never>] = [:]
  private static let contentPublicationDelay = Duration.milliseconds(50)
  private var monitorTasks: [UUID: Task<Void, Never>] = [:]
  private var historyTasks: [String: (agentID: UUID, task: Task<Void, Never>)] = [:]
  private var dirtyHistories: Set<String> = []
  private var testClient: OpenClawGatewayClient?
  private var automaticReconnect = true
  private var isShuttingDown = false

  public init(
    database: WorkspaceDatabase,
    onChange: ChangeHandler? = nil
  ) {
    self.connectClient = { try await $0.connect() }
    self.database = database
    self.runExecutor = nil
    self.onChange = onChange
  }

  init(
    database: WorkspaceDatabase,
    onChange: ChangeHandler? = nil,
    runExecutor: @escaping RunExecutor
  ) {
    self.connectClient = { try await $0.connect() }
    self.database = database
    self.runExecutor = runExecutor
    self.onChange = onChange
    self.automaticReconnect = false
  }

  init(database: WorkspaceDatabase, client: OpenClawGatewayClient? = nil, connectClient: @escaping ConnectClient) {
    self.database = database
    self.connectClient = connectClient
    self.runExecutor = nil
    self.onChange = nil
    self.automaticReconnect = false
    self.testClient = client
  }

  private func invalidateConnection(agentID: UUID) -> OpenClawGatewayClient? {
    monitorTasks.removeValue(forKey: agentID)?.cancel()
    for (conversationID, refresh) in historyTasks where refresh.agentID == agentID {
      refresh.task.cancel()
      historyTasks.removeValue(forKey: conversationID)
      dirtyHistories.remove(conversationID)
    }
    connectionGenerations.removeValue(forKey: agentID)
    pendingClientConnections.removeValue(forKey: agentID)?.cancel()
    return clients.removeValue(forKey: agentID)
  }

  public func reconnect(
    agentID: UUID,
    attempts requestedAttempts: Int? = nil
  ) async throws -> OpenClawGatewayCapabilities {
    await invalidateConnection(agentID: agentID)?.disconnect()
    let location = try database.openClawGatewayLinks().first(where: {
      $0.agentID == agentID
    })?.location
    let attempts = requestedAttempts ?? (location == .buzzLocal
      || location == .localAgentWorkspace
      || location == .remoteWorkspace ? 12 : 1)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(
      by: requestedAttempts == nil ? .seconds(20) : .seconds(45)
    )
    try? setLinkStatus(agentID: agentID, status: .reconnecting, error: nil)
    var lastError: any Error = OpenClawGatewayClientError.invalidEndpoint
    for attempt in 0..<attempts {
      do {
        let client = try await client(agentID: agentID)
        let capabilities = try await client.connect()
        _ = try await client.request("health", timeout: .seconds(5))
        return capabilities
      } catch {
        lastError = error
        await disconnect(agentID: agentID)
        guard attempt + 1 < attempts,
              Self.shouldRetryConnection(error),
              clock.now < deadline else { break }
        try? setLinkStatus(
          agentID: agentID,
          status: .reconnecting,
          error: error.localizedDescription
        )
        let retryDelay = (error as? OpenClawGatewayClientError)?.retryDelay
          ?? .milliseconds(250 * (1 << min(attempt, 3)))
        let remaining = clock.now.duration(to: deadline)
        try await Task.sleep(for: min(retryDelay, remaining))
      }
    }
    try? setLinkStatus(
      agentID: agentID,
      status: .unavailable,
      error: lastError.localizedDescription
    )
    throw lastError
  }

  private static func shouldRetryConnection(_ error: any Error) -> Bool {
    guard let gatewayError = error as? OpenClawGatewayClientError else {
      return true
    }
    switch gatewayError {
    case .invalidEndpoint, .authenticationMissing, .rejected,
         .unsupportedCapability, .malformedFrame, .challengeMissing:
      return false
    case .connectionClosed, .unavailable, .requestTimedOut:
      return true
    }
  }

  public func disconnect(agentID: UUID) async {
    await invalidateConnection(agentID: agentID)?.disconnect()
  }

  public func shutdown() async {
    isShuttingDown = true
    for task in runTasks.values { task.cancel() }
    for refresh in historyTasks.values { refresh.task.cancel() }
    for task in monitorTasks.values { task.cancel() }
    for agentID in Set(clients.keys).union(pendingClientConnections.keys) {
      await disconnect(agentID: agentID)
    }
  }

  public func configureTransport(
    agentID: UUID,
    endpoint: OpenClawGatewayEndpoint,
    requestHeaders: [String: String],
    password: String? = nil
  ) async {
    let previous = invalidateConnection(agentID: agentID)
    clientTransports[agentID] = ClientTransport(
      endpoint: endpoint,
      headers: requestHeaders, password: password
    )
    await previous?.disconnect()
  }

  @discardableResult
  public func accept(
    conversationID: String,
    content: String,
    deliveryContent: String? = nil,
    noteContext: AgentNoteContext? = nil,
    onPermission: PermissionHandler? = nil,
    onUpdate: UpdateHandler? = nil
  ) async throws -> LocalACPRunIdentifiers {
    try await accept(
      conversationID: conversationID,
      input: AgentMessageInput(text: content),
      deliveryContent: deliveryContent,
      noteContext: noteContext,
      onPermission: onPermission,
      onUpdate: onUpdate
    )
  }

  @discardableResult
  public func accept(
    conversationID: String,
    input: AgentMessageInput,
    deliveryContent: String? = nil,
    noteContext: AgentNoteContext? = nil,
    onPermission: PermissionHandler? = nil,
    onUpdate: UpdateHandler? = nil
  ) async throws -> LocalACPRunIdentifiers {
    let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
    let capabilities: OpenClawGatewayCapabilities?
    if runExecutor == nil {
      capabilities = try await client(agentID: descriptor.agentID).connect()
    } else {
      capabilities = nil
    }
    let attachments = try Self.gatewayAttachments(
      input.files,
      policy: capabilities?.attachmentPolicy
    )
    let transportContent = input.transportText(deliveryText: deliveryContent)
    try Self.validateGatewayPayload(
      maximumBytes: capabilities?.maximumPayloadBytes,
      sessionKey: descriptor.sessionKey,
      content: transportContent,
      attachments: attachments
    )
    let (run, _) = try beginAcceptedRun(
      conversationID: conversationID,
      input: input,
      transportContent: transportContent,
      noteContext: noteContext,
      attachments: attachments,
      onPermission: onPermission,
      onUpdate: onUpdate
    )
    return run
  }

  private func beginAcceptedRun(
    conversationID: String,
    input: AgentMessageInput,
    transportContent: String? = nil,
    noteContext: AgentNoteContext? = nil,
    attachments: [GatewayJSONValue],
    onPermission: PermissionHandler?,
    onUpdate: UpdateHandler?
  ) throws -> (LocalACPRunIdentifiers, Task<Void, any Error>) {
    let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
    let run = try database.beginLocalACPRun(
      conversationID: conversationID,
      input: input,
      noteContext: noteContext
    )
    activeRuns[run.runID] = ActiveRun(
      runID: run.runID,
      conversationID: conversationID,
      agentID: descriptor.agentID,
      sessionKey: descriptor.sessionKey,
      onUpdate: onUpdate,
      onPermission: onPermission,
      remoteRunIDs: [run.runID],
      lastRemoteRunID: run.runID,
      assistantMessageIDsByRemoteRunID: [run.runID: run.assistantMessageID]
    )
    publishChange(runID: run.runID, phase: .content)
    let task = Task { [self] in
      try await driveAcceptedRun(
        run: run,
        agentID: descriptor.agentID,
        sessionKey: descriptor.sessionKey,
        content: transportContent ?? input.textWithReferenceContext,
        attachments: attachments
      )
    }
    runTasks[run.runID] = task
    return (run, task)
  }

  private func driveAcceptedRun(
    run: LocalACPRunIdentifiers,
    agentID: UUID,
    sessionKey: String,
    content: String,
    attachments: [GatewayJSONValue]
  ) async throws {
    defer { finishTracking(runID: run.runID) }
    do {
      if let runExecutor {
        try await runExecutor(run.runID, agentID, sessionKey, content)
        try database.completeLocalACPRun(runID: run.runID)
        await publishUpdate(runID: run.runID, phase: .terminal)
        return
      }
      let client = try await client(agentID: agentID)
      let receipt = try await client.request("chat.send", params: .object(
        Self.chatSendParameters(
          sessionKey: sessionKey,
          content: content,
          runID: run.runID,
          attachments: attachments
        )
      ))
      guard let remoteRunID = receipt.objectValue?["runId"]?.stringValue,
            remoteRunID == run.runID else {
        throw OpenClawGatewayClientError.malformedFrame
      }
      markPromptReady(runID: run.runID)
      await publishUpdate(runID: run.runID, phase: .content)
      let initialTerminal: OpenClawGatewayEventProjection.TerminalState
      do {
        initialTerminal = try await waitForRun(
          localRunID: run.runID,
          remoteRunID: run.runID,
          agentID: agentID
        )
      } catch {
        if Task.isCancelled { return }
        if Self.isRecoverableDeliveryError(error), let conversationID = activeRuns[run.runID]?.conversationID {
          await observeRecoveredRun(run: run, conversationID: conversationID)
          return
        }
        initialTerminal = .failed(error.localizedDescription)
      }
      guard let conversationID = activeRuns[run.runID]?.conversationID else {
        throw LocalACPSessionDatabaseError.steeringUnsupported
      }
      let terminal = try await drainActiveInputs(
        runID: run.runID,
        conversationID: conversationID,
        initialTerminal: initialTerminal
      )
      let remoteRunIDs = activeRuns[run.runID]?.remoteRunIDs ?? [run.runID]
      for remoteRunID in remoteRunIDs {
        if Task.isCancelled { return }
        await reconcileAudit(
          runID: run.runID,
          remoteRunID: remoteRunID,
          agentID: agentID
        )
        guard let assistantMessageID = activeRuns[run.runID]?
          .assistantMessageIDsByRemoteRunID[remoteRunID] else { continue }
        await reconcileAssistantHistory(
          runID: run.runID,
          assistantMessageID: assistantMessageID,
          remoteRunID: remoteRunID,
          sessionKey: sessionKey,
          agentID: agentID
        )
        let segmentTerminal = activeRuns[run.runID]?
          .terminalStatesByRemoteRunID[remoteRunID] ?? .completed
        completeAssistantSegment(
          runID: run.runID,
          assistantMessageID: assistantMessageID,
          terminal: segmentTerminal
        )
      }
      if Task.isCancelled { return }
      switch terminal {
      case .completed:
        try database.completeLocalACPRun(runID: run.runID)
      case .cancelled:
        try database.cancelLocalACPRun(runID: run.runID)
      case .failed(let message):
        try database.completeLocalACPRun(runID: run.runID, error: message)
      }
      await publishUpdate(runID: run.runID, phase: .terminal)
    } catch {
      if Task.isCancelled { return } // App shutdown does not cancel Gateway-owned execution.
      if Self.isRecoverableDeliveryError(error), let conversationID = activeRuns[run.runID]?.conversationID {
        await observeRecoveredRun(run: run, conversationID: conversationID)
        return
      }
      if activeRuns[run.runID]?.cancelRequested == true {
        try? database.cancelLocalACPRun(runID: run.runID)
      } else {
        try? database.completeLocalACPRun(
          runID: run.runID,
          error: error.localizedDescription
        )
      }
      await publishUpdate(runID: run.runID, phase: .terminal)
      throw error
    }
  }

  static func gatewayAttachments(
    _ files: [AgentFileAttachmentDraft],
    policy: OpenClawGatewayCapabilities.AttachmentPolicy?
  ) throws -> [GatewayJSONValue] {
    try files.map { file in
      let data: Data
      do {
        data = try Data(contentsOf: file.localURL, options: [.mappedIfSafe])
      } catch {
        throw AgentMessageAttachmentError.unreadableFile(file.fileName)
      }
      let limit = file.kind == .image
        ? policy?.maximumImageBytes ?? policy?.maximumBytes
        : policy?.maximumBytes
      if let limit, data.count > limit {
        throw AgentMessageAttachmentError.unsupportedForAgent(
          "\(file.fileName) exceeds this OpenClaw Gateway's \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) attachment limit."
        )
      }
      return .object([
        "type": .string(file.kind.rawValue),
        "mimeType": .string(file.mimeType),
        "fileName": .string(file.fileName),
        "content": .string(data.base64EncodedString()),
      ])
    }
  }

  static func isRecoverableDeliveryError(_ error: any Error) -> Bool {
    if let error = error as? OpenClawGatewayClientError {
      switch error {
      case .connectionClosed, .requestTimedOut, .unavailable, .malformedFrame: return true
      default: return false
      }
    }
    return isRetryableWaitError(error)
  }

  static func chatSendParameters(
    sessionKey: String,
    content: String,
    runID: String,
    attachments: [GatewayJSONValue]
  ) -> [String: GatewayJSONValue] {
    var parameters: [String: GatewayJSONValue] = [
      "sessionKey": .string(sessionKey),
      "message": .string(content),
      "deliver": .bool(false),
      "idempotencyKey": .string(runID),
    ]
    if !attachments.isEmpty {
      parameters["attachments"] = .array(attachments)
    }
    return parameters
  }

  private static func validateGatewayPayload(
    maximumBytes: Int?,
    sessionKey: String,
    content: String,
    attachments: [GatewayJSONValue]
  ) throws {
    guard let maximumBytes else { return }
    let placeholderID = UUID().uuidString.lowercased()
    let frame = GatewayJSONValue.object([
      "type": .string("req"),
      "id": .string(placeholderID),
      "method": .string("chat.send"),
      "params": .object(chatSendParameters(
        sessionKey: sessionKey,
        content: content,
        runID: placeholderID,
        attachments: attachments
      )),
    ])
    let byteCount = try JSONEncoder().encode(frame).count
    guard byteCount <= maximumBytes else {
      throw AgentMessageAttachmentError.unsupportedForAgent(
        "The message and attachments exceed this OpenClaw Gateway's \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)) payload limit."
      )
    }
  }

  public func cancel(conversationID: String) async throws {
    guard let active = activeRuns.values.first(where: {
      $0.conversationID == conversationID
    }) else {
      let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
      _ = try await client(agentID: descriptor.agentID).request("sessions.abort", params: .object([
        "key": .string(descriptor.sessionKey), "clearQueued": .bool(true)
      ]))
      _ = try await synchronizeSession(conversationID: conversationID)
      return
    }
    let client = try await client(agentID: active.agentID)
    var accepted = false
    var lastError: (any Error)?
    for remoteRunID in active.remoteRunIDs {
      do {
        let receipt = try await client.request("chat.abort", params: .object([
          "sessionKey": .string(active.sessionKey),
          "runId": .string(remoteRunID),
        ]))
        accepted = accepted || Self.cancellationWasAccepted(receipt)
      } catch {
        lastError = error
      }
    }
    guard accepted else {
      if let lastError { throw lastError }
      throw OpenClawGatewayClientError.rejected("the run was not aborted")
    }
    guard var current = activeRuns[active.runID] else { return }
    current.cancelRequested = true
    activeRuns[active.runID] = current
  }

  @discardableResult
  public func sendActiveInput(
    conversationID: String,
    content: String,
    deliveryContent: String? = nil
  ) async throws -> LocalACPSteeringIdentifiers {
    try await sendActiveInput(
      conversationID: conversationID,
      input: AgentMessageInput(text: content),
      deliveryContent: deliveryContent
    )
  }

  @discardableResult
  public func sendActiveInput(
    conversationID: String,
    input: AgentMessageInput,
    deliveryContent: String? = nil
  ) async throws -> LocalACPSteeringIdentifiers {
    await acquireSteeringLock(conversationID: conversationID)
    defer { releaseSteeringLock(conversationID: conversationID) }
    guard runExecutor == nil else {
      throw LocalACPSessionDatabaseError.steeringUnsupported
    }
    guard let active = activeRuns.values.first(where: {
      $0.conversationID == conversationID
    }), await waitUntilPromptReady(runID: active.runID) else {
      throw LocalACPSessionDatabaseError.steeringUnsupported
    }
    let gatewayClient = try await client(agentID: active.agentID)
    let capabilities = try await gatewayClient.connect()
    let attachments = try Self.gatewayAttachments(
      input.files,
      policy: capabilities.attachmentPolicy
    )
    let transportContent = input.transportText(deliveryText: deliveryContent)
    try Self.validateGatewayPayload(
      maximumBytes: capabilities.maximumPayloadBytes,
      sessionKey: active.sessionKey,
      content: transportContent,
      attachments: attachments
    )
    pausedGatewayEventRunIDs.insert(active.runID)
    let identifiers: LocalACPSteeringIdentifiers
    do {
      identifiers = try database.beginLocalACPSteeringTurn(
        runID: active.runID,
        input: input,
        completesPreviousAssistant: false
      )
    } catch {
      await resumeGatewayEvents(runID: active.runID)
      throw error
    }
    let provisionalRemoteRunID = identifiers.userMessageID
    guard var current = activeRuns[active.runID] else {
      await resumeGatewayEvents(runID: active.runID)
      throw LocalACPSessionDatabaseError.steeringUnsupported
    }
    current.remoteRunIDs.insert(provisionalRemoteRunID)
    current.lastRemoteRunID = provisionalRemoteRunID
    current.assistantMessageIDsByRemoteRunID[provisionalRemoteRunID] =
      identifiers.assistantMessageID
    activeRuns[active.runID] = current
    let task = Task { [self] in
      try await dispatchActiveInput(
        localRunID: active.runID,
        provisionalRemoteRunID: provisionalRemoteRunID,
        agentID: active.agentID,
        sessionKey: active.sessionKey,
        content: transportContent,
        attachments: attachments
      )
    }
    activeInputTasksByRunID[active.runID, default: []].append(ActiveInputTask(
      remoteRunID: provisionalRemoteRunID,
      assistantMessageID: identifiers.assistantMessageID,
      task: task
    ))
    publishChange(runID: active.runID, phase: .content)
    await resumeGatewayEvents(runID: active.runID)
    return identifiers
  }

  private func drainActiveInputs(
    runID: String,
    conversationID: String,
    initialTerminal: OpenClawGatewayEventProjection.TerminalState
  ) async throws -> OpenClawGatewayEventProjection.TerminalState {
    var terminal = initialTerminal
    activeRuns[runID]?.terminalStatesByRemoteRunID[runID] = initialTerminal
    while true {
      await acquireSteeringLock(conversationID: conversationID)
      let tasks = activeInputTasksByRunID.removeValue(forKey: runID) ?? []
      if tasks.isEmpty {
        promptReadyRunIDs.remove(runID)
        releaseSteeringLock(conversationID: conversationID)
        return terminal
      }
      releaseSteeringLock(conversationID: conversationID)
      for tracked in tasks {
        let resolved: OpenClawGatewayEventProjection.TerminalState
        do {
          resolved = try await tracked.task.value
        } catch {
          // Steering is a send too: a lost receipt is not proof of failure.
          // Let the owning run switch to observation, without resending input.
          if Task.isCancelled || Self.isRecoverableDeliveryError(error) { throw error }
          resolved = .failed(error.localizedDescription)
        }
        terminal = resolved
        let remoteRunID = activeRuns[runID]?.assistantMessageIDsByRemoteRunID
          .first(where: { $0.value == tracked.assistantMessageID })?.key
          ?? tracked.remoteRunID
        activeRuns[runID]?.terminalStatesByRemoteRunID[remoteRunID] = resolved
      }
    }
  }

  private func dispatchActiveInput(
    localRunID: String,
    provisionalRemoteRunID: String,
    agentID: UUID,
    sessionKey: String,
    content: String,
    attachments: [GatewayJSONValue]
  ) async throws -> OpenClawGatewayEventProjection.TerminalState {
    let receipt = try await client(agentID: agentID).request(
      "chat.send",
      params: .object(Self.chatSendParameters(
        sessionKey: sessionKey,
        content: content,
        runID: provisionalRemoteRunID,
        attachments: attachments
      ))
    )
    // Gateway v4 acknowledges the supplied idempotency key, just as it does
    // for the first input. Never attach a different run's output to this row.
    guard let remoteRunID = receipt.objectValue?["runId"]?.stringValue,
          remoteRunID == provisionalRemoteRunID else {
      throw OpenClawGatewayClientError.malformedFrame
    }
    return try await waitForRun(
      localRunID: localRunID,
      remoteRunID: remoteRunID,
      agentID: agentID
    )
  }

  private func acquireSteeringLock(conversationID: String) async {
    guard steeringLocks.insert(conversationID).inserted == false else {
      return
    }
    await withCheckedContinuation { continuation in
      steeringWaiters[conversationID, default: []].append(continuation)
    }
  }

  private func releaseSteeringLock(conversationID: String) {
    guard var waiters = steeringWaiters[conversationID],
          !waiters.isEmpty else {
      steeringLocks.remove(conversationID)
      return
    }
    let continuation = waiters.removeFirst()
    if waiters.isEmpty {
      steeringWaiters.removeValue(forKey: conversationID)
    } else {
      steeringWaiters[conversationID] = waiters
    }
    continuation.resume()
  }

  private func waitUntilPromptReady(runID: String) async -> Bool {
    if promptReadyRunIDs.contains(runID) { return true }
    guard activeRuns[runID] != nil else { return false }
    return await withCheckedContinuation { continuation in
      promptReadyWaiters[runID, default: []].append(continuation)
    }
  }

  private func markPromptReady(runID: String) {
    promptReadyRunIDs.insert(runID)
    let waiters = promptReadyWaiters.removeValue(forKey: runID) ?? []
    for waiter in waiters { waiter.resume(returning: true) }
  }

  static func cancellationWasAccepted(_ receipt: GatewayJSONValue) -> Bool {
    receipt.objectValue?["aborted"]?.boolValue == true
  }

  private func handleGatewayEvent(
    _ event: OpenClawGatewayEvent,
    agentID: UUID,
    generation: UUID
  ) async {
    guard isCurrentConnection(agentID, generation: generation) else { return }
    if ["sessions.changed", "session.message"].contains(event.name)
      || (event.name == "chat" && ["final", "error", "aborted"].contains(event.payload?.objectValue?["state"]?.stringValue ?? "")) {
      let key = event.payload?.objectValue?["sessionKey"]?.stringValue
        ?? event.payload?.objectValue?["key"]?.stringValue
      for session in (try? database.openClawGatewaySessions(agentID: agentID)) ?? []
      where key == nil || session.sessionKey == key {
        scheduleHistoryRefresh(conversationID: session.conversationID, agentID: agentID, generation: generation)
      }
    }
    guard let projection = OpenClawGatewayEventProjection.project(event),
          let runID = activeRunID(for: projection, agentID: agentID),
          var active = activeRuns[runID] else { return }
    if pausedGatewayEventRunIDs.contains(runID) {
      bufferedGatewayEventsByRunID[runID, default: []].append((event, agentID, generation))
      return
    }
    let remoteRunID = projection.runID ?? active.lastRemoteRunID
    switch active.eventFence.evaluate(
      event, remoteRunID: remoteRunID
    ) {
    case .duplicate:
      return
    case .accept:
      break
    }
    let sequence: Int
    if let projectedSequence = projection.sequence {
      sequence = projectedSequence
      active.fallbackSequence = max(active.fallbackSequence, projectedSequence)
    } else {
      active.fallbackSequence += 1
      sequence = active.fallbackSequence
    }
    let assistantMessageID = active.assistantMessageIDsByRemoteRunID[remoteRunID]
    var acceptedAssistantUpdate: OpenClawGatewayEventProjection.AssistantUpdate?
    if let update = projection.assistantUpdate,
       active.assistantSource.accepts(
         event, runID: remoteRunID, update: update,
         terminal: projection.terminalState != nil
       ) {
      acceptedAssistantUpdate = update
    }
    let assistantMutation: WorkspaceDatabase.DeviceOwnedAssistantMutation? = switch acceptedAssistantUpdate {
    case .append(let chunk): .append(chunk)
    case .replace(let content): .replace(content)
    case nil: nil
    }
    let activity = projection.activity.map {
      projection.approval == nil ? $0.scoped(to: remoteRunID) : $0
    }
    guard let raw = Self.rawEventJSON(event) else { return }
    let application: WorkspaceDatabase.DeviceOwnedGatewayProjectionResult
    do {
      application = try database.applyDeviceOwnedGatewayProjection(
        runID: runID, remoteRunID: remoteRunID, eventName: event.name,
        eventStream: event.payload?.objectValue?["stream"]?.stringValue
          ?? (event.name == "session.tool" ? "tool" : nil),
        sequence: sequence,
        eventType: projection.eventType, eventPhase: projection.eventPhase,
        toolName: projection.toolName, content: projection.content,
        rawEventJSON: raw, assistantMessageID: assistantMessageID,
        assistantMutation: assistantMutation,
        streamBoundary: activity != nil,
        finalAssistantSegment: projection.terminalState != nil && acceptedAssistantUpdate != nil,
        activity: activity, appendingActivity: activity?.contentIsDelta == true
      )
    } catch {
      scheduleHistoryRefresh(conversationID: active.conversationID, agentID: agentID,
        generation: generation)
      return
    }
    switch application {
    case .applied:
      break
    case .duplicate:
      return
    case .legacyUncertain:
      scheduleHistoryRefresh(conversationID: active.conversationID, agentID: agentID,
        generation: generation)
      return
    }
    if let activity {
      if activity.kind == .tool,
         projection.eventType == "tool_call" || projection.eventType == "tool_result" {
        active.liveToolCallIDs.insert(activity.id)
      }
    }
    if let terminal = projection.terminalState {
      active.assistantSource.finish(runID: remoteRunID)
      active.terminalStatesByRemoteRunID[remoteRunID] = terminal
    }
    if let approval = projection.approval {
      if approval.resolvedDecision != nil {
        approvalTasks[approval.id]?.cancel()
      } else if approvalTasks[approval.id] == nil,
                let approvalClient = clients[agentID],
                let transportGeneration = await approvalClient.connectedGeneration,
                isCurrentConnection(agentID, generation: generation) {
        approvalRunIDs[approval.id] = runID
        approvalTasks[approval.id] = Task {
          await self.relayApproval(approval, runID: runID, client: approvalClient,
            generation: generation, transportGeneration: transportGeneration)
        }
      }
    }
    let reachedBoundary = projection.activity != nil
      || projection.terminalState != nil
      || projection.approval != nil
    activeRuns[runID] = active
    if reachedBoundary {
      contentPublicationTasks.removeValue(forKey: runID)?.cancel()
      await publishUpdate(runID: runID, phase: .content)
    } else if projection.assistantUpdate != nil {
      scheduleContentPublication(runID: runID)
    }
  }

#if DEBUG
  func receiveGatewayEventForTesting(
    _ event: OpenClawGatewayEvent,
    agentID: UUID
  ) async {
    let generation = connectionGenerations[agentID] ?? UUID()
    connectionGenerations[agentID] = generation
    await handleGatewayEvent(event, agentID: agentID, generation: generation)
  }
#endif

  private func scheduleContentPublication(runID: String) {
    guard contentPublicationTasks[runID] == nil else { return }
    contentPublicationTasks[runID] = Task { [weak self] in
      try? await Task.sleep(for: Self.contentPublicationDelay)
      guard !Task.isCancelled else { return }
      await self?.publishScheduledContent(runID: runID)
    }
  }

  private func publishScheduledContent(runID: String) async {
    contentPublicationTasks.removeValue(forKey: runID)
    await publishUpdate(runID: runID, phase: .content)
  }

  private func resumeGatewayEvents(runID: String) async {
    pausedGatewayEventRunIDs.remove(runID)
    let buffered = bufferedGatewayEventsByRunID.removeValue(forKey: runID) ?? []
    for (event, agentID, generation) in buffered {
      await handleGatewayEvent(event, agentID: agentID, generation: generation)
    }
  }

  private func activeRunID(
    for projection: OpenClawGatewayEventProjection,
    agentID: UUID
  ) -> String? {
    if let approvalID = projection.approval?.id,
       let runID = approvalRunIDs[approvalID],
       activeRuns[runID]?.agentID == agentID {
      return runID
    }
    if let remoteRunID = projection.runID {
      if activeRuns[remoteRunID]?.agentID == agentID {
        return remoteRunID
      }
      if let localRunID = activeRuns.first(where: {
        $0.value.agentID == agentID
          && $0.value.remoteRunIDs.contains(remoteRunID)
      })?.key {
        return localRunID
      }
    }
    guard let sessionKey = projection.sessionKey else { return nil }
    return activeRuns.values.first(where: {
      $0.agentID == agentID && $0.sessionKey == sessionKey
    })?.runID
  }

  private func relayApproval(
    _ approval: OpenClawGatewayEventProjection.Approval,
    runID: String,
    client: OpenClawGatewayClient,
    generation: UUID,
    transportGeneration: UUID
  ) async {
    defer {
      approvalTasks.removeValue(forKey: approval.id)
      approvalRunIDs.removeValue(forKey: approval.id)
    }
    guard let active = activeRuns[runID],
          let handler = active.onPermission,
          isCurrentConnection(active.agentID, generation: generation) else {
      // A recovered run may not own a live permission presenter. Leave the
      // request pending for the Gateway approval inbox, never implicitly deny it.
      return
    }
    let details: GatewayJSONValue? = if approval.kind == "exec" {
      try? await client.request(
        "exec.approval.get",
        params: .object(["id": .string(approval.id)]),
        expectedConnectionGeneration: transportGeneration
      )
    } else {
      nil
    }
    let request = details?.objectValue ?? [:]
    let command = request["commandText"]?.stringValue
      ?? request["commandPreview"]?.stringValue
      ?? approval.command
    let allowed = request["allowedDecisions"]?.arrayValue?.compactMap(\.stringValue)
      ?? approval.allowedDecisions
    let decisions = allowed.isEmpty ? ["allow-once", "deny"] : allowed
    let options = decisions.compactMap(Self.permissionOption)
    let title = [approval.title, command].compactMap { value in
      value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }.joined(separator: "\n")
    let selection = await handler(LocalACPPermissionRequest(
      title: title,
      options: options
    ))
    guard !Task.isCancelled, isCurrentConnection(active.agentID, generation: generation),
          let decision = selection, decisions.contains(decision) else { return }
    await resolveApproval(approval, decision: decision, runID: runID,
      client: client, transportGeneration: transportGeneration)
  }

  private func resolveApproval(
    _ approval: OpenClawGatewayEventProjection.Approval,
    decision: String,
    runID: String,
    client: OpenClawGatewayClient,
    transportGeneration: UUID
  ) async {
    guard activeRuns[runID] != nil else { return }
    do {
      _ = try await client.request(Self.approvalResolveMethod(kind: approval.kind), params: .object([
        "id": .string(approval.id), "decision": .string(decision)
      ]), expectedConnectionGeneration: transportGeneration)
    } catch {
      guard !Task.isCancelled else { return }
      let message = error.localizedDescription
      try? database.upsertDeviceOwnedRunActivity(
        runID: runID,
        activity: AgentRunActivity(
          id: "approval:\(approval.id)",
          kind: .tool,
          phase: "result",
          title: "Approval response failed",
          status: "failed",
          toolName: approval.kind,
          content: message,
          rawOutputJSON: Self.json(.object(["error": .string(message)]))
        )
      )
      await publishUpdate(runID: runID, phase: .content)
      return
    }
    let approvalNoun = approval.kind == "plugin" ? "Plugin" : "Command"
    try? database.upsertDeviceOwnedRunActivity(
      runID: runID,
      activity: AgentRunActivity(
        id: "approval:\(approval.id)",
        kind: .tool,
        phase: "result",
        title: decision == "deny" ? "\(approvalNoun) denied" : "\(approvalNoun) approved",
        status: decision == "deny" ? "failed" : "completed",
        toolName: approval.kind,
        rawOutputJSON: "{\"decision\":\"\(decision)\"}"
      )
    )
    await publishUpdate(runID: runID, phase: .content)
  }

  private static func permissionOption(_ decision: String) -> LocalACPPermissionOption? {
    switch decision {
    case "allow-once":
      LocalACPPermissionOption(id: decision, name: "Allow once", kind: "allow_once")
    case "allow-always":
      LocalACPPermissionOption(id: decision, name: "Always allow", kind: "allow_always")
    case "deny":
      LocalACPPermissionOption(id: decision, name: "Deny", kind: "reject_once")
    default:
      nil
    }
  }

  static func approvalResolveMethod(kind: String) -> String {
    kind + ".approval.resolve"
  }

  private func waitForRun(
    localRunID: String,
    remoteRunID: String,
    agentID: UUID
  ) async throws -> OpenClawGatewayEventProjection.TerminalState {
    // Each request is bounded so a dropped WebSocket can reconnect and resume
    // the same idempotent remote run without losing its local transcript.
    for _ in 0..<60 {
      try Task.checkCancellation()
      if let terminal = activeRuns[localRunID]?
        .terminalStatesByRemoteRunID[remoteRunID] { return terminal }
      if activeRuns[localRunID]?.cancelRequested == true {
        return .cancelled(nil)
      }
      do {
        let value = try await client(agentID: agentID).request(
          "agent.wait",
          params: .object([
            "runId": .string(remoteRunID),
            "timeoutMs": .number(30_000),
          ]),
          timeout: .seconds(35)
        )
        let object = value.objectValue ?? [:]
        switch object["status"]?.stringValue {
        case "error":
          return .failed(
            object["error"]?.stringValue ?? "OpenClaw Gateway run failed."
          )
        case "aborted", "cancelled", "canceled":
          return .cancelled(object["error"]?.stringValue)
        case "timeout", "pending":
          continue
        case "ok", "completed":
          return activeRuns[localRunID]?
            .terminalStatesByRemoteRunID[remoteRunID] ?? .completed
        default:
          throw OpenClawGatewayClientError.malformedFrame
        }
      } catch let error as OpenClawGatewayClientError {
        switch error {
        case .connectionClosed, .requestTimedOut:
          try await Task.sleep(for: .milliseconds(250))
          continue
        default:
          throw error
        }
      } catch {
        guard Self.isRetryableWaitError(error) else { throw error }
        try await Task.sleep(for: .milliseconds(250))
      }
    }
    throw OpenClawGatewayClientError.requestTimedOut("agent.wait")
  }

  static func isRetryableWaitError(_ error: any Error) -> Bool {
    if error is CancellationError { return false }
    if error is URLError { return true }
    let cocoaError = error as NSError
    return cocoaError.domain == NSURLErrorDomain
      || cocoaError.domain == NSPOSIXErrorDomain
  }

  private func reconcileAssistantHistory(
    runID: String,
    assistantMessageID: String,
    remoteRunID: String,
    sessionKey: String,
    agentID: UUID
  ) async {
    let generation = connectionGenerations[agentID]
    let assistantIDs = (try? database.openClawRunAssistantIDs(runID: runID)) ?? [:]
    let knownInputIDs = Set(assistantIDs.keys)
    if let response = await GatewayHistoryRecovery.assistantMessage(
      remoteRunID: remoteRunID,
      knownInputIDs: knownInputIDs,
      fetch: {
        let socket = try await self.client(agentID: agentID)
        _ = try await socket.connect()
        guard let transportGeneration = await socket.connectedGeneration else { throw CancellationError() }
        let payload = try await socket.request("chat.history", params: .object([
          "sessionKey": .string(sessionKey), "limit": .number(50), "maxChars": .number(500_000)
        ]), timeout: .seconds(5), expectedConnectionGeneration: transportGeneration)
        return try await OpenClawGatewayHistoryHydration.hydrate(payload) { messageID in
          try await socket.request("chat.message.get", params: .object([
            "sessionKey": .string(sessionKey), "messageId": .string(messageID), "maxChars": .number(500_000)
          ]), timeout: .seconds(5), expectedConnectionGeneration: transportGeneration)
        }
      }
    ) {
      guard !Task.isCancelled, generation == connectionGenerations[agentID] else { return }
      try? database.replaceLocalACPAssistantMessage(
        runID: runID,
        assistantMessageID: assistantMessageID,
        content: response.text,
        preservingStreamCommentary: response.isFinalOnlyAssistantTranscript
      )
    }
  }

  private func completeAssistantSegment(
    runID: String,
    assistantMessageID: String,
    terminal: OpenClawGatewayEventProjection.TerminalState
  ) {
    switch terminal {
    case .completed:
      try? database.completeLocalACPAssistantMessage(
        runID: runID,
        assistantMessageID: assistantMessageID
      )
    case .cancelled(let message):
      try? database.completeLocalACPAssistantMessage(
        runID: runID,
        assistantMessageID: assistantMessageID,
        error: message ?? "The OpenClaw Gateway run was cancelled."
      )
    case .failed(let message):
      try? database.completeLocalACPAssistantMessage(
        runID: runID,
        assistantMessageID: assistantMessageID,
        error: message
      )
    }
  }

  private func reconcileAudit(
    runID: String,
    remoteRunID: String,
    agentID: UUID
  ) async {
    guard let client = try? await client(agentID: agentID),
          let result = try? await client.request(
            "audit.list",
            params: .object([
              "runId": .string(remoteRunID),
              "limit": .number(500),
            ]),
            timeout: .seconds(10)
          ) else { return }
    let events = (result.objectValue?["events"]?.arrayValue ?? []).sorted {
      ($0.objectValue?["sequence"]?.intValue ?? 0)
        < ($1.objectValue?["sequence"]?.intValue ?? 0)
    }
    let liveToolCallIDs = activeRuns[runID]?.liveToolCallIDs ?? []
    var recoveredActivity = false
    for value in events {
      guard let event = value.objectValue,
            event["kind"]?.stringValue == "tool_action",
            let toolCallID = event["toolCallId"]?.stringValue else { continue }
      let action = event["action"]?.stringValue
      let status = event["status"]?.stringValue ?? "unknown"
      let phase = action == "tool.action.started" ? "start" : "result"
      let normalizedStatus: String = switch status {
      case "started": "running"
      case "succeeded": "completed"
      case "failed", "blocked", "timed_out", "cancelled": "failed"
      default: status
      }
      let toolName = event["toolName"]?.stringValue ?? "tool"
      guard !liveToolCallIDs.contains(toolCallID) else { continue }
      try? database.upsertDeviceOwnedRunActivity(
        runID: runID,
        activity: AgentRunActivity(
          id: toolCallID,
          kind: .tool,
          phase: phase,
          title: OpenClawGatewayEventProjection.toolTitle(
            name: toolName
          ),
          status: normalizedStatus,
          toolName: toolName
        )
      )
      recoveredActivity = true
      if let sequence = event["sequence"]?.intValue,
         let raw = Self.json(value) {
        try? database.appendDeviceOwnedGatewayTraceEvent(
          runID: runID,
          eventName: "audit",
          sequence: sequence,
          eventType: phase == "start" ? "tool_call" : "tool_result",
          eventPhase: phase,
          toolName: toolName,
          content: nil,
          rawEventJSON: raw
        )
      }
    }
    if recoveredActivity {
      await publishUpdate(runID: runID, phase: .content)
    }
  }

  private func publishUpdate(
    runID: String,
    phase: DashboardConversationChange.Phase
  ) async {
    guard let active = activeRuns[runID] else { return }
    publishChange(runID: runID, phase: phase)
    await active.onUpdate?(active.conversationID)
  }

  private func finishTracking(runID: String) {
    runTasks.removeValue(forKey: runID)
    contentPublicationTasks.removeValue(forKey: runID)?.cancel()
    let activeInputs = activeInputTasksByRunID.removeValue(forKey: runID) ?? []
    for input in activeInputs { input.task.cancel() }
    let approvalIDs = approvalRunIDs.compactMap { id, ownerRunID in
      ownerRunID == runID ? id : nil
    }
    for id in approvalIDs {
      approvalTasks.removeValue(forKey: id)?.cancel()
      approvalRunIDs.removeValue(forKey: id)
    }
    promptReadyRunIDs.remove(runID)
    pausedGatewayEventRunIDs.remove(runID)
    bufferedGatewayEventsByRunID.removeValue(forKey: runID)
    let readinessWaiters = promptReadyWaiters.removeValue(forKey: runID) ?? []
    for waiter in readinessWaiters { waiter.resume(returning: false) }
    activeRuns.removeValue(forKey: runID)
  }

  private func publishChange(
    runID: String,
    phase: DashboardConversationChange.Phase
  ) {
    guard let active = activeRuns[runID] else { return }
    onChange?(DashboardConversationChange(
      conversationID: active.conversationID,
      runID: runID,
      phase: phase
    ))
  }

  private static func rawEventJSON(_ event: OpenClawGatewayEvent) -> String? {
    var object: [String: GatewayJSONValue] = ["event": .string(event.name)]
    if let sequence = event.sequence { object["seq"] = .number(Double(sequence)) }
    if let payload = event.payload { object["payload"] = payload }
    guard let data = try? JSONEncoder().encode(GatewayJSONValue.object(object)) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private func hydrateGatewayStreamingState(
    runID: String,
    active: inout ActiveRun
  ) throws {
    for trace in try database.deviceOwnedGatewayTraceEvents(runID: runID) {
      active.fallbackSequence = max(active.fallbackSequence, trace.sequence)
      guard let data = trace.rawEventJSON.data(using: .utf8),
            let value = try? JSONDecoder().decode(GatewayJSONValue.self, from: data),
            let row = value.objectValue,
            let name = row["event"]?.stringValue else { continue }
      let event = OpenClawGatewayEvent(
        name: name, payload: row["payload"], sequence: row["seq"]?.intValue
      )
      guard let projection = OpenClawGatewayEventProjection.project(event) else { continue }
      let remoteRunID = projection.runID ?? active.lastRemoteRunID
      _ = active.eventFence.evaluate(event, remoteRunID: remoteRunID)
      if let update = projection.assistantUpdate {
        _ = active.assistantSource.accepts(
          event, runID: remoteRunID, update: update,
          terminal: projection.terminalState != nil
        )
      }
      if projection.terminalState != nil {
        active.assistantSource.finish(runID: remoteRunID)
      }
    }
  }

  private static func json(_ value: GatewayJSONValue) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func sessionPreferences(
    conversationID: String
  ) async throws -> OpenClawSessionPreferences {
    let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
    let value = try await client(agentID: descriptor.agentID)
      .sessionPreferences(key: descriptor.sessionKey)
    try database.updateOpenClawGatewaySessionPreferences(
      conversationID: conversationID,
      preferences: value
    )
    return value
  }

  public func patchSession(
    conversationID: String,
    preferences: OpenClawSessionPreferences
  ) async throws -> OpenClawSessionPreferences {
    let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
    let value = try await client(agentID: descriptor.agentID).patchSession(
      key: descriptor.sessionKey,
      preferences: preferences
    )
    try database.updateOpenClawGatewaySessionPreferences(
      conversationID: conversationID,
      preferences: value
    )
    return value
  }

  @discardableResult
  public func refreshStatus(agentID: UUID) async throws -> OpenClawGatewayLink {
    do {
      let client = try await client(agentID: agentID)
      _ = try await client.request("health", timeout: .seconds(5))
      try setLinkStatus(agentID: agentID, status: .ready, error: nil)
      return try linkedGateway(agentID: agentID)
    } catch {
      try? setLinkStatus(
        agentID: agentID,
        status: .unavailable,
        error: error.localizedDescription
      )
      throw error
    }
  }

  public func sessionMetadata(conversationID: String) async throws -> LocalACPSessionMetadata {
    let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
    let client = try await client(agentID: descriptor.agentID)
    let description = try await client.request(
      "sessions.describe", params: .object(["key": .string(descriptor.sessionKey)])
    )
    let session = description.objectValue?["session"]?.objectValue ?? [:]
    let rawModel = session["model"]?.stringValue
    let provider = session["modelProvider"]?.stringValue
    let selectedModel = rawModel.map { model in
      model.contains("/") || provider?.isEmpty != false ? model : provider! + "/" + model
    }
    let agentID = OpenClawGatewaySession.agentID(for: descriptor.sessionKey)
    var modelParams = Self.modelsListParameters.objectValue ?? [:]
    modelParams["sessionKey"] = .string(descriptor.sessionKey)
    modelParams["includeDetails"] = .bool(true)
    if let agentID { modelParams["agentId"] = .string(agentID) }
    let catalog = try await client.request("models.list", params: .object(modelParams))
    let choices = catalog.objectValue?["models"]?.arrayValue ?? []
    var configuredModels: [String] = []
    var seenModels: Set<String> = []
    var modelOptionMetadata: [String: SessionOptionMetadata] = [:]
    for choice in choices {
      guard let reference = Self.modelReference(choice),
            seenModels.insert(reference).inserted else { continue }
      configuredModels.append(reference)
      let object = choice.objectValue ?? [:]
      let name = object["name"]?.stringValue ?? object["alias"]?.stringValue
      let description = object["description"]?.stringValue
      if name != nil || description != nil {
        modelOptionMetadata[reference] = SessionOptionMetadata(
          name: name, description: description
        )
      }
    }
    let selected = choices.first { Self.modelReference($0) == selectedModel }?.objectValue
    // A present empty array is authoritative: the selected model has no selectable
    // levels. Older/prepared catalog rows can omit the field, while the session row
    // still carries the exact session-model projection.
    let levelValues = selected?["thinkingLevels"] != nil
      ? selected?["thinkingLevels"]?.arrayValue ?? []
      : session["thinkingLevels"]?.arrayValue ?? []
    var thinking: [String] = []
    var seenThinking: Set<String> = []
    var thinkingOptionMetadata: [String: SessionOptionMetadata] = [:]
    for level in levelValues {
      let object = level.objectValue
      guard let id = level.stringValue ?? object?["id"]?.stringValue,
            !id.isEmpty, seenThinking.insert(id).inserted else { continue }
      thinking.append(id)
      let name = object?["label"]?.stringValue ?? object?["name"]?.stringValue
      let description = object?["description"]?.stringValue
      if name != nil || description != nil {
        thinkingOptionMetadata[id] = SessionOptionMetadata(
          name: name, description: description
        )
      }
    }
    let commands = await Self.slashCommands(client: client, agentID: agentID, sessionKey: descriptor.sessionKey)
    return LocalACPSessionMetadata(
      sessionKey: descriptor.sessionKey,
      model: selectedModel,
      thinking: session["thinkingLevel"]?.stringValue,
      modelOptions: configuredModels,
      thinkingLevels: thinking,
      slashCommands: commands,
      modelOptionMetadata: modelOptionMetadata,
      thinkingOptionMetadata: thinkingOptionMetadata
    )
  }

  public func heartbeatConfiguration(
    agentID: UUID
  ) async throws -> OpenClawHeartbeatConfiguration {
    let value = try await client(agentID: agentID).request("config.get")
    return Self.heartbeatConfiguration(from: value)
  }

  public func updateHeartbeat(
    agentID: UUID,
    configuration: OpenClawHeartbeatConfiguration
  ) async throws -> OpenClawHeartbeatConfiguration {
    let interval = configuration.interval.trimmingCharacters(in: .whitespacesAndNewlines)
    let activeFrom = configuration.activeFrom.trimmingCharacters(in: .whitespacesAndNewlines)
    let activeUntil = configuration.activeUntil.trimmingCharacters(in: .whitespacesAndNewlines)
    let timezone = configuration.timezone.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !interval.isEmpty, !activeFrom.isEmpty, !activeUntil.isEmpty, !timezone.isEmpty else {
      throw OpenClawGatewayClientError.rejected(
        "Heartbeat interval, active hours, and timezone are required."
      )
    }
    let client = try await client(agentID: agentID)
    let snapshot = try await client.request("config.get")
    guard let hash = snapshot.objectValue?["hash"]?.stringValue else {
      throw OpenClawGatewayClientError.rejected(
        "config.get did not return the base hash required for a safe heartbeat update."
      )
    }
    let requested = OpenClawHeartbeatConfiguration(
      isEnabled: configuration.isEnabled,
      interval: interval,
      activeFrom: activeFrom,
      activeUntil: activeUntil,
      timezone: timezone,
      prompt: configuration.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let patch: GatewayJSONValue = .object([
      "agents": .object([
        "defaults": .object([
          "heartbeat": .object([
            "every": .string(requested.isEnabled ? requested.interval : "0m"),
            "activeHours": .object([
              "start": .string(requested.activeFrom),
              "end": .string(requested.activeUntil),
              "timezone": .string(requested.timezone),
            ]),
            "prompt": .string(requested.prompt),
          ]),
        ]),
      ]),
    ])
    let rawData = try JSONEncoder().encode(patch)
    guard let raw = String(data: rawData, encoding: .utf8) else {
      throw OpenClawGatewayClientError.malformedFrame
    }
    _ = try await client.request("config.patch", params: .object([
      "raw": .string(raw),
      "baseHash": .string(hash),
      "restartDelayMs": .number(0),
      "note": .string("Woven Matter updated Heartbeat from Cron Jobs."),
    ]))
    let confirmed = try await heartbeatConfiguration(agentID: agentID)
    guard confirmed.isEnabled == requested.isEnabled,
          (!requested.isEnabled || confirmed.interval == requested.interval),
          confirmed.activeFrom == requested.activeFrom,
          confirmed.activeUntil == requested.activeUntil,
          confirmed.timezone == requested.timezone,
          confirmed.prompt == requested.prompt else {
      throw OpenClawGatewayClientError.rejected(
        "OpenClaw did not retain the requested Heartbeat configuration."
      )
    }
    return confirmed
  }

  static func heartbeatConfiguration(
    from response: GatewayJSONValue
  ) -> OpenClawHeartbeatConfiguration {
    let root = response.objectValue?["config"]?.objectValue ?? response.objectValue ?? [:]
    let defaults = root["agents"]?.objectValue?["defaults"]?.objectValue ?? [:]
    let heartbeat = defaults["heartbeat"]?.objectValue ?? [:]
    let every = heartbeat["every"]?.stringValue ?? "0m"
    let activeHours = heartbeat["activeHours"]?.objectValue ?? [:]
    return OpenClawHeartbeatConfiguration(
      isEnabled: every != "0m",
      interval: every == "0m" ? "30m" : every,
      activeFrom: activeHours["start"]?.stringValue ?? "09:00",
      activeUntil: activeHours["end"]?.stringValue ?? "17:00",
      timezone: activeHours["timezone"]?.stringValue
        ?? defaults["userTimezone"]?.stringValue
        ?? TimeZone.current.identifier,
      prompt: heartbeat["prompt"]?.stringValue ?? ""
    )
  }

  static func modelReference(_ choice: GatewayJSONValue) -> String? {
    guard let object = choice.objectValue,
          object["available"]?.boolValue != false,
          let id = object["id"]?.stringValue, !id.isEmpty else { return nil }
    if id.contains("/") { return id }
    guard let provider = object["provider"]?.stringValue, !provider.isEmpty else {
      return id
    }
    return "\(provider)/\(id)"
  }

  static func slashCommands(from result: GatewayJSONValue) -> [LocalACPSlashCommand] {
    let values = result.objectValue?["commands"]?.arrayValue ?? []
    var seen: Set<String> = []
    return values.compactMap { value in
      guard let object = value.objectValue else { return nil }
      let aliases = object["textAliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let rawName = aliases.first ?? object["name"]?.stringValue
      guard let rawName else { return nil }
      let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
      guard !name.isEmpty, seen.insert(name).inserted else { return nil }
      return LocalACPSlashCommand(
        name: name,
        detail: object["description"]?.stringValue,
        argumentHint: object["args"]?.arrayValue?.compactMap { value in
          guard let arg = value.objectValue, let name = arg["name"]?.stringValue else { return nil }
          return arg["required"]?.boolValue == true ? "<\(name)>" : "[\(name)]"
        }.joined(separator: " ")
      )
    }
  }

  private static func slashCommands(
    client: OpenClawGatewayClient,
    agentID: String?,
    sessionKey: String
  ) async -> [LocalACPSlashCommand] {
    var params: [String: GatewayJSONValue] = [
      "sessionKey": .string(sessionKey), "scope": .string("text"), "includeArgs": .bool(true)
    ]
    if let agentID { params["agentId"] = .string(agentID) }
    guard let result = try? await client.request(
      "commands.list",
      params: .object(params),
      timeout: .seconds(5)
    ) else { return [] }
    return slashCommands(from: result)
  }

  @discardableResult
  public func restart(agentID: UUID) async throws -> OpenClawGatewayLink {
    _ = try linkedGateway(agentID: agentID)
    let client = try await client(agentID: agentID)
    try setLinkStatus(agentID: agentID, status: .restarting, error: nil)
    do {
      _ = try await client.request(
        Self.nativeRestartMethod,
        params: Self.nativeRestartParameters
      )
      await disconnect(agentID: agentID)
      try await Task.sleep(for: .milliseconds(500))
      _ = try await reconnect(agentID: agentID, attempts: 40)
      return try await refreshStatus(agentID: agentID)
    } catch {
      try? setLinkStatus(
        agentID: agentID,
        status: .unavailable,
        error: error.localizedDescription
      )
      throw error
    }
  }

  public func createCron(agentID: UUID, name: String, message: String, expression: String,
                         timeZone: String, declarationKey: String, destination: String) async throws {
    let socket = try await client(agentID: agentID)
    // Do not create an always-on job on a host whose durable collector is absent.
    _ = try await socket.request("wovenmatter.results.list", params: .object([
      "consumer": .string(agentID.uuidString.lowercased()), "limit": .number(1)
    ]))
    let result = try await socket.request("cron.add", params: .object([
      "name": .string(name), "declarationKey": .string(declarationKey), "enabled": .bool(false),
      "schedule": .object(["kind": .string("cron"), "expr": .string(expression), "tz": .string(timeZone)]),
      "sessionTarget": .string("isolated"), "wakeMode": .string("now"),
      "payload": .object(["kind": .string("agentTurn"), "message": .string(message)]),
      "delivery": .object(["mode": .string("none")])
    ]))
    guard let id = result.objectValue?["job"]?.objectValue?["id"]?.stringValue ?? result.objectValue?["id"]?.stringValue else {
      throw OpenClawGatewayClientError.malformedFrame
    }
    // A newly created job cannot fire before its local destination is saved.
    try database.setOpenClawResultRoute(agentID: agentID, jobID: id, destination: destination)
    _ = try await socket.request("cron.update", params: .object([
      "id": .string(id), "patch": .object(["enabled": .bool(true)])
    ]))
  }

  public func updateCron(agentID: UUID, jobID: String, patch: GatewayJSONValue,
                         revision: String? = nil) async throws {
    let socket = try await client(agentID: agentID)
    var parameters: [String: GatewayJSONValue] = ["id": .string(jobID), "patch": patch]
    if let revision { parameters["expectedConfigRevision"] = .string(revision) }
    _ = try await socket.request("cron.update", params: .object(parameters))
  }

  public func performCronAction(agentID: UUID, jobID: String, action: String) async throws {
    guard ["run", "remove"].contains(action) else { throw OpenClawGatewayClientError.malformedFrame }
    let socket = try await client(agentID: agentID)
    _ = try await socket.request("cron." + action, params: .object(["id": .string(jobID)]))
  }

  public func syncCron(agentID: UUID) async throws {
    guard cronSyncAgents.insert(agentID).inserted else { return }
    defer { cronSyncAgents.remove(agentID) }
    let socket = try await client(agentID: agentID)
    let generation = connectionGenerations[agentID]
    let jobs = try await cronPages(socket: socket, method: "cron.list", field: "jobs", parameters: [
      "includeDisabled": .bool(true), "sortBy": .string("updatedAtMs"), "sortDir": .string("asc")
    ]).map { value -> OpenClawCronJob in
      guard let job = try Self.cronJob(agentID: agentID, value: value) else { throw OpenClawGatewayClientError.malformedFrame }
      return job
    }
    // Ascending pages and a fresh scan each time avoid a permanent high-water mark
    // skipping late completions or equal timestamps. Receipts provide deduplication.
    let runs = try await cronPages(socket: socket, method: "cron.runs", field: "entries", parameters: [
      "scope": .string("all"), "sortDir": .string("asc")
    ]).map { value -> OpenClawCronRun in
      guard let run = try Self.cronRun(agentID: agentID, value: value) else { throw OpenClawGatewayClientError.malformedFrame }
      return run
    }
    guard generation == connectionGenerations[agentID], !Task.isCancelled else { throw CancellationError() }
    try database.replaceOpenClawCronSnapshot(agentID: agentID, jobs: jobs, runs: runs)
    let routes = try database.openClawResultRoutes(agentID: agentID)
    var receipts: [String: Set<String>] = [:]
    var failure: (any Error)?
    do { try await collectRetainedResults(agentID: agentID, socket: socket, generation: generation) }
    catch { failure = error }
    // Include cached pending runs even if OpenClaw has since pruned its run ledger.
    for run in try database.openClawCronRuns(agentID: agentID).reversed() {
      guard let destination = routes[run.jobID], !destination.isEmpty else { continue }
      if receipts[run.jobID] == nil {
        receipts[run.jobID] = try database.collectedOpenClawResultIDs(agentID: agentID, jobID: run.jobID)
      }
      guard receipts[run.jobID]?.contains(run.id) != true else { continue }
      do {
        let output: String
        if let retained = try database.retainedOpenClawResult(agentID: agentID, runID: run.id) {
          output = retained
        } else {
          output = try await scheduledOutput(run: run, socket: socket)
          try database.retainOpenClawResult(run, title: jobs.first { $0.id == run.jobID }?.name ?? "Scheduled result", output: output)
        }
        guard generation == connectionGenerations[agentID], !Task.isCancelled else { throw CancellationError() }
        let title = jobs.first { $0.id == run.jobID }?.name ?? "Scheduled result"
        if let conversationID = try database.collectOpenClawResult(run, title: title, output: output, destination: destination) {
          receipts[run.jobID, default: []].insert(run.id)
          onChange?(DashboardConversationChange(conversationID: conversationID, runID: run.id, phase: .content))
        }
      } catch is CancellationError { throw CancellationError() }
      catch { failure = failure ?? error }
    }
    if let failure { throw failure }
  }

  private func collectRetainedResults(agentID: UUID, socket: OpenClawGatewayClient, generation: UUID?) async throws {
    let consumer = agentID.uuidString.lowercased()
    var after = ""
    var failure: String?
    while true {
      let response = try await socket.request("wovenmatter.results.list", params: .object([
        "consumer": .string(consumer), "after": .string(after), "limit": .number(100)
      ]))
      guard let page = response.objectValue, let entries = page["entries"]?.arrayValue else {
        throw OpenClawGatewayClientError.malformedFrame
      }
      failure = failure ?? page["error"]?.stringValue
      for entry in entries {
        try Task.checkCancellation()
        guard generation == connectionGenerations[agentID] else { throw CancellationError() }
        guard let row = entry.objectValue, let id = row["id"]?.stringValue,
              let payload = row["run"], let run = try Self.cronRun(agentID: agentID, value: payload) else {
          throw OpenClawGatewayClientError.malformedFrame
        }
        guard row["available"]?.boolValue == true else {
          failure = failure ?? row["error"]?.stringValue ?? "A scheduled result is unavailable."
          continue
        }
        if try database.retainedOpenClawResult(agentID: agentID, runID: run.id) == nil {
          var output = ""
          var offset = 0
          while true {
            let chunk = try await socket.request("wovenmatter.results.output", params: .object([
              "id": .string(id), "offset": .number(Double(offset))
            ]))
            guard let text = chunk.objectValue?["text"]?.stringValue else { throw OpenClawGatewayClientError.malformedFrame }
            output += text
            guard let next = chunk.objectValue?["nextOffset"]?.intValue else { break }
            guard next > offset, !text.isEmpty else { throw OpenClawGatewayClientError.malformedFrame }
            offset = next
          }
          guard generation == connectionGenerations[agentID], !Task.isCancelled else { throw CancellationError() }
          try database.retainOpenClawResult(run, title: row["title"]?.stringValue ?? "Scheduled result", output: output)
        }
        // The durable local history commit precedes the host receipt. A lost
        // acknowledgement is retried without another message or another run.
        _ = try await socket.request("wovenmatter.results.ack", params: .object([
          "consumer": .string(consumer), "id": .string(id)
        ]))
      }
      guard let next = page["next"]?.stringValue else { break }
      guard next > after, !entries.isEmpty else { throw OpenClawGatewayClientError.malformedFrame }
      after = next
    }
    if let failure { throw OpenClawGatewayClientError.rejected(failure) }
  }

  private func cronPages(socket: OpenClawGatewayClient, method: String, field: String,
                         parameters: [String: GatewayJSONValue]) async throws -> [GatewayJSONValue] {
    var offset = 0
    var values: [GatewayJSONValue] = []
    while true {
      try Task.checkCancellation()
      var parameters = parameters
      parameters["limit"] = .number(200)
      parameters["offset"] = .number(Double(offset))
      let result = try await socket.request(method, params: .object(parameters))
      guard let row = result.objectValue, let page = row[field]?.arrayValue,
            let more = row["hasMore"]?.boolValue else { throw OpenClawGatewayClientError.malformedFrame }
      values.append(contentsOf: page)
      if !more { return values }
      guard let next = row["nextOffset"]?.intValue, next > offset, !page.isEmpty else {
        throw OpenClawGatewayClientError.malformedFrame
      }
      offset = next
    }
  }

  private func scheduledOutput(run: OpenClawCronRun, socket: OpenClawGatewayClient) async throws -> String {
    guard let key = run.nativeSessionKey, let sessionID = run.nativeSessionID else {
      // Main-session wakeups and failed/skipped runs can have no transcript.
      guard run.status != "ok" else {
        throw OpenClawGatewayClientError.rejected("Job \(run.jobID): no run transcript is available. The result remains uncollected.")
      }
      return run.output ?? "OpenClaw reported \(run.status) without output."
    }
    var offset = 0
    var first: OpenClawGatewayHistory?
    var messages: [OpenClawGatewayHistoryMessage] = []
    var seen: Set<String> = []
    while true {
      let history = try await fetchHistory(sessionKey: key, offset: offset, socket: socket)
      guard history.sessionID == sessionID, history.isIdle else {
        throw OpenClawGatewayClientError.rejected("Job \(run.jobID): the run transcript is unavailable or still changing. Collection will retry.")
      }
      if let first, first.totalMessages != history.totalMessages { throw OpenClawGatewayClientError.rejected("The run transcript changed during collection.") }
      if first == nil { first = history }
      messages.append(contentsOf: history.messages.filter { seen.insert($0.id).inserted })
      guard let next = history.nextOffset else { break }
      guard next > offset else { throw OpenClawGatewayClientError.malformedFrame }
      offset = next
    }
    // A run-specific cron key owns the isolated transcript. Reused/main sessions
    // require explicit native run identity; timestamps alone are not authority.
    let isolated = key.contains(":cron:\(run.jobID):run:")
    let replies = messages.filter {
      $0.isAssistantResponse && (isolated || $0.gatewayRunID == run.id || $0.runID == run.id)
    }.sorted { $0.date < $1.date }
    let output = replies.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    guard !output.isEmpty else {
      throw OpenClawGatewayClientError.rejected("Job \(run.jobID): full output is not available. Its retained summary has not been acknowledged as a complete result.")
    }
    if let first {
      let check = try await fetchHistory(sessionKey: key, offset: 0, socket: socket)
      guard check.sessionID == first.sessionID, check.totalMessages == first.totalMessages,
            check.messages == first.messages, !check.hasActiveRun, check.inFlightRunID == nil else {
        throw OpenClawGatewayClientError.rejected("The run transcript changed during collection.")
      }
    }
    return output
  }

  static func cronJob(
    agentID: UUID,
    value: GatewayJSONValue,
    encoder: JSONEncoder = JSONEncoder()
  ) throws -> OpenClawCronJob? {
    guard let object = value.objectValue,
          let id = object["id"]?.stringValue else { return nil }
    let scheduleData = try encoder.encode(object["schedule"] ?? .null)
    return OpenClawCronJob(
      id: id, agentID: agentID,
      name: object["name"]?.stringValue ?? "Cron job",
      schedule: String(data: scheduleData, encoding: .utf8) ?? "{}",
      enabled: object["enabled"]?.boolValue ?? true,
      nativeSessionID: object["sessionId"]?.stringValue,
      nativeSessionKey: object["sessionKey"]?.stringValue,
      remotePayload: try encoder.encode(value),
      updatedAt: object["updatedAtMs"]?.dateFromMilliseconds ?? Date()
    )
  }

  static func cronRun(
    agentID: UUID,
    value: GatewayJSONValue,
    encoder: JSONEncoder = JSONEncoder()
  ) throws -> OpenClawCronRun? {
    guard let object = value.objectValue,
          let jobID = object["jobId"]?.stringValue,
          object["action"]?.stringValue == "finished",
          case .number(let timestampMilliseconds)? = object["ts"],
          timestampMilliseconds.isFinite, timestampMilliseconds >= 0, timestampMilliseconds < Double(Int64.max) else { return nil }
    let id = object["runId"]?.stringValue
      ?? "history:\(jobID):\(Int(timestampMilliseconds))"
    let runAt = object["runAtMs"]?.dateFromMilliseconds
    let timestamp = object["ts"]?.dateFromMilliseconds
    let startedAt = runAt ?? timestamp
    let completedAt: Date? = if let runAt,
      case .number(let duration)? = object["durationMs"] {
      runAt.addingTimeInterval(duration / 1_000)
    } else {
      timestamp
    }
    return OpenClawCronRun(
      id: id, jobID: jobID, agentID: agentID,
      status: object["status"]?.stringValue ?? "unknown",
      output: object["summary"]?.stringValue ?? object["error"]?.stringValue,
      nativeSessionID: object["sessionId"]?.stringValue,
      nativeSessionKey: object["sessionKey"]?.stringValue,
      startedAt: startedAt, completedAt: completedAt,
      remotePayload: try encoder.encode(value)
    )
  }

  func client(agentID: UUID) async throws -> OpenClawGatewayClient {
    guard !isShuttingDown else { throw CancellationError() }
    if let client = clients[agentID] { return client }
    if let pending = pendingClientConnections[agentID] {
      let generation = connectionGenerations[agentID]
      let client = try await pending.value
      guard generation == connectionGenerations[agentID] else { throw CancellationError() }
      try Task.checkCancellation()
      return client
    }
    let generation = UUID()
    connectionGenerations[agentID] = generation
    let connectClient = self.connectClient
    let database = self.database
    let task = Task<OpenClawGatewayClient, any Error> { [weak self] in
      guard var link = try database.openClawGatewayLinks().first(where: {
        $0.agentID == agentID
      }) else { throw OpenClawGatewayClientError.invalidEndpoint }
      let transport = await self?.clientTransports[agentID]
        ?? ClientTransport(endpoint: link.endpoint, headers: [:])
      let injectedClient = await self?.testClient
      let client = injectedClient ?? OpenClawGatewayClient(
        endpoint: transport.endpoint,
        requestHeaders: transport.headers,
        password: transport.password,
        credentialScope: "gateway-agent:\(agentID.uuidString.lowercased())"
          + (link.location == .remoteWorkspace ? "" : ":\(link.endpoint.url.absoluteString)"),
        eventHandler: { [weak self] event in
          await self?.handleGatewayEvent(event, agentID: agentID, generation: generation)
        },
        disconnectHandler: { [weak self] detail in
          await self?.handleGatewayDisconnect(agentID: agentID, generation: generation, detail: detail)
        },
        connectionHandler: { [weak self] in
          await self?.didConnect(agentID: agentID, generation: generation)
        }
      )
      do {
        let hello = try await connectClient(client)
        try Task.checkCancellation()
        guard await self?.isCurrentConnection(agentID, generation: generation) == true else { throw CancellationError() }
        link.status = OpenClawGatewayConnectionStatus.ready.rawValue
        link.openClawVersion = hello.applicationVersion
        link.lastConnectedAt = hello.connectedAt
        link.lastError = nil
        link.updatedAt = Date()
        try database.saveOpenClawGatewayLink(link)
        return client
      } catch {
        await client.disconnect()
        link.status = OpenClawGatewayConnectionStatus.unavailable.rawValue
        link.lastError = error.localizedDescription
        link.updatedAt = Date()
        if await self?.isCurrentConnection(agentID, generation: generation) == true {
          try? database.saveOpenClawGatewayLink(link)
        }
        throw error
      }
    }
    pendingClientConnections[agentID] = task
    do {
      let client = try await task.value
      guard isCurrentConnection(agentID, generation: generation) else {
        await client.disconnect()
        throw CancellationError()
      }
      pendingClientConnections.removeValue(forKey: agentID)
      clients[agentID] = client
      startMonitor(agentID: agentID, generation: generation)
      try Task.checkCancellation()
      return client
    } catch {
      if isCurrentConnection(agentID, generation: generation) {
        pendingClientConnections.removeValue(forKey: agentID)
      }
      throw error
    }
  }

  private func isCurrentConnection(_ agentID: UUID, generation: UUID) -> Bool {
    connectionGenerations[agentID] == generation
  }

  private func linkedGateway(agentID: UUID) throws -> OpenClawGatewayLink {
    guard let link = try database.openClawGatewayLinks().first(where: {
      $0.agentID == agentID
    }) else {
      throw OpenClawGatewayClientError.invalidEndpoint
    }
    return link
  }

  private func setLinkStatus(
    agentID: UUID,
    status: OpenClawGatewayConnectionStatus,
    error: String?
  ) throws {
    var link = try linkedGateway(agentID: agentID)
    link.status = status.rawValue
    link.lastError = error
    link.updatedAt = Date()
    try database.saveOpenClawGatewayLink(link)
  }

  private func handleGatewayDisconnect(agentID: UUID, generation: UUID, detail: String) {
    guard isCurrentConnection(agentID, generation: generation), let link = try? linkedGateway(agentID: agentID),
          link.connectionStatus != .restarting else { return }
    try? setLinkStatus(agentID: agentID, status: .unavailable, error: detail)
  }

  private func startMonitor(agentID: UUID, generation: UUID) {
    guard automaticReconnect, monitorTasks[agentID] == nil else { return }
    monitorTasks[agentID] = Task { [weak self] in
      var delay = 2
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard let self, await self.isCurrentConnection(agentID, generation: generation) else { return }
        do {
          let socket = try await self.client(agentID: agentID)
          _ = try await socket.connect()
          delay = 2
        } catch {
          guard Self.shouldRetryConnection(error) else { return }
          delay = min(30, delay * 2)
        }
      }
    }
  }

  private func didConnect(agentID: UUID, generation: UUID) async {
    guard isCurrentConnection(agentID, generation: generation) else { return }
    do {
      let socket = try await client(agentID: agentID)
      _ = try await socket.request("health", timeout: .seconds(5))
      guard isCurrentConnection(agentID, generation: generation) else { return }
      try setLinkStatus(agentID: agentID, status: .ready, error: nil)
      _ = try await socket.request("sessions.subscribe")
      for session in try database.openClawGatewaySessions(agentID: agentID) {
        scheduleHistoryRefresh(conversationID: session.conversationID, agentID: agentID, generation: generation)
      }
    } catch {
      if isCurrentConnection(agentID, generation: generation) {
        try? setLinkStatus(agentID: agentID, status: .unavailable, error: error.localizedDescription)
      }
    }
  }

  private func scheduleHistoryRefresh(conversationID: String, agentID: UUID, generation: UUID) {
    guard isCurrentConnection(agentID, generation: generation) else { return }
    guard historyTasks[conversationID] == nil else {
      dirtyHistories.insert(conversationID)
      return
    }
    historyTasks[conversationID] = (agentID, Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard let self, await self.isCurrentConnection(agentID, generation: generation) else { return }
      do { _ = try await self.synchronizeSession(conversationID: conversationID) }
      catch { await self.historyRefreshFailed(conversationID: conversationID, agentID: agentID, generation: generation, error: error) }
      await self.finishedHistoryRefresh(conversationID: conversationID, agentID: agentID, generation: generation)
    })
  }

  private func finishedHistoryRefresh(conversationID: String, agentID: UUID, generation: UUID) {
    guard isCurrentConnection(agentID, generation: generation) else { return }
    historyTasks[conversationID] = nil
    if dirtyHistories.remove(conversationID) != nil {
      scheduleHistoryRefresh(conversationID: conversationID, agentID: agentID, generation: generation)
    }
  }
  private func historyRefreshFailed(conversationID: String, agentID: UUID, generation: UUID, error: any Error) {
    guard isCurrentConnection(agentID, generation: generation), !(error is CancellationError) else { return }
    if let descriptor = try? database.openClawGatewaySession(conversationID: conversationID) {
      try? setLinkStatus(agentID: descriptor.agentID, status: .unavailable, error: error.localizedDescription)
    }
  }

  public func createWorkspaceSession(agentID: UUID, sessionKey: String, cwd: URL) async throws {
    let socket = try await client(agentID: agentID)
    let generation = connectionGenerations[agentID]
    let receipt = try await socket.request("sessions.create", params: .object([
      "key": .string(sessionKey), "cwd": .string(cwd.path)
    ]))
    guard generation == connectionGenerations[agentID], !Task.isCancelled else { throw CancellationError() }
    guard receipt.objectValue?["key"]?.stringValue == sessionKey,
          receipt.objectValue?["entry"]?.objectValue?["spawnedCwd"]?.stringValue == cwd.path else {
      throw OpenClawGatewayClientError.rejected("OpenClaw did not confirm this session's working directory.")
    }
  }

  public func nativeSessions(agentID: UUID, offset: Int = 0) async throws -> (sessions: [OpenClawGatewaySession], nextOffset: Int?) {
    guard offset >= 0 else { throw OpenClawGatewayClientError.malformedFrame }
    let socket = try await client(agentID: agentID)
    let generation = connectionGenerations[agentID]
    var excluded = try database.knownOpenClawSessionKeys(agentID: agentID)
    var eligible: [OpenClawGatewaySession] = []
    var position = offset
    while eligible.count < 25 {
      let result = try await socket.request("sessions.list", params: .object([
        "limit": .number(Double(25 - eligible.count)), "offset": .number(Double(position))
      ]))
      guard generation == connectionGenerations[agentID], !Task.isCancelled else { throw CancellationError() }
      guard let row = result.objectValue, let rows = row["sessions"]?.arrayValue else { throw OpenClawGatewayClientError.malformedFrame }
      for session in rows.compactMap(OpenClawGatewaySession.init(payload:)) {
        if !session.key.contains(":wovenmatter:"), excluded.insert(session.key).inserted { eligible.append(session) }
      }
      position += rows.count
      if row["hasMore"]?.boolValue != true { return (eligible, nil) }
      guard !rows.isEmpty else { throw OpenClawGatewayClientError.malformedFrame }
    }
    return (eligible, position)
  }

  public func importSession(agentID: UUID, session: OpenClawGatewaySession) async throws -> String {
    guard !session.key.contains(":wovenmatter:"),
          !(try database.knownOpenClawSessionKeys(agentID: agentID)).contains(session.key) else {
      throw NSError(domain: "OpenClawImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "This session is already in Woven Matter. Refresh the list."])
    }
    let socket = try await client(agentID: agentID)
    let generation = connectionGenerations[agentID]
    _ = try await socket.connect()
    guard let transportGeneration = await socket.connectedGeneration else { throw CancellationError() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wovenmatter-openclaw-import-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    var pages: [URL] = []
    var offset = 0
    var first: OpenClawGatewayHistory?
    while true {
      try Task.checkCancellation()
      let page = try await fetchHistory(sessionKey: session.key, offset: offset, socket: socket)
      guard generation == connectionGenerations[agentID],
            transportGeneration == (await socket.connectedGeneration) else { throw CancellationError() }
      if let first {
        guard page.sessionID == first.sessionID, page.totalMessages == first.totalMessages else {
          throw NSError(domain: "OpenClawImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "This session changed during import. Please import it again."])
        }
      } else { first = page }
      let file = directory.appendingPathComponent("\(pages.count).json")
      try JSONEncoder().encode(page).write(to: file, options: .atomic)
      pages.append(file)
      guard let next = page.nextOffset else { break }
      guard next > offset else { throw OpenClawGatewayClientError.malformedFrame }
      offset = next
    }
    guard let first else { throw OpenClawGatewayClientError.malformedFrame }
    let history = pages.count > 1
      ? try await fetchHistory(sessionKey: session.key, offset: 0, socket: socket)
      : first
    guard history.sessionID == first.sessionID, history.totalMessages == first.totalMessages,
          history.messages == first.messages else {
      throw NSError(domain: "OpenClawImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "This session changed during import. Please import it again."])
    }
    guard generation == connectionGenerations[agentID],
          transportGeneration == (await socket.connectedGeneration), !Task.isCancelled else { throw CancellationError() }
    let liveIDs = history.isIdle ? Set<String>() : Set(activeRuns.values.flatMap(\.remoteRunIDs))
    let id = try database.importOpenClawGatewaySession(agentID: agentID, session: session,
                                                      historyPages: pages, liveRunIDs: liveIDs)
    try recoverSessionRuns(conversationID: id, history: history)
    onChange?(DashboardConversationChange(conversationID: id, runID: "", phase: .content))
    return id
  }

  private func fetchHistory(sessionKey: String, offset: Int, socket: OpenClawGatewayClient) async throws -> OpenClawGatewayHistory {
    _ = try await socket.connect()
    guard let transportGeneration = await socket.connectedGeneration else { throw CancellationError() }
    // Reading history must not depend on approval-management authorization.
    _ = try await socket.request("sessions.messages.subscribe", params: .object([
      "key": .string(sessionKey)
    ]), expectedConnectionGeneration: transportGeneration)
    let result = try await socket.request("chat.history", params: .object([
      "sessionKey": .string(sessionKey), "limit": .number(100),
      "offset": .number(Double(offset)), "maxBytes": .number(524_288),
      "maxChars": .number(500_000)
    ]), expectedConnectionGeneration: transportGeneration)
    let hydrated = try await OpenClawGatewayHistoryHydration.hydrate(result) { messageID in
      try await socket.request("chat.message.get", params: .object([
        "sessionKey": .string(sessionKey), "messageId": .string(messageID),
        "maxChars": .number(500_000)
      ]), expectedConnectionGeneration: transportGeneration)
    }
    try Task.checkCancellation()
    guard await socket.connectedGeneration == transportGeneration else { throw CancellationError() }
    return try OpenClawGatewayHistory(payload: hydrated)
  }

  @discardableResult
  public func synchronizeSession(conversationID: String, offset: Int = 0) async throws -> OpenClawGatewayHistory {
    let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
    let socket = try await client(agentID: descriptor.agentID)
    let generation = connectionGenerations[descriptor.agentID]
    let history = try await fetchHistory(sessionKey: descriptor.sessionKey, offset: offset, socket: socket)
    guard generation == connectionGenerations[descriptor.agentID], !Task.isCancelled else { throw CancellationError() }
    // Provider idle does not mean local reconciliation has finished. Protect
    // tracked and interrupted replies until their final segment is repaired.
    let unfinishedRuns = try database.interruptedOpenClawRuns(conversationID: conversationID)
    var liveIDs = Set(activeRuns.values.filter { $0.conversationID == conversationID }.flatMap(\.remoteRunIDs))
    var inputsByRun: [String: [String: String]] = [:]
    for run in unfinishedRuns {
      var inputs = try database.openClawRunAssistantIDs(runID: run.runID)
      if inputs.isEmpty { inputs[run.runID] = run.assistantMessageID }
      inputsByRun[run.runID] = inputs
      liveIDs.formUnion(inputs.keys)
    }
    try database.synchronizeOpenClawHistory(conversationID: conversationID, history: history, liveRunIDs: liveIDs)
    if history.isIdle {
      for run in unfinishedRuns {
        let inputs = inputsByRun[run.runID] ?? [:]
        let latestID = inputs.first { $0.value == run.assistantMessageID }?.key ?? run.runID
        if let final = history.messages.last(where: {
          $0.isAssistantResponse && !$0.isTruncated && $0.correlatedRunID(knownInputIDs: Set(inputs.keys)) == latestID
        }), !final.isTruncated, !final.text.isEmpty {
          try database.replaceLocalACPAssistantMessage(runID: run.runID,
            assistantMessageID: run.assistantMessageID, content: final.text,
            preservingStreamCommentary: final.isFinalOnlyAssistantTranscript)
        }
      }
    }
    if offset == 0 {
      try recoverSessionRuns(conversationID: conversationID, history: history)
    }
    onChange?(DashboardConversationChange(conversationID: conversationID, runID: "", phase: .content))
    return history
  }

  func recoverSessionRuns(conversationID: String, history: OpenClawGatewayHistory) throws {
    for run in try database.interruptedOpenClawRuns(conversationID: conversationID)
    where activeRuns[run.runID] == nil {
      var inputs = try database.openClawRunAssistantIDs(runID: run.runID)
      if inputs.isEmpty { inputs[run.runID] = run.assistantMessageID }
      let latestRemoteID = inputs.first { $0.value == run.assistantMessageID }?.key ?? run.runID
      // Observe recovery by session. Never resend an input on ambiguous acceptance.
      if history.hasActiveRun || history.inFlightRunID != nil {
        if let remoteID = history.inFlightRunID, let assistantID = inputs[remoteID],
           let text = history.inFlightText, !history.inFlightIsTruncated, !text.isEmpty {
          try database.replaceLocalACPAssistantMessage(runID: run.runID, assistantMessageID: assistantID, content: text)
        }
        let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
        // An unrelated client may own inFlightRun. Never bind its output to our input.
        var active = ActiveRun(
          runID: run.runID, conversationID: conversationID, agentID: descriptor.agentID,
          sessionKey: descriptor.sessionKey, onUpdate: nil, onPermission: nil,
          remoteRunIDs: Set(inputs.keys), lastRemoteRunID: latestRemoteID,
          assistantMessageIDsByRemoteRunID: inputs
        )
        try hydrateGatewayStreamingState(runID: run.runID, active: &active)
        activeRuns[run.runID] = active
        markPromptReady(runID: run.runID)
        runTasks[run.runID] = Task { [weak self] in
          await self?.observeRecoveredRun(run: run, conversationID: conversationID)
        }
      } else if history.isIdle {
        let final = history.messages.last { $0.correlatedRunID(knownInputIDs: Set(inputs.keys)) == latestRemoteID && $0.isAssistantResponse && !$0.isTruncated }
        try database.completeLocalACPRun(runID: run.runID, error: final == nil
          ? "OpenClaw delivery could not be confirmed after reconnect. Check the shared session before retrying; this input was not resent."
          : final?.terminalError)
        onChange?(DashboardConversationChange(conversationID: conversationID, runID: run.runID, phase: .terminal))
      }
    }
  }

  private func observeRecoveredRun(run: LocalACPRunIdentifiers, conversationID: String) async {
    defer { finishTracking(runID: run.runID) }
    while !Task.isCancelled {
      do {
        let history = try await synchronizeSession(conversationID: conversationID)
        if history.isIdle {
          let cancelled = activeRuns[run.runID]?.cancelRequested == true
          let latestRemoteID = activeRuns[run.runID]?.lastRemoteRunID ?? run.runID
          let inputs = try database.openClawRunAssistantIDs(runID: run.runID)
          let final = history.messages.last { $0.isAssistantResponse && !$0.isTruncated && $0.correlatedRunID(knownInputIDs: Set(inputs.keys)) == latestRemoteID }
          try database.completeLocalACPRun(runID: run.runID, error: cancelled
            ? "The OpenClaw Gateway run was cancelled."
            : (final == nil ? "OpenClaw delivery could not be confirmed after reconnect. This input was not resent." : final?.terminalError))
          await publishUpdate(runID: run.runID, phase: .terminal)
          return
        }
      } catch {
        // A disconnected Gateway owns execution; keep the local run recoverable.
        if Task.isCancelled { return }
      }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }

  static func assistantText(
    history: GatewayJSONValue,
    idempotencyKey: String,
    knownInputIDs: Set<String>
  ) -> String? {
    assistantMessage(
      history: history,
      idempotencyKey: idempotencyKey,
      knownInputIDs: knownInputIDs
    )?.text
  }

  static func assistantMessage(
    history: GatewayJSONValue,
    idempotencyKey: String,
    knownInputIDs: Set<String>
  ) -> OpenClawGatewayHistoryMessage? {
    let messages = history.objectValue?["messages"]?.arrayValue ?? []
    for value in messages.reversed() {
      guard let projected = OpenClawGatewayHistoryMessage(payload: value),
            projected.isAssistantResponse, !projected.isTruncated, projected.correlatedRunID(knownInputIDs: knownInputIDs) == idempotencyKey else { continue }
      if !projected.text.isEmpty { return projected }
    }
    return nil
  }
}

private extension GatewayJSONValue {
  var dateFromMilliseconds: Date? {
    guard case .number(let value) = self else { return nil }
    return Date(timeIntervalSince1970: value / 1_000)
  }
}
