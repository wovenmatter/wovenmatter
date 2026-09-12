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
  private static let agentsListParameters: GatewayJSONValue = .object([:])
  private static let cronListParameters: GatewayJSONValue = .object([
    "includeDisabled": .bool(true), "limit": .number(200),
    "offset": .number(0), "sortBy": .string("updatedAtMs"),
    "sortDir": .string("desc"),
  ])
  private static let cronRunsParameters: GatewayJSONValue = .object([
    "scope": .string("all"), "limit": .number(200),
    "sortDir": .string("desc"),
  ])

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
  private var historyTasks: [String: Task<Void, Never>] = [:]
  private var dirtyHistories: Set<String> = []
  private var lastRunSequences: [String: Int] = [:]
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
    for session in (try? database.openClawGatewaySessions(agentID: agentID)) ?? [] {
      historyTasks.removeValue(forKey: session.conversationID)?.cancel()
      dirtyHistories.remove(session.conversationID)
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
    monitorTasks.removeValue(forKey: agentID)?.cancel()
    for session in (try? database.openClawGatewaySessions(agentID: agentID)) ?? [] {
      historyTasks.removeValue(forKey: session.conversationID)?.cancel()
    }
    await invalidateConnection(agentID: agentID)?.disconnect()
  }

  public func shutdown() async {
    isShuttingDown = true
    for task in runTasks.values { task.cancel() }
    for task in historyTasks.values { task.cancel() }
    for task in monitorTasks.values { task.cancel() }
    for agentID in Set(clients.keys).union(pendingClientConnections.keys) {
      await disconnect(agentID: agentID)
    }
  }

  public func configureTransport(
    agentID: UUID,
    endpoint: OpenClawGatewayEndpoint,
    requestHeaders: [String: String]
  ) async {
    let previous = invalidateConnection(agentID: agentID)
    clientTransports[agentID] = ClientTransport(
      endpoint: endpoint,
      headers: requestHeaders
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
    if event.name == "agent", let row = event.payload?.objectValue,
       let remoteID = row["runId"]?.stringValue, let sequence = row["seq"]?.intValue {
      let sequenceKey = agentID.uuidString + ":" + remoteID
      if let previous = lastRunSequences[sequenceKey], sequence <= previous { return }
      if let previous = lastRunSequences[sequenceKey], sequence > previous + 1 {
        scheduleHistoryRefresh(conversationID: active.conversationID, agentID: agentID, generation: generation)
      }
      lastRunSequences[sequenceKey] = sequence
    }
    let sequence: Int
    if let projectedSequence = projection.sequence {
      sequence = projectedSequence
      active.fallbackSequence = max(active.fallbackSequence, projectedSequence)
    } else {
      active.fallbackSequence += 1
      sequence = active.fallbackSequence
    }
    if let raw = Self.rawEventJSON(event) {
      try? database.appendDeviceOwnedGatewayTraceEvent(
        runID: runID,
        eventName: event.name,
        sequence: sequence,
        eventType: projection.eventType,
        eventPhase: projection.eventPhase,
        toolName: projection.toolName,
        content: projection.content,
        rawEventJSON: raw
      )
    }
    if let assistantUpdate = projection.assistantUpdate {
      let remoteRunID = projection.runID ?? active.lastRemoteRunID
      let assistantMessageID = active.assistantMessageIDsByRemoteRunID[remoteRunID]
      switch assistantUpdate {
      case .append(let chunk):
        if let assistantMessageID {
          try? database.appendLocalACPAssistantChunk(
            runID: runID,
            assistantMessageID: assistantMessageID,
            chunk: chunk
          )
        }
      case .replace(let content):
        if let assistantMessageID {
          try? database.replaceLocalACPAssistantMessage(
            runID: runID,
            assistantMessageID: assistantMessageID,
            content: content
          )
        }
      }
    }
    if let activity = projection.activity {
      try? database.upsertDeviceOwnedRunActivity(
        runID: runID,
        activity: activity,
        appendingContent: activity.contentIsDelta == true
      )
      if activity.kind == .tool,
         projection.eventType == "tool_call" || projection.eventType == "tool_result" {
        active.liveToolCallIDs.insert(activity.id)
      }
    }
    if let terminal = projection.terminalState {
      let remoteRunID = projection.runID ?? active.lastRemoteRunID
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
    for _ in 0..<3 {
      do {
        let history = try await client(agentID: agentID).request(
          "chat.history",
          params: .object([
            "sessionKey": .string(sessionKey),
            "limit": .number(50),
          ])
        )
        if let response = Self.assistantText(
          history: history,
          idempotencyKey: remoteRunID
        ) {
          try database.replaceLocalACPAssistantMessage(
            runID: runID,
            assistantMessageID: assistantMessageID,
            content: response
          )
        }
        return
      } catch {
        try? await Task.sleep(for: .milliseconds(250))
      }
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
    if let active = activeRuns[runID] {
      for remoteID in active.remoteRunIDs { lastRunSequences[active.agentID.uuidString + ":" + remoteID] = nil }
    }
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
    let preferences = try await client.sessionPreferences(key: descriptor.sessionKey)
    let agentID = OpenClawGatewaySession.agentID(for: descriptor.sessionKey)
    var modelParams = Self.modelsListParameters.objectValue ?? [:]
    modelParams["sessionKey"] = .string(descriptor.sessionKey)
    modelParams["includeDetails"] = .bool(true)
    if let agentID { modelParams["agentId"] = .string(agentID) }
    let catalog = try await client.request("models.list", params: .object(modelParams))
    let choices = catalog.objectValue?["models"]?.arrayValue ?? []
    let configuredModels = choices.compactMap(Self.modelReference)
    let selected = choices.first { Self.modelReference($0) == preferences.model }?.objectValue
    let modelThinking = selected?["thinkingLevels"]?.arrayValue?.compactMap {
      $0.stringValue ?? $0.objectValue?["id"]?.stringValue
    } ?? []
    let thinking = modelThinking.isEmpty
      ? await Self.thinkingLevels(client: client, agentID: agentID ?? "main") : modelThinking
    let commands = await Self.slashCommands(client: client, agentID: agentID, sessionKey: descriptor.sessionKey)
    return LocalACPSessionMetadata(
      sessionKey: descriptor.sessionKey,
      model: preferences.model,
      thinking: preferences.thinkingLevel,
      modelOptions: configuredModels,
      thinkingLevels: Array(Set(thinking)).sorted(),
      slashCommands: commands
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

  private static func thinkingLevels(
    from agentsResult: GatewayJSONValue,
    agentID: String
  ) -> [String] {
    let agents = agentsResult.objectValue?["agents"]?.arrayValue ?? []
    guard let agent = agents.first(where: {
      $0.objectValue?["id"]?.stringValue == agentID
    })?.objectValue else { return [] }
    let levels = agent["thinkingLevels"]?.arrayValue?.compactMap {
      $0.objectValue?["id"]?.stringValue
    } ?? []
    let options = agent["thinkingOptions"]?.arrayValue?.compactMap(\.stringValue) ?? []
    return Array(Set(levels + options)).sorted()
  }

  private static func thinkingLevels(
    client: OpenClawGatewayClient,
    agentID: String
  ) async -> [String] {
    guard let agents = try? await client.request(
      "agents.list", params: agentsListParameters, timeout: .seconds(5)
    ) else { return [] }
    return thinkingLevels(from: agents, agentID: agentID)
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

  public func syncCron(agentID: UUID) async throws {
    let client = try await client(agentID: agentID)
    let list = try await client.request(
      "cron.list", params: Self.cronListParameters
    )
    let history = try await client.request(
      "cron.runs", params: Self.cronRunsParameters
    )
    let encoder = JSONEncoder()
    let jobs: [OpenClawCronJob] = try (list.objectValue?["jobs"]?.arrayValue ?? [])
      .compactMap { try Self.cronJob(agentID: agentID, value: $0, encoder: encoder) }
    let runValues = history.objectValue?["entries"]?.arrayValue
      ?? history.objectValue?["runs"]?.arrayValue ?? []
    let runs: [OpenClawCronRun] = try runValues.compactMap {
      try Self.cronRun(agentID: agentID, value: $0, encoder: encoder)
    }
    try database.replaceOpenClawCronSnapshot(
      agentID: agentID,
      jobs: jobs,
      runs: runs
    )
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
          case .number(let timestampMilliseconds)? = object["ts"] else { return nil }
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
      output: object["summary"]?.stringValue,
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
        credentialScope: "gateway-agent:\(agentID.uuidString.lowercased())"
          + (link.location == .remoteWorkspace ? "" : ":\(link.endpoint.url.absoluteString)"),
        eventHandler: { [weak self] event in
          await self?.handleGatewayEvent(event, agentID: agentID, generation: generation)
        },
        disconnectHandler: { [weak self] detail in
          await self?.handleGatewayDisconnect(agentID: agentID, generation: generation, detail: detail)
        },
        connectionHandler: { [weak self] hello in
          await self?.didConnect(agentID: agentID, generation: generation, hello: hello)
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

  private func didConnect(agentID: UUID, generation: UUID, hello: OpenClawGatewayCapabilities) async {
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
    historyTasks[conversationID] = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard let self, await self.isCurrentConnection(agentID, generation: generation) else { return }
      do { _ = try await self.synchronizeSession(conversationID: conversationID) }
      catch { await self.historyRefreshFailed(conversationID: conversationID, agentID: agentID, generation: generation, error: error) }
      await self.finishedHistoryRefresh(conversationID: conversationID, agentID: agentID, generation: generation)
    }
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

  public func nativeSessions(agentID: UUID, offset: Int = 0) async throws -> (sessions: [OpenClawGatewaySession], nextOffset: Int?) {
    let socket = try await client(agentID: agentID)
    let generation = connectionGenerations[agentID]
    let result = try await socket.request("sessions.list", params: .object([
      "limit": .number(60), "offset": .number(Double(offset))
    ]))
    guard generation == connectionGenerations[agentID], !Task.isCancelled else { throw CancellationError() }
    guard let row = result.objectValue, let sessions = row["sessions"]?.arrayValue else {
      throw OpenClawGatewayClientError.malformedFrame
    }
    return (sessions.compactMap(OpenClawGatewaySession.init(payload:)),
      row["hasMore"]?.boolValue == true ? row["nextOffset"]?.intValue : nil)
  }

  public func sessionControls(conversationID: String) async throws -> OpenClawGatewayControls {
    let session = try database.openClawGatewaySession(conversationID: conversationID)
    let socket = try await client(agentID: session.agentID)
    guard let generation = connectionGenerations[session.agentID] else { throw CancellationError() }
    let hello = try await socket.connect()
    guard let transportGeneration = await socket.connectedGeneration else { throw CancellationError() }
    let subscription = try await socket.request("sessions.messages.subscribe", params: .object([
      "key": .string(session.sessionKey), "includeApprovals": .bool(true)
    ]), expectedConnectionGeneration: transportGeneration)
    let questions = try await socket.request("question.list", expectedConnectionGeneration: transportGeneration)
    guard isCurrentConnection(session.agentID, generation: generation) else { throw CancellationError() }
    let replay = subscription.objectValue?["approvalReplay"]?.objectValue ?? [:]
    var controlURL = OpenClawGatewayControls.safeControlUIURL(hello.controlUIURL)
    let link = try linkedGateway(agentID: session.agentID)
    if controlURL == nil, link.endpoint.authorization == .localService {
      var components = URLComponents(url: link.endpoint.url, resolvingAgainstBaseURL: false)
      components?.scheme = link.endpoint.url.scheme == "wss" ? "https" : "http"
      components?.path = "/"; components?.query = nil; components?.fragment = nil
      controlURL = OpenClawGatewayControls.safeControlUIURL(components?.url)
    }
    return OpenClawGatewayControls(agentID: session.agentID, generation: generation,
      conversationID: conversationID, sessionKey: session.sessionKey,
      approvals: replay["approvals"]?.arrayValue ?? [],
      questions: (questions.objectValue?["questions"]?.arrayValue ?? []).filter {
        $0.objectValue?["status"]?.stringValue == "pending"
          && $0.objectValue?["sessionKey"]?.stringValue == session.sessionKey
      }, approvalsTruncated: replay["truncated"]?.boolValue == true, controlUIURL: controlURL,
      transportGeneration: transportGeneration)
  }

  private func controlsClient(_ snapshot: OpenClawGatewayControls) throws -> OpenClawGatewayClient {
    let session = try database.openClawGatewaySession(conversationID: snapshot.conversationID)
    guard session.agentID == snapshot.agentID, session.sessionKey == snapshot.sessionKey,
          isCurrentConnection(snapshot.agentID, generation: snapshot.generation),
          let socket = clients[snapshot.agentID] else {
      throw OpenClawGatewayClientError.rejected("The Gateway connection changed. Refresh before making a change.")
    }
    return socket
  }

  public func setSessionSetting(_ setting: OpenClawSessionSetting, value: GatewayJSONValue,
                               snapshot: OpenClawGatewayControls) async throws {
    let socket = try controlsClient(snapshot)
    _ = try await socket.request("sessions.patch", params: .object([
      "key": .string(snapshot.sessionKey), setting.rawValue: value
    ]), expectedConnectionGeneration: snapshot.transportGeneration)
    _ = try controlsClient(snapshot)
  }

  public func stopSession(snapshot: OpenClawGatewayControls) async throws {
    let socket = try controlsClient(snapshot)
    let receipt = try await socket.request("sessions.abort", params: .object([
      "key": .string(snapshot.sessionKey), "clearQueued": .bool(true)
    ]), expectedConnectionGeneration: snapshot.transportGeneration)
    _ = try controlsClient(snapshot)
    guard receipt.objectValue?["status"]?.stringValue == "aborted" else { return }
    for (id, var active) in activeRuns where active.conversationID == snapshot.conversationID {
      active.cancelRequested = true
      activeRuns[id] = active
    }
  }

  public func resolveApproval(id: String, decision: String, snapshot: OpenClawGatewayControls) async throws {
    let socket = try controlsClient(snapshot)
    guard let approval = snapshot.approvals.first(where: { $0.objectValue?["id"]?.stringValue == id }),
          let presentation = approval.objectValue?["presentation"]?.objectValue,
          let kind = presentation["kind"]?.stringValue,
          ["allow-once", "deny"].contains(decision),
          presentation["allowedDecisions"]?.arrayValue?.contains(.string(decision)) == true else {
      throw OpenClawGatewayClientError.rejected("Refresh this approval before deciding.")
    }
    // Deliberately no automatic retry: a lost response is not a failed decision.
    let result = try await socket.request("approval.resolve", params: .object([
      "id": .string(id), "kind": .string(kind), "decision": .string(decision)
    ]), expectedConnectionGeneration: snapshot.transportGeneration)
    _ = try controlsClient(snapshot)
    guard result.objectValue?["applied"]?.boolValue == true else {
      throw OpenClawGatewayClientError.rejected("This approval was already resolved. Refresh to see its recorded state.")
    }
  }

  public func answerQuestion(id: String, answers: [String: [String]], snapshot: OpenClawGatewayControls) async throws {
    let socket = try controlsClient(snapshot)
    guard let record = snapshot.questions.first(where: { $0.objectValue?["id"]?.stringValue == id }),
          let questions = record.objectValue?["questions"]?.arrayValue,
          !questions.contains(where: { $0.objectValue?["isSecret"]?.boolValue == true || $0.objectValue?["secretStore"]?.objectValue != nil }) else {
      throw OpenClawGatewayClientError.rejected("Open secret-store questions in OpenClaw Control UI.")
    }
    let resolutionID = UUID().uuidString.lowercased()
    do {
      let result = try await socket.request("question.resolve", params: .object([
        "id": .string(id), "resolutionId": .string(resolutionID),
        "answers": .object(["answers": .object(answers.mapValues { .array($0.map(GatewayJSONValue.string)) })])
      ]), expectedConnectionGeneration: snapshot.transportGeneration)
      guard result.objectValue?["status"]?.stringValue == "answered" else {
        throw OpenClawGatewayClientError.rejected("This question was not answered. Refresh its current state.")
      }
    } catch {
      guard Self.isRecoverableDeliveryError(error) else { throw error }
      // Probe the receipt, never resend an answer whose delivery is uncertain.
      _ = try controlsClient(snapshot)
      let receipt = try await socket.request("question.waitAnswer", params: .object([
        "id": .string(id), "timeoutMs": .number(1), "includeResolutionId": .bool(true)
      ]))
      guard receipt.objectValue?["status"]?.stringValue == "answered",
            receipt.objectValue?["resolutionId"]?.stringValue == resolutionID else {
        throw OpenClawGatewayClientError.rejected("Answer delivery could not be confirmed. Refresh; the answer was not resent.")
      }
    }
    _ = try controlsClient(snapshot)
  }

  public func importSession(agentID: UUID, session: OpenClawGatewaySession) async throws -> String {
    let socket = try await client(agentID: agentID)
    let generation = connectionGenerations[agentID]
    let history = try await fetchHistory(sessionKey: session.key, offset: 0, socket: socket)
    guard generation == connectionGenerations[agentID], !Task.isCancelled else { throw CancellationError() }
    // Do not leave a phantom local chat when history is denied or the link changes.
    let id = try database.importOpenClawGatewaySession(agentID: agentID, session: session)
    let liveIDs = history.isIdle ? [] : Set(activeRuns.values.filter { $0.conversationID == id }.flatMap(\.remoteRunIDs))
    try database.synchronizeOpenClawHistory(conversationID: id, history: history, liveRunIDs: liveIDs)
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
      "offset": .number(Double(offset)), "maxBytes": .number(524_288)
    ]), expectedConnectionGeneration: transportGeneration)
    return try OpenClawGatewayHistory(payload: result)
  }

  @discardableResult
  public func synchronizeSession(conversationID: String, offset: Int = 0) async throws -> OpenClawGatewayHistory {
    let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
    let socket = try await client(agentID: descriptor.agentID)
    let generation = connectionGenerations[descriptor.agentID]
    let history = try await fetchHistory(sessionKey: descriptor.sessionKey, offset: offset, socket: socket)
    guard generation == connectionGenerations[descriptor.agentID], !Task.isCancelled else { throw CancellationError() }
    let liveIDs = history.isIdle ? [] : Set(activeRuns.values.filter { $0.conversationID == conversationID }.flatMap(\.remoteRunIDs))
    try database.synchronizeOpenClawHistory(conversationID: conversationID, history: history, liveRunIDs: liveIDs)
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
           let text = history.inFlightText, !text.isEmpty {
          try database.replaceLocalACPAssistantMessage(runID: run.runID, assistantMessageID: assistantID, content: text)
        }
        let descriptor = try database.openClawGatewaySession(conversationID: conversationID)
        // An unrelated client may own inFlightRun. Never bind its output to our input.
        activeRuns[run.runID] = ActiveRun(
          runID: run.runID, conversationID: conversationID, agentID: descriptor.agentID,
          sessionKey: descriptor.sessionKey, onUpdate: nil, onPermission: nil,
          remoteRunIDs: Set(inputs.keys), lastRemoteRunID: latestRemoteID,
          assistantMessageIDsByRemoteRunID: inputs
        )
        markPromptReady(runID: run.runID)
        runTasks[run.runID] = Task { [weak self] in
          await self?.observeRecoveredRun(run: run, conversationID: conversationID)
        }
      } else if history.isIdle {
        let final = history.messages.last { $0.runID == latestRemoteID && $0.isAssistantResponse }
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
          let final = history.messages.last { $0.isAssistantResponse && $0.runID == latestRemoteID }
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

  private static func assistantText(
    history: GatewayJSONValue,
    idempotencyKey: String
  ) -> String? {
    let messages = history.objectValue?["messages"]?.arrayValue ?? []
    for value in messages.reversed() {
      guard let message = value.objectValue,
            let projected = OpenClawGatewayHistoryMessage(payload: value),
            projected.isAssistantResponse, projected.runID == idempotencyKey else { continue }
      if let text = message["text"]?.stringValue { return text }
      let parts = message["content"]?.arrayValue ?? []
      let text = parts.compactMap { part -> String? in
        let object = part.objectValue
        guard object?["type"]?.stringValue == "text" else { return nil }
        return object?["text"]?.stringValue
      }.joined()
      if !text.isEmpty { return text }
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
