import Darwin
import Foundation
import WovenMatterCore

public enum LocalACPEvent: Equatable, Sendable {
    case assistantChunk(String)
    case assistantSnapshot(String)
    case sessionIdentity(String)
    case assistantBoundary
    case activity(AgentRunActivity, appendsContent: Bool)
    case usage(UsageTokenCounts)
    case composerPrefill(String)
}

public struct LocalACPPermissionOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct LocalACPPermissionRequest: Equatable, Sendable {
    public let title: String
    public let options: [LocalACPPermissionOption]

    public init(title: String, options: [LocalACPPermissionOption]) {
        self.title = title
        self.options = options
    }
}

public struct LocalACPQuestionOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct LocalACPQuestion: Equatable, Identifiable, Sendable {
    public let id: String
    public let prompt: String
    public let options: [LocalACPQuestionOption]
    public let allowsMultiple: Bool

    public init(
        id: String,
        prompt: String,
        options: [LocalACPQuestionOption],
        allowsMultiple: Bool = false
    ) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.allowsMultiple = allowsMultiple
    }
}

public struct LocalACPQuestionRequest: Equatable, Sendable {
    public let title: String?
    public let questions: [LocalACPQuestion]

    public init(title: String? = nil, questions: [LocalACPQuestion]) {
        self.title = title
        self.questions = questions
    }
}

public enum LocalACPQuestionAnswer: Equatable, Sendable {
    case single(String)
    case multiple([String])
}

public struct LocalACPPlanRequest: Equatable, Sendable {
    public let name: String?
    public let overview: String?
    public let markdown: String

    public init(name: String? = nil, overview: String? = nil, markdown: String) {
        self.name = name
        self.overview = overview
        self.markdown = markdown
    }
}

public enum LocalACPInteractionRequest: Equatable, Sendable {
    case questions(LocalACPQuestionRequest)
    case plan(LocalACPPlanRequest)
    case secret(prompt: String)
}

public enum LocalACPInteractionResponse: Equatable, Sendable {
    case answers([String: LocalACPQuestionAnswer])
    case planAccepted(Bool)
    case secret(String)
    case cancelled
}

public enum LocalACPStopReason: String, Sendable {
    case endTurn = "end_turn"
    case cancelled
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
}

public struct LocalACPActiveInputReceipt: Sendable {
    public let completion: Task<LocalACPStopReason?, any Error>

    public init(completion: Task<LocalACPStopReason?, any Error>) {
        self.completion = completion
    }
}

enum LocalACPActiveInputRoute: Equatable, Sendable {
    case acpSteering
    case grokInterjection
    case concurrentPrompt
    case piRPC
    case unsupported
}

public struct LocalACPSlashCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let detail: String?
    public let argumentHint: String?

    public init(name: String, detail: String? = nil, argumentHint: String? = nil) {
        self.name = name
        self.detail = detail
        self.argumentHint = argumentHint
    }
}

public struct LocalACPSessionConfiguration: Equatable, Sendable {
    public var workingDirectory: String?
    public let model: String?
    public let thinking: String?
    public let modelOptions: [String]
    public let thinkingOptions: [String]
    public let slashCommands: [LocalACPSlashCommand]
    public let modelOptionMetadata: [String: SessionOptionMetadata]
    public let thinkingOptionMetadata: [String: SessionOptionMetadata]
    public let permission: String?
    public let permissionOptions: [String]
    public let permissionOptionMetadata: [String: SessionOptionMetadata]

    public static let empty = LocalACPSessionConfiguration()

    public init(
        model: String? = nil,
        thinking: String? = nil,
        modelOptions: [String] = [],
        thinkingOptions: [String] = [],
        slashCommands: [LocalACPSlashCommand] = [],
        modelOptionMetadata: [String: SessionOptionMetadata] = [:],
        thinkingOptionMetadata: [String: SessionOptionMetadata] = [:],
        permission: String? = nil,
        permissionOptions: [String] = [],
        permissionOptionMetadata: [String: SessionOptionMetadata] = [:],
        workingDirectory: String? = nil
    ) {
        self.model = model
        self.thinking = thinking
        self.modelOptions = Self.unique(modelOptions + [model].compactMap { $0 })
        self.thinkingOptions = Self.unique(thinkingOptions)
        self.slashCommands = slashCommands
        self.modelOptionMetadata = modelOptionMetadata
        self.thinkingOptionMetadata = thinkingOptionMetadata
        self.workingDirectory = workingDirectory
        self.permission = permission
        self.permissionOptions = Self.unique(permissionOptions)
        self.permissionOptionMetadata = permissionOptionMetadata
    }

    public func selecting(
        model: String? = nil,
        thinking: String? = nil,
        permission: String? = nil
    ) -> Self {
        Self(
            model: model ?? self.model,
            thinking: thinking ?? self.thinking,
            modelOptions: modelOptions,
            thinkingOptions: thinkingOptions,
            slashCommands: slashCommands,
            modelOptionMetadata: modelOptionMetadata,
            thinkingOptionMetadata: thinkingOptionMetadata,
            permission: permission ?? self.permission,
            permissionOptions: permissionOptions,
            permissionOptionMetadata: permissionOptionMetadata,
            workingDirectory: workingDirectory
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
}

public struct LocalACPInitializedSession: Equatable, Sendable {
    public let sessionID: String
    public let loadedExistingSession: Bool
    public let configuration: LocalACPSessionConfiguration

    public init(
        sessionID: String,
        loadedExistingSession: Bool,
        configuration: LocalACPSessionConfiguration = .empty
    ) {
        self.sessionID = sessionID
        self.loadedExistingSession = loadedExistingSession
        self.configuration = configuration
    }
}

public struct LocalACPConnectionProbe: Equatable, Sendable {
    public let agentName: String?
    public let agentVersion: String?
    public let authenticationMethodIDs: [String]

    public init(
        agentName: String?,
        agentVersion: String?,
        authenticationMethodIDs: [String]
    ) {
        self.agentName = agentName
        self.agentVersion = agentVersion
        self.authenticationMethodIDs = authenticationMethodIDs
    }
}

enum ACPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ACPJSONValue])
    case object([String: ACPJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ACPJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ACPJSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> ACPJSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var arrayValue: [ACPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

}

private struct ACPErrorBody: Codable, Sendable {
    let code: Int?
    let message: String?
    let data: ACPJSONValue?

    init(
        code: Int?,
        message: String?,
        data: ACPJSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.data = data
    }
}

private struct ACPEnvelope: Codable, Sendable {
    let jsonrpc: String?
    let id: ACPJSONValue?
    let method: String?
    let params: ACPJSONValue?
    let result: ACPJSONValue?
    let error: ACPErrorBody?

    init(
        id: ACPJSONValue? = nil,
        method: String? = nil,
        params: ACPJSONValue? = nil,
        result: ACPJSONValue? = nil,
        error: ACPErrorBody? = nil
    ) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

final class ACPLineCursor: @unchecked Sendable {
    static let maximumLineBytes = 10_000_000
    private let handle: FileHandle
    // FileHandle.AsyncBytes shares a blocking I/O actor across handles on macOS.
    // An idle session must not prevent another session from reading its response.
    // All mutable framing state is confined to this cursor's queue.
    private let queue = DispatchQueue(label: "com.wovenmatter.acp-line-reader", qos: .userInitiated)
    private var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
    private var chunkCount = 0
    private var chunkOffset = 0
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func next() async throws -> Data? {
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.readLine(cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func readLine(cancellation: ReadCancellation) throws -> Data? {
        while true {
            try cancellation.check()
            while chunkOffset < chunkCount {
                let byte = chunk[chunkOffset]
                chunkOffset += 1
                if byte == 0x0A {
                    guard !buffer.isEmpty else { continue }
                    let line = buffer
                    buffer.removeAll(keepingCapacity: true)
                    return line
                }
                buffer.append(byte)
                guard buffer.count <= Self.maximumLineBytes else {
                    throw LocalACPClientError.lineTooLarge
                }
            }

            // Poll on a dispatch worker, never on Swift's cooperative executor.
            // The bounded wait lets cancellation finish even if the writer stays open.
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try cancellation.check()
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            chunkCount = count
            chunkOffset = 0
            if count == 0 {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer.removeAll()
                return line
            }
        }
    }

    private final class ReadCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }
}

private final class LocalACPProcessRegistry: @unchecked Sendable {
    static let shared = LocalACPProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func register(_ process: Process) {
        lock.withLock {
            processes[ObjectIdentifier(process)] = process
        }
    }

    func unregister(_ process: Process) {
        _ = lock.withLock {
            processes.removeValue(forKey: ObjectIdentifier(process))
        }
    }

    func terminateAll() {
        let active = lock.withLock {
            let active = Array(processes.values)
            processes.removeAll()
            return active
        }
        for process in active where process.isRunning {
            terminateLocalACPProcessGroup(process, signal: SIGTERM)
        }

        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline, active.contains(where: \.isRunning) {
            usleep(10_000)
        }
        for process in active where process.isRunning {
            terminateLocalACPProcessGroup(process, signal: SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(1)
        while Date() < killDeadline, active.contains(where: \.isRunning) {
            usleep(10_000)
        }
    }
}

func terminateLocalACPProcessGroup(_ process: Process, signal: Int32) {
    let identifier = process.processIdentifier
    guard identifier > 0 else { return }
    if killpg(identifier, signal) != 0 {
        kill(identifier, signal)
    }
}

func localACPProcessGroupIsRunning(_ identifier: pid_t) -> Bool {
    guard identifier > 0 else { return false }
    if killpg(identifier, 0) == 0 {
        return true
    }
    return errno == EPERM
}

public actor LocalACPClient {
    public typealias EventHandler = @Sendable (LocalACPEvent) async throws -> Void
    public typealias PermissionHandler = @Sendable (LocalACPPermissionRequest) async -> String?
    public typealias InteractionHandler = @Sendable (
        LocalACPInteractionRequest
    ) async -> LocalACPInteractionResponse
    private static let latestProtocolVersion: Int64 = 2
    private static let supportedProtocolVersions: ClosedRange<Int64> = 1...2
    private static let resourceNotFoundErrorCode = -32_002

    private let process: Process
    private let input: FileHandle
    private let cursor: ACPLineCursor
    private let runtimeKind: AgentRuntimeKind
    private let workingDirectory: URL
    private var nextID: Int64 = 0
    private var negotiatedProtocolVersion: Int64?
    private var agentName: String?
    private var pendingInitialSystemPrompt: String?
    private var initialSystemPromptInFlight = false
    private var loadSessionSupported = false
    private var steeringSupported = false
    private var sessionID: String?
    // A new session's identity is supplied by its response. Keep early updates
    // in wire order until that identity is known, then apply normal routing.
    private var pendingNewSessionUpdates: [ACPEnvelope]?
    private var configuration = LocalACPSessionConfiguration.empty
    private var configurationHandler: (@Sendable (LocalACPSessionConfiguration) async -> Void)?
    private var modelConfigurationID: String?
    private var modelUsesSessionModelMethod = false
    private var thinkingConfigurationID: String?
    private var permissionConfigurationID: String?
    private var permissionUsesSessionModeMethod = false
    // Native-supported policies include legacy values hidden from the picker.
    // Keep them available to restore an existing conversation without translation.
    private var nativePermissionOptions: [String] = []
    private var permissionStateRevision: UInt64 = 0
    private var cursorPermission: String
    private let requestedPermission: String?
    private var sessionCancellationRequested = false
    private var pendingPermissionRequestIDs: [ACPJSONValue] = []
    private struct PendingCursorRequest {
        let id: ACPJSONValue
        let method: String
    }
    private var pendingCursorRequests: [PendingCursorRequest] = []
    private struct PendingRequest {
        let continuation: AsyncThrowingStream<ACPRequestResponse, any Error>.Continuation
    }
    private struct ACPRequestResponse: Sendable {
        let value: ACPJSONValue?
        let notificationBarrier: Task<Void, any Error>?
    }
    private var pendingRequests: [Int64: PendingRequest] = [:]
    private var readerTask: Task<Void, Never>?
    private var notificationTask: Task<Void, any Error>?
    private let historyRecorder: WorkspaceWireRecorder?
    private var activeEventHandler: EventHandler?
    private var activePermissionHandler: PermissionHandler?
    private var activeInteractionHandler: InteractionHandler?
    private var activePromptRequestCount = 0
    // ACP does not provide an identifier for thought chunks. Keep one stable
    // identity for adjacent deltas, then advance it when another stream kind
    // separates reasoning phases so distinct commentary is not merged.
    private var reasoningPhaseSequence = 0
    private var activeReasoningPhaseID: String?
    private var closed = false
    private var shutdownTask: Task<Void, Never>?

    private init(
        process: Process,
        input: FileHandle,
        cursor: ACPLineCursor,
        runtimeKind: AgentRuntimeKind,
        workingDirectory: URL,
        requestedPermission: String?,
        historyRecorder: WorkspaceWireRecorder? = nil
    ) {
        self.historyRecorder = historyRecorder
        self.requestedPermission = requestedPermission
        self.cursorPermission = requestedPermission ?? "normal"
        self.process = process
        self.input = input
        self.cursor = cursor
        self.runtimeKind = runtimeKind
        self.workingDirectory = workingDirectory.standardizedFileURL
    }

    public static func start(
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL
    ) throws -> LocalACPClient {
        guard launch.runtimeKind != .opencode else {
            throw OpenCodeError.message("OpenCode v1 ACP is no longer supported. Create a new OpenCode v2 server session.")
        }
        let process = Process()
        // Foundation.Process cannot configure POSIX_SPAWN_SETPGROUP. A minimal
        // non-interactive shell wrapper enables job control and then execs the
        // selected adapter without interpolation, leaving the adapter as the
        // process-group leader. Group-wide shutdown also catches CLI and tool
        // subprocesses spawned by the adapter.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let preparedLaunch = try LocalACPSessionPermissions.prepareLaunch(launch)
        process.arguments = [
            "-c",
            #"set -m; exec "$@""#,
            "wovenmatter-local-acp",
            launch.executableURL.path,
        ] + preparedLaunch.arguments
        process.currentDirectoryURL = launch.processWorkingDirectoryURL
            ?? workingDirectory
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launch.environment { environment[key] = value }
        let removedKeys = Set(
            launch.environmentKeysToRemove.map { $0.uppercased() }
        )
        let removedPrefixes = launch.environmentKeyPrefixesToRemove
            .map { $0.uppercased() }
            .filter { !$0.isEmpty }
        environment = environment.filter { key, _ in
            let upperKey = key.uppercased()
            return !removedKeys.contains(upperKey)
                && !removedPrefixes.contains(where: upperKey.hasPrefix)
        }
        environment["WOVENMATTER_LOCAL_ACP"] = "1"
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        LocalACPProcessRegistry.shared.register(process)

        return LocalACPClient(
            process: process,
            input: stdin.fileHandleForWriting,
            cursor: ACPLineCursor(handle: stdout.fileHandleForReading),
            runtimeKind: launch.runtimeKind,
            workingDirectory: workingDirectory,
            requestedPermission: preparedLaunch.explicitPermission,
            historyRecorder: launch.historyRecorder
        )
    }

    public static func probeConnection(
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL,
        timeout: Duration = .seconds(5)
    ) async throws -> LocalACPConnectionProbe {
        let client = try start(
            launch: launch,
            workingDirectory: workingDirectory
        )
        return try await withTaskCancellationHandler {
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await client.shutdown()
            }
            do {
                let probe = try await client.connectionProbe()
                timeoutTask.cancel()
                await client.shutdown()
                return probe
            } catch {
                timeoutTask.cancel()
                await client.shutdown()
                throw error
            }
        } onCancel: {
            Task { await client.shutdown() }
        }
    }

    public func initializeSession(
        workingDirectory: URL,
        existingSessionID: String?,
        title: String?,
        systemPrompt: String? = nil
    ) async throws -> LocalACPInitializedSession {
        _ = try await initializeConnection()
        if runtimeKind == .cursor {
            _ = try await request(
                method: "authenticate",
                params: .object([
                    "methodId": .string(CursorACPSupport.authMethodID),
                ])
            )
        }

        if let existingSessionID, loadSessionSupported {
            let previousSessionID = sessionID
            sessionID = existingSessionID
            do {
                let loaded = try await request(
                    method: "session/load",
                    params: .object([
                        "sessionId": .string(existingSessionID),
                        "cwd": .string(workingDirectory.path),
                        "mcpServers": .array([]),
                    ])
                )
                if runtimeKind == .hermes,
                   loaded?["models"] == nil,
                   loaded?["modelState"] == nil {
                    return try await createSession(
                        workingDirectory: workingDirectory,
                        title: title,
                        systemPrompt: systemPrompt
                    )
                }
                sessionID = existingSessionID
                captureSessionConfiguration(from: loaded)
                try await discoverCursorModelsIfNeeded()
                return LocalACPInitializedSession(
                    sessionID: existingSessionID,
                    loadedExistingSession: true,
                    configuration: configuration
                )
            } catch LocalACPClientError.agent(let code, let message)
                where Self.isMissingSessionError(
                    code: code,
                    message: message,
                    runtimeKind: runtimeKind,
                    expectedSessionID: existingSessionID
                ) {
                // Persisted adapter session IDs are recovery hints. ACP's
                // resource-not-found error proves this one no longer exists,
                // so replace it in the same initialized client. Other failures
                // remain visible rather than silently forking the conversation.
                sessionID = previousSessionID
            } catch {
                sessionID = previousSessionID
                throw error
            }
        }

        return try await createSession(
            workingDirectory: workingDirectory,
            title: title,
            systemPrompt: systemPrompt
        )
    }

    private func connectionProbe() async throws -> LocalACPConnectionProbe {
        let result = try await initializeConnection()
        return LocalACPConnectionProbe(
            agentName: result?["agentInfo"]?["name"]?.stringValue,
            agentVersion: result?["agentInfo"]?["version"]?.stringValue,
            authenticationMethodIDs: result?["authMethods"]?.arrayValue?
                .compactMap { $0["id"]?.stringValue } ?? []
        )
    }

    private func initializeConnection() async throws -> ACPJSONValue? {
        var clientCapabilities: [String: ACPJSONValue] = [:]
        if runtimeKind == .cursor {
            clientCapabilities["_meta"] = .object([
                "parameterizedModelPicker": .bool(true),
            ])
        }
        let initializeResult = try await request(
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(Self.latestProtocolVersion),
                "clientCapabilities": .object(clientCapabilities),
                "clientInfo": .object([
                    "name": .string("Woven Matter"),
                    "version": .string(
                        Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "development"
                    ),
                ]),
            ])
        )
        guard let negotiatedVersion = initializeResult?["protocolVersion"]?.integerValue,
              Self.supportedProtocolVersions.contains(negotiatedVersion) else {
            throw LocalACPClientError.unsupportedProtocolVersion(
                initializeResult?["protocolVersion"]?.integerValue
            )
        }
        negotiatedProtocolVersion = negotiatedVersion
        agentName = initializeResult?["agentInfo"]?["name"]?.stringValue
        loadSessionSupported =
            initializeResult?["agentCapabilities"]?["loadSession"]?.boolValue ?? false
        steeringSupported = initializeResult?["_meta"]?["steering"]?["supported"]?
            .boolValue ?? false
        captureSessionConfiguration(from: initializeResult)
        return initializeResult
    }

    private func createSession(
        workingDirectory: URL,
        title: String?,
        systemPrompt: String?
    ) async throws -> LocalACPInitializedSession {
        var parameters: [String: ACPJSONValue] = [
            "cwd": .string(workingDirectory.path),
            "mcpServers": .array([]),
        ]
        var metadata: [String: ACPJSONValue] = [:]
        if let systemPrompt, !systemPrompt.isEmpty {
            if agentName == "@agentclientprotocol/claude-agent-acp" {
                metadata["systemPrompt"] = .object([
                    "append": .string(systemPrompt),
                ])
            } else if let negotiatedProtocolVersion,
                      negotiatedProtocolVersion >= 2 {
                parameters["systemPrompt"] = .string(systemPrompt)
            } else {
                // ACP v1 has no system-prompt field. Match Buzz's compatibility
                // behavior by carrying the agent definition in the first user
                // turn instead of silently discarding it or refusing the agent.
                pendingInitialSystemPrompt = systemPrompt
            }
        }
        if let title, !title.isEmpty {
            metadata["sessionTitle"] = .string(title)
        }
        if !metadata.isEmpty {
            parameters["_meta"] = .object(metadata)
        }
        pendingNewSessionUpdates = []
        defer { pendingNewSessionUpdates = nil }
        guard let response = try await request(
            method: "session/new",
            params: .object(parameters)
        ), let created = response["sessionId"]?.stringValue, !created.isEmpty else {
            throw LocalACPClientError.missingSessionID
        }
        sessionID = created
        let earlyUpdates = pendingNewSessionUpdates ?? []
        pendingNewSessionUpdates = nil
        for update in earlyUpdates {
            enqueueNotification(update)
        }
        try await notificationTask?.value
        captureSessionConfiguration(from: response)
        try await discoverCursorModelsIfNeeded()
        try await selectNativeAutomaticPermissionMode(
            from: response,
            sessionID: created
        )
        return LocalACPInitializedSession(
            sessionID: created,
            loadedExistingSession: false,
            configuration: configuration
        )
    }

    private func discoverCursorModelsIfNeeded() async throws {
        guard runtimeKind == .cursor else { return }
        do {
            let response = try await request(
                method: "cursor/list_available_models",
                params: .object([:])
            )
            let models = response?["models"]?.arrayValue?.compactMap { value -> String? in
                let identifier = value["value"]?.stringValue
                    ?? value["modelId"]?.stringValue
                let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            } ?? []
            guard !models.isEmpty else { return }
            let catalogMetadata = Self.modelMetadata(response?["models"]?.arrayValue ?? [], idKeys: ["value", "modelId"])
            configuration = LocalACPSessionConfiguration(
                model: configuration.model,
                thinking: configuration.thinking,
                modelOptions: models,
                thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: catalogMetadata.merging(configuration.modelOptionMetadata) { _, session in session },
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: configuration.permission,
                permissionOptions: configuration.permissionOptions,
                permissionOptionMetadata: configuration.permissionOptionMetadata
            )
        } catch {
            // session/new already advertised a catalog; keep that if the
            // Cursor extension method is unavailable.
        }
    }

    /// Claude's ACP adapter advertises its native guarded Auto mode in the
    /// session result. Match Buzz by selecting that stable ACP configuration
    /// option when available. Agents that do not advertise Auto continue to
    /// use Woven Matter's request-permission UI.
    private func selectNativeAutomaticPermissionMode(
        from sessionResult: ACPJSONValue?,
        sessionID: String
    ) async throws {
        guard runtimeKind == .claudeCode,
              requestedPermission == nil,
              let sessionResult,
              Self.automaticPermissionModeIsAvailable(in: sessionResult),
              !Self.automaticPermissionModeIsSelected(in: sessionResult) else {
            return
        }
        _ = try await setSessionPermission("auto")
    }

    private static func automaticPermissionModeIsAvailable(
        in sessionResult: ACPJSONValue
    ) -> Bool {
        let advertisedByLegacyModes = sessionResult["modes"]?["availableModes"]?
            .arrayValue?
            .contains { $0["id"]?.stringValue == "auto" } ?? false
        let advertisedByConfiguration = sessionResult["configOptions"]?
            .arrayValue?
            .first { $0["id"]?.stringValue == "mode" }?["options"]?
            .arrayValue?
            .contains { $0["value"]?.stringValue == "auto" } ?? false
        return advertisedByLegacyModes || advertisedByConfiguration
    }

    private static func automaticPermissionModeIsSelected(
        in sessionResult: ACPJSONValue
    ) -> Bool {
        if sessionResult["modes"]?["currentModeId"]?.stringValue == "auto" {
            return true
        }
        return sessionResult["configOptions"]?
            .arrayValue?
            .first { $0["id"]?.stringValue == "mode" }?["currentValue"]?
            .stringValue == "auto"
    }

    public func sessionConfiguration() -> LocalACPSessionConfiguration {
        configuration
    }

    public func setConfigurationHandler(_ handler: @escaping @Sendable (LocalACPSessionConfiguration) async -> Void) async {
        configurationHandler = handler
        await handler(configuration)
    }

    public func setSessionPermission(_ permission: String) async throws -> LocalACPSessionConfiguration {
        guard let sessionID else { throw LocalACPClientError.sessionNotInitialized }
        let supportedOptions = runtimeKind == .codex || runtimeKind == .claudeCode
            ? nativePermissionOptions : configuration.permissionOptions
        guard !supportedOptions.isEmpty else {
            throw LocalACPClientError.unsupportedConfiguration("permission")
        }
        guard supportedOptions.contains(permission) else {
            throw LocalACPClientError.invalidConfigurationValue(field: "permission", value: permission)
        }
        if configuration.permission == permission { return configuration }
        if runtimeKind == .cursor {
            cursorPermission = permission
            configuration = configuration.selecting(permission: permission)
            await configurationHandler?(configuration)
            return configuration
        }
        if runtimeKind == .grokBuild {
            throw LocalACPClientError.permissionChangeRequiresRestart
        }
        if let permissionConfigurationID {
            let response = try await request(
                method: "session/set_config_option",
                params: .object([
                    "sessionId": .string(sessionID),
                    "configId": .string(permissionConfigurationID),
                    "value": .string(permission),
                ])
            )
            let previous = configuration
            captureSessionConfiguration(from: response)
            if configuration != previous { await configurationHandler?(configuration) }
            guard configuration.permission == permission else {
                throw LocalACPClientError.configurationNotConfirmed("permission")
            }
        } else if permissionUsesSessionModeMethod {
            let revision = permissionStateRevision
            let response = try await request(
                method: "session/set_mode",
                params: .object([
                    "sessionId": .string(sessionID),
                    "modeId": .string(permission),
                ])
            )
            let previous = configuration
            captureSessionConfiguration(from: response)
            // Legacy ACP returns an empty success response after applying an
            // advertised mode. Respect any authoritative update that accompanied
            // that acknowledgement, including a policy clamp to another mode.
            if permissionStateRevision == revision {
                configuration = configuration.selecting(permission: permission)
            }
            if configuration != previous { await configurationHandler?(configuration) }
            guard configuration.permission == permission else {
                throw LocalACPClientError.configurationNotConfirmed("permission")
            }
        } else {
            throw LocalACPClientError.unsupportedConfiguration("permission")
        }
        return configuration
    }

    public func setSessionConfiguration(
        model: String? = nil,
        thinking: String? = nil
    ) async throws -> LocalACPSessionConfiguration {
        guard let sessionID else {
            throw LocalACPClientError.sessionNotInitialized
        }
        if let model {
            let model = runtimeKind == .cursor
                ? CursorACPSupport.baseModelID(model)
                : model
            if let modelConfigurationID {
                try validateConfigurationValue(
                    model,
                    field: "model",
                    options: configuration.modelOptions
                )
                let response = try await request(
                    method: "session/set_config_option",
                    params: .object([
                        "sessionId": .string(sessionID),
                        "configId": .string(modelConfigurationID),
                        "value": .string(model),
                    ])
                )
                captureSessionConfiguration(from: response)
            } else if modelUsesSessionModelMethod {
                try validateConfigurationValue(
                    model,
                    field: "model",
                    options: configuration.modelOptions
                )
                let response = try await request(
                    method: "session/set_model",
                    params: .object([
                        "sessionId": .string(sessionID),
                        "modelId": .string(model),
                    ])
                )
                captureSessionConfiguration(from: response)
                configuration = configuration.selecting(model: model)
            } else {
                throw LocalACPClientError.unsupportedConfiguration("model")
            }
        }
        if let thinking {
            guard let thinkingConfigurationID else {
                throw LocalACPClientError.unsupportedConfiguration("thinking")
            }
            try validateConfigurationValue(
                thinking,
                field: "thinking",
                options: configuration.thinkingOptions
            )
            let response = try await request(
                method: "session/set_config_option",
                params: .object([
                    "sessionId": .string(sessionID),
                    "configId": .string(thinkingConfigurationID),
                    "value": .string(thinking),
                ])
            )
            captureSessionConfiguration(from: response)
        }
        return configuration
    }

    private func validateConfigurationValue(
        _ value: String,
        field: String,
        options: [String]
    ) throws {
        guard options.isEmpty || options.contains(value) else {
            throw LocalACPClientError.invalidConfigurationValue(
                field: field,
                value: value
            )
        }
    }

    public func prompt(
        _ text: String,
        onEvent: EventHandler? = nil,
        onPermission: PermissionHandler? = nil,
        onInteraction: InteractionHandler? = nil
    ) async throws -> LocalACPStopReason {
        try await prompt(
            AgentMessageInput(text: text),
            onEvent: onEvent,
            onPermission: onPermission,
            onInteraction: onInteraction
        )
    }

    public func prompt(
        _ input: AgentMessageInput,
        onEvent: EventHandler? = nil,
        onPermission: PermissionHandler? = nil,
        onInteraction: InteractionHandler? = nil
    ) async throws -> LocalACPStopReason {
        sessionCancellationRequested = false
        return try await beginPrompt(
            input,
            onEvent: onEvent,
            onPermission: onPermission,
            onInteraction: onInteraction
        ).value
    }

    /// Accepts another user message while the session has an active prompt.
    /// Each adapter keeps ownership of delivery semantics: steering extensions
    /// are used only when the provider exposes them, otherwise a concurrent
    /// ACP prompt lets the adapter apply its native queue, redirect, or
    /// stop-and-send behavior.
    public func beginActiveInput(
        _ text: String
    ) async throws -> LocalACPActiveInputReceipt {
        try await beginActiveInput(AgentMessageInput(text: text))
    }

    public func beginActiveInput(
        _ input: AgentMessageInput
    ) async throws -> LocalACPActiveInputReceipt {
        guard let sessionID else {
            throw LocalACPClientError.sessionNotInitialized
        }
        switch Self.activeInputRoute(
            runtimeKind: runtimeKind,
            steeringSupported: steeringSupported
        ) {
        case .acpSteering:
            let response = try await request(
                method: "_session/steering",
                params: .object([
                    "sessionId": .string(sessionID),
                    "prompt": try Self.promptBlocks(input),
                    "_meta": .object([
                        "steering": .object([
                            "idleBehavior": .string("promptRequired"),
                        ]),
                    ]),
                ]),
                waitsForNotifications: false
            )
            switch response?["outcome"]?.stringValue {
            case "injected", "startedNewTurn":
                return LocalACPActiveInputReceipt(completion: Task { nil })
            case "promptRequired":
                return LocalACPActiveInputReceipt(
                    completion: try beginActivePrompt(input)
                )
            default:
                throw LocalACPClientError.invalidActiveInputResponse
            }
        case .grokInterjection:
            if !input.files.isEmpty {
                return LocalACPActiveInputReceipt(
                    completion: try beginActivePrompt(input)
                )
            }
            do {
                _ = try await request(
                    method: "_x.ai/interject",
                    params: .object([
                        "sessionId": .string(sessionID),
                        "text": .string(input.transportText()),
                    ]),
                    waitsForNotifications: false
                )
                return LocalACPActiveInputReceipt(completion: Task { nil })
            } catch LocalACPClientError.agent(let code, _) where code == -32_601 {
                return LocalACPActiveInputReceipt(
                    completion: try beginActivePrompt(input)
                )
            }
        case .concurrentPrompt:
            return LocalACPActiveInputReceipt(
                completion: try beginActivePrompt(input)
            )
        case .piRPC, .unsupported:
            throw LocalACPClientError.activeInputUnsupported
        }
    }

    nonisolated static func activeInputRoute(
        runtimeKind: AgentRuntimeKind,
        steeringSupported: Bool
    ) -> LocalACPActiveInputRoute {
        switch runtimeKind {
        case .codex, .claudeCode:
            steeringSupported ? .acpSteering : .unsupported
        case .grokBuild:
            .grokInterjection
        case .hermes, .cursor, .opencode, .openclaw:
            .concurrentPrompt
        case .pi:
            .piRPC
        }
    }

    private func beginActivePrompt(
        _ input: AgentMessageInput
    ) throws -> Task<LocalACPStopReason?, any Error> {
        let prompt = try beginPrompt(
            input,
            onEvent: activeEventHandler,
            onPermission: activePermissionHandler,
            onInteraction: activeInteractionHandler
        )
        return Task { try await prompt.value }
    }

    private func beginPrompt(
        _ input: AgentMessageInput,
        onEvent: EventHandler?,
        onPermission: PermissionHandler?,
        onInteraction: InteractionHandler?
    ) throws -> Task<LocalACPStopReason, any Error> {
        guard let sessionID else {
            throw LocalACPClientError.sessionNotInitialized
        }
        let outboundText = input.transportText().trimmingCharacters(in: .whitespacesAndNewlines)
        // Native commands must stay at the start of the message. Defer ACP v1's
        // instruction prefix until an ordinary prompt instead of consuming it here.
        let initialSystemPrompt = initialSystemPromptInFlight || outboundText.hasPrefix("/")
            ? nil
            : pendingInitialSystemPrompt
        let prefixedText = initialSystemPrompt.map {
            "[System]\n\($0)\n\n\(outboundText)"
        } ?? outboundText
        let response = try beginRequest(
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": try Self.promptBlocks(input, text: prefixedText),
            ])
        )
        if initialSystemPrompt != nil {
            // A second accepted message must not duplicate the definition,
            // but a transport or agent failure must make it retryable.
            initialSystemPromptInFlight = true
        }
        activeEventHandler = onEvent
        activePermissionHandler = onPermission
        activeInteractionHandler = onInteraction
        activePromptRequestCount += 1
        return Task {
            do {
                let result = try await response.value
                try await result.notificationBarrier?.value
                let reason = try Self.stopReason(from: result.value)
                if let usage = Self.usage(from: result.value) {
                    try await onEvent?(.usage(usage))
                }
                if initialSystemPrompt != nil {
                    self.resolveInitialSystemPrompt(succeeded: true)
                }
                self.promptRequestFinished()
                return reason
            } catch {
                if initialSystemPrompt != nil {
                    self.resolveInitialSystemPrompt(succeeded: false)
                }
                self.promptRequestFinished()
                throw error
            }
        }
    }

    private func promptRequestFinished() {
        activePromptRequestCount = max(0, activePromptRequestCount - 1)
        if activePromptRequestCount == 0 {
            activeEventHandler = nil
            activePermissionHandler = nil
            activeInteractionHandler = nil
        }
    }

    private func resolveInitialSystemPrompt(succeeded: Bool) {
        initialSystemPromptInFlight = false
        if succeeded {
            pendingInitialSystemPrompt = nil
        }
    }

    private nonisolated static func promptBlocks(
        _ input: AgentMessageInput,
        text: String? = nil
    ) throws -> ACPJSONValue {
        var blocks: [ACPJSONValue] = []
        let outboundText = text ?? input.transportText()
        if !outboundText.isEmpty {
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(outboundText),
            ]))
        }
        for file in input.files {
            let data: Data
            do {
                data = try Data(contentsOf: file.localURL, options: [.mappedIfSafe])
            } catch {
                throw AgentMessageAttachmentError.unreadableFile(file.fileName)
            }
            if file.kind == .image {
                blocks.append(.object([
                    "type": .string("image"),
                    "mimeType": .string(file.mimeType),
                    "data": .string(data.base64EncodedString()),
                ]))
            } else if file.mimeType.hasPrefix("text/"),
                      let text = String(data: data, encoding: .utf8) {
                blocks.append(.object([
                    "type": .string("resource"),
                    "resource": .object([
                        "uri": .string(file.localURL.absoluteString),
                        "mimeType": .string(file.mimeType),
                        "text": .string(text),
                    ]),
                ]))
            } else {
                blocks.append(.object([
                    "type": .string("resource_link"),
                    "uri": .string(file.localURL.absoluteString),
                    "name": .string(file.fileName),
                    "mimeType": .string(file.mimeType),
                    "size": .integer(file.sizeBytes),
                ]))
            }
        }
        return .array(blocks)
    }

    private nonisolated static func stopReason(
        from result: ACPJSONValue?
    ) throws -> LocalACPStopReason {
        guard let raw = result?["stopReason"]?.stringValue,
              let reason = LocalACPStopReason(rawValue: raw.lowercased()) else {
            throw LocalACPClientError.invalidStopReason
        }
        return reason
    }

    private nonisolated static func usage(
        from result: ACPJSONValue?
    ) -> UsageTokenCounts? {
        guard let usage = result?["usage"],
              let input = usage["inputTokens"]?.integerValue,
              let output = usage["outputTokens"]?.integerValue else { return nil }
        return UsageTokenCounts(
            inputTokens: input,
            cachedInputTokens: usage["cachedReadTokens"]?.integerValue ?? 0,
            cacheCreationTokens: usage["cachedWriteTokens"]?.integerValue ?? 0,
            outputTokens: output,
            reasoningTokens: usage["thoughtTokens"]?.integerValue ?? 0,
            reportedTotalTokens: usage["totalTokens"]?.integerValue
        )
    }

    public func cancel() throws {
        guard let sessionID else { return }
        sessionCancellationRequested = true
        let pending = pendingPermissionRequestIDs
        pendingPermissionRequestIDs.removeAll()
        for id in pending {
            try respondWithCancelledPermission(id: id)
        }
        let cursorRequests = pendingCursorRequests
        pendingCursorRequests.removeAll()
        for request in cursorRequests {
            try respondToCancelledCursorRequest(request)
        }
        try write(ACPEnvelope(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)])
        ))
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        readerTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        failPendingRequests(with: LocalACPClientError.processExited)
        try? input.close()
        let trackedProcess = process
        let processGroupIdentifier = trackedProcess.processIdentifier
        let task = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { [trackedProcess] in
                    if localACPProcessGroupIsRunning(processGroupIdentifier) {
                        terminateLocalACPProcessGroup(trackedProcess, signal: SIGTERM)
                    }
                    let terminationDeadline = Date().addingTimeInterval(2)
                    while localACPProcessGroupIsRunning(processGroupIdentifier),
                          Date() < terminationDeadline {
                        usleep(10_000)
                    }
                    if localACPProcessGroupIsRunning(processGroupIdentifier) {
                        terminateLocalACPProcessGroup(trackedProcess, signal: SIGKILL)
                    }
                    // Foundation can block indefinitely if waitUntilExit races
                    // a process that it already observed and reaped. Only wait
                    // while the Process object still reports a live leader;
                    // process-group disappearance remains the final drain proof.
                    if trackedProcess.isRunning {
                        trackedProcess.waitUntilExit()
                    }
                    while localACPProcessGroupIsRunning(processGroupIdentifier) {
                        usleep(10_000)
                    }
                    LocalACPProcessRegistry.shared.unregister(trackedProcess)
                    continuation.resume()
                }
            }
        }
        shutdownTask = task
        await task.value
    }

    public nonisolated static func terminateAllProcesses() {
        LocalACPProcessRegistry.shared.terminateAll()
    }

    private func request(
        method: String,
        params: ACPJSONValue,
        waitsForNotifications: Bool = true
    ) async throws -> ACPJSONValue? {
        let response = try await beginRequest(
            method: method,
            params: params
        ).value
        if waitsForNotifications {
            try await response.notificationBarrier?.value
        }
        return response.value
    }

    private func beginRequest(
        method: String,
        params: ACPJSONValue
    ) throws -> Task<ACPRequestResponse, any Error> {
        startReaderIfNeeded()
        let id = nextID
        nextID += 1
        let pair = AsyncThrowingStream<ACPRequestResponse, any Error>.makeStream()
        pendingRequests[id] = PendingRequest(continuation: pair.continuation)
        do {
            try write(ACPEnvelope(
                id: .integer(id),
                method: method,
                params: params
            ))
        } catch {
            pendingRequests.removeValue(forKey: id)
            pair.continuation.finish(throwing: error)
            throw error
        }
        return Task {
            var iterator = pair.stream.makeAsyncIterator()
            guard let response = try await iterator.next() else {
                throw LocalACPClientError.processExited
            }
            return response
        }
    }

    private func startReaderIfNeeded() {
        guard readerTask == nil, !closed else { return }
        let cursor = cursor
        readerTask = Task { [weak self, cursor] in
            do {
                while !Task.isCancelled,
                      let data = try await cursor.next() {
                    guard let self else { return }
                    try await self.receive(data)
                }
                guard !Task.isCancelled else { return }
                await self?.readerFailed(LocalACPClientError.processExited)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.readerFailed(error)
            }
        }
    }

    private func receive(_ data: Data) throws {
        try historyRecorder?("in", data)
        let envelope = try Self.decodeEnvelope(data)
        if envelope.method == nil,
           let id = envelope.id?.integerValue,
           let pending = pendingRequests.removeValue(forKey: id) {
            if let error = envelope.error {
                pending.continuation.finish(
                    throwing: Self.agentError(error)
                )
            } else {
                pending.continuation.yield(ACPRequestResponse(
                    value: envelope.result,
                    notificationBarrier: notificationTask
                ))
                pending.continuation.finish()
            }
            return
        }
        if envelope.method == "session/update", pendingNewSessionUpdates != nil {
            pendingNewSessionUpdates?.append(envelope)
            return
        }
        enqueueNotification(envelope)
    }

    private func enqueueNotification(_ envelope: ACPEnvelope) {
        let previous = notificationTask
        let task = Task<Void, any Error> { [weak self] in
            try await previous?.value
            guard let self else { return }
            try Task.checkCancellation()
            try await self.handleNotification(envelope)
        }
        notificationTask = task
        Task { [weak self] in
            do {
                try await task.value
            } catch {
                guard !(error is CancellationError) else { return }
                await self?.readerFailed(error)
            }
        }
    }

    private func handleNotification(_ envelope: ACPEnvelope) async throws {
        if envelope.method == "session/update" {
            let update = envelope.params?["update"]
            switch update?["sessionUpdate"]?.stringValue {
            case "config_option_update", "available_commands_update", "current_mode_update":
                guard belongsToActiveSession(envelope) else { return }
                let previousConfiguration = configuration
                captureSessionConfiguration(from: update)
                if previousConfiguration != configuration { await configurationHandler?(configuration) }
            default:
                break
            }
            if let event = projectedEvent(
                from: envelope,
                workingDirectory: workingDirectory
            ) {
                try await activeEventHandler?(event)
            }
        } else if envelope.method == "session/request_permission" {
            try await respondToPermissionRequest(
                envelope,
                handler: activePermissionHandler
            )
        } else if envelope.method == "cursor/ask_question" {
            try await respondToCursorQuestion(
                envelope,
                handler: activeInteractionHandler
            )
        } else if envelope.method == "cursor/create_plan" {
            if let event = Self.cursorPlanEvent(from: envelope) {
                try await activeEventHandler?(event)
            }
            try await respondToCursorPlan(
                envelope,
                handler: activeInteractionHandler
            )
        } else if envelope.method == "cursor/update_todos" {
            if let event = Self.cursorTodoEvent(from: envelope) {
                try await activeEventHandler?(event)
            }
        } else if envelope.method != nil, envelope.id != nil {
            try write(ACPEnvelope(
                id: envelope.id,
                error: ACPErrorBody(code: -32601, message: "Method not found")
            ))
        }
    }

    private func belongsToActiveSession(_ envelope: ACPEnvelope) -> Bool {
        guard pendingNewSessionUpdates == nil else { return false }
        // Older adapters omit the identity on their single-session connection.
        // An explicit identity, including an invalid one, never uses that fallback.
        guard let value = envelope.params?["sessionId"] else { return true }
        guard let incomingSessionID = value.stringValue, !incomingSessionID.isEmpty else { return false }
        return incomingSessionID == sessionID
    }

    private func readerFailed(_ error: any Error) {
        failPendingRequests(with: error)
    }

    private func failPendingRequests(with error: any Error) {
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.continuation.finish(throwing: error)
        }
    }

    private func captureSessionConfiguration(from value: ACPJSONValue?) {
        guard let value else { return }
        // Codex/Claude modes govern approval policy. Cursor's agent/plan/ask
        // modes govern execution and must not appear as permission choices.
        if runtimeKind == .codex || runtimeKind == .claudeCode,
           let modes = value["modes"],
           let available = modes["availableModes"]?.arrayValue {
            permissionStateRevision &+= 1
            permissionUsesSessionModeMethod = true
            nativePermissionOptions = available.compactMap { $0["id"]?.stringValue }
            configuration = LocalACPSessionConfiguration(
                model: configuration.model, thinking: configuration.thinking,
                modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: modes["currentModeId"]?.stringValue,
                permissionOptions: LocalACPSessionPermissions.nativeOptions(runtimeKind: runtimeKind, options: nativePermissionOptions),
                permissionOptionMetadata: LocalACPSessionPermissions.nativeMetadata(runtimeKind: runtimeKind, options: available, idKeys: ["id"])
            )
        }
        if permissionConfigurationID != nil || permissionUsesSessionModeMethod,
           let currentMode = value["currentModeId"]?.stringValue {
            permissionStateRevision &+= 1
            configuration = configuration.selecting(permission: currentMode)
        }
        if let commands = value["availableCommands"]?.arrayValue {
            var seen: Set<String> = []
            let slashCommands = commands.compactMap { command -> LocalACPSlashCommand? in
                guard let name = command["name"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, seen.insert(name).inserted else { return nil }
                return LocalACPSlashCommand(
                    name: name,
                    detail: command["description"]?.stringValue,
                    argumentHint: command["input"]?["hint"]?.stringValue
                )
            }
            configuration = LocalACPSessionConfiguration(
                model: configuration.model,
                thinking: configuration.thinking,
                modelOptions: configuration.modelOptions,
                thinkingOptions: configuration.thinkingOptions,
                slashCommands: slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: configuration.permission,
                permissionOptions: configuration.permissionOptions,
                permissionOptionMetadata: configuration.permissionOptionMetadata
            )
        }
        if let configOptions = value["configOptions"]?.arrayValue {
            let parsed = configurationOptions(from: configOptions)
            let hadModelOption = modelConfigurationID != nil
            let hadPermissionOption = permissionConfigurationID != nil
            modelConfigurationID = parsed.model?.id
            thinkingConfigurationID = parsed.thinking?.id
            permissionConfigurationID = parsed.permission?.id
            if parsed.permission != nil || hadPermissionOption {
                permissionStateRevision &+= 1
                nativePermissionOptions = parsed.permission?.options ?? []
            }
            if hadPermissionOption && parsed.permission == nil {
                permissionUsesSessionModeMethod = false
            }
            // ACP publishes the complete current option list. A model switch
            // may remove effort support; do not retain its old menu or setter.
            configuration = LocalACPSessionConfiguration(
                model: parsed.model?.currentValue ?? (hadModelOption ? nil : configuration.model),
                thinking: parsed.thinking?.currentValue,
                modelOptions: parsed.model?.options ?? (hadModelOption ? [] : configuration.modelOptions),
                thinkingOptions: parsed.thinking?.options ?? [],
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: parsed.model?.metadata ?? (hadModelOption ? [:] : configuration.modelOptionMetadata),
                thinkingOptionMetadata: parsed.thinking?.metadata ?? [:],
                permission: parsed.permission?.currentValue ?? (hadPermissionOption ? nil : configuration.permission),
                permissionOptions: parsed.permission.map {
                    LocalACPSessionPermissions.nativeOptions(runtimeKind: runtimeKind, options: $0.options)
                } ?? (hadPermissionOption ? [] : configuration.permissionOptions),
                permissionOptionMetadata: parsed.permission?.metadata ?? (hadPermissionOption ? [:] : configuration.permissionOptionMetadata)
            )
        }

        // Some adapters publish both the writable `configOptions` contract and
        // a legacy `models` catalog. Codex ACP's legacy catalog expands every
        // base model into model[reasoning-effort] variants, while its model and
        // reasoning config options are intentionally independent. Once a model
        // config option is advertised, keep it authoritative instead of
        // replacing it with that compatibility catalog.
        if modelConfigurationID == nil,
           let modelState = Self.standardModelConfiguration(from: value) {
            modelUsesSessionModelMethod = true
            configuration = LocalACPSessionConfiguration(
                model: modelState.model ?? configuration.model,
                thinking: configuration.thinking,
                modelOptions: modelState.options,
                thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: modelState.metadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: configuration.permission,
                permissionOptions: configuration.permissionOptions,
                permissionOptionMetadata: configuration.permissionOptionMetadata
            )
        }
        if let grokConfiguration = Self.grokConfiguration(from: value) {
            configuration = LocalACPSessionConfiguration(
                model: grokConfiguration.model ?? configuration.model,
                thinking: grokConfiguration.thinking ?? configuration.thinking,
                // Vendor model state reports what is active, but not a
                // writable ACP configuration contract. Keep only choices
                // independently advertised by standard `configOptions`.
                modelOptions: configuration.modelOptions,
                thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: grokConfiguration.modelOptionMetadata.merging(configuration.modelOptionMetadata) { _, standard in standard },
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: configuration.permission,
                permissionOptions: configuration.permissionOptions,
                permissionOptionMetadata: configuration.permissionOptionMetadata
            )
        }
        if runtimeKind == .claudeCode {
            configuration = LocalACPSessionConfiguration(
                model: configuration.model, thinking: configuration.thinking,
                modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata.reduce(into: [:]) { result, entry in
                    result[entry.key] = ClaudeModelPresentation.metadata(id: entry.key, supplied: entry.value)
                },
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: configuration.permission,
                permissionOptions: configuration.permissionOptions,
                permissionOptionMetadata: configuration.permissionOptionMetadata
            )
        }
        if runtimeKind == .grokBuild {
            // Grok reports model/effort over ACP, but not its effective permission
            // setting. This is the explicit native CLI policy of this process;
            // nil preserves an unknown inherited policy until the user chooses.
            configuration = LocalACPSessionConfiguration(
                model: configuration.model, thinking: configuration.thinking,
                modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: requestedPermission,
                permissionOptions: LocalACPSessionPermissions.grokOptions(currentPermission: requestedPermission),
                permissionOptionMetadata: LocalACPSessionPermissions.grokMetadata
            )
        }
        if runtimeKind == .cursor {
            // Cursor's ACP mode is an execution mode, and --force can persist in
            // its native session. This picker controls only requests delivered
            // to this client, without changing either native setting.
            configuration = LocalACPSessionConfiguration(
                model: configuration.model, thinking: configuration.thinking,
                modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: cursorPermission,
                permissionOptions: LocalACPSessionPermissions.cursorOptions,
                permissionOptionMetadata: LocalACPSessionPermissions.cursorMetadata
            )
        }
    }

    private struct ParsedConfigurationOption {
        let id: String
        let currentValue: String?
        let options: [String]
        let metadata: [String: SessionOptionMetadata]
    }

    private func configurationOptions(
        from options: [ACPJSONValue]
    ) -> (
        model: ParsedConfigurationOption?,
        thinking: ParsedConfigurationOption?,
        permission: ParsedConfigurationOption?
    ) {
        var model: ParsedConfigurationOption?
        var thinking: ParsedConfigurationOption?
        var permission: ParsedConfigurationOption?
        for option in options {
            guard let id = option["id"]?.stringValue else { continue }
            let category = option["category"]?.stringValue
            let parsed = ParsedConfigurationOption(
                id: id,
                currentValue: option["currentValue"]?.stringValue,
                options: Self.configurationOptionValues(
                    option["options"]?.arrayValue ?? []
                ),
                metadata: Self.configurationOptionMetadata(option["options"]?.arrayValue ?? [])
            )
            if id == "model" || category == "model" {
                model = parsed
            } else if category == "thought_level"
                        || ["effort", "reasoning_effort", "thinking"].contains(id) {
                thinking = parsed
            } else if ["permission_mode", "approval_mode"].contains(id)
                        || (id == "mode" && (runtimeKind == .codex || runtimeKind == .claudeCode)) {
                permission = ParsedConfigurationOption(
                    id: parsed.id, currentValue: parsed.currentValue,
                    options: parsed.options,
                    metadata: LocalACPSessionPermissions.nativeMetadata(runtimeKind: runtimeKind,
                        options: option["options"]?.arrayValue ?? [], idKeys: ["value"])
                )
            }
        }
        return (model, thinking, permission)
    }

    private static func configurationOptionValues(
        _ options: [ACPJSONValue]
    ) -> [String] {
        options.flatMap { option -> [String] in
            if let value = option["value"]?.stringValue {
                return [value]
            }
            return configurationOptionValues(
                option["options"]?.arrayValue ?? []
            )
        }
    }

    private static func configurationOptionMetadata(_ options: [ACPJSONValue]) -> [String: SessionOptionMetadata] {
        var result: [String: SessionOptionMetadata] = [:]
        for option in options {
            if let id = option["value"]?.stringValue {
                result[id] = SessionOptionMetadata(name: option["name"]?.stringValue,
                    description: option["description"]?.stringValue)
            } else {
                result.merge(configurationOptionMetadata(option["options"]?.arrayValue ?? [])) { _, latest in latest }
            }
        }
        return result
    }

    private static func modelMetadata(_ models: [ACPJSONValue], idKeys: [String]) -> [String: SessionOptionMetadata] {
        var result: [String: SessionOptionMetadata] = [:]
        for model in models {
            guard let id = idKeys.compactMap({ model[$0]?.stringValue }).first else { continue }
            result[id] = SessionOptionMetadata(name: model["name"]?.stringValue,
                description: model["description"]?.stringValue)
        }
        return result
    }

    private static func standardModelConfiguration(
        from value: ACPJSONValue
    ) -> (model: String?, options: [String], metadata: [String: SessionOptionMetadata])? {
        guard let modelState = value["models"],
              let models = modelState["availableModels"]?.arrayValue else {
            return nil
        }
        let options = models.compactMap { $0["modelId"]?.stringValue }
        guard !options.isEmpty else { return nil }
        return (modelState["currentModelId"]?.stringValue, options, modelMetadata(models, idKeys: ["modelId"]))
    }

    private static func grokConfiguration(
        from value: ACPJSONValue
    ) -> LocalACPSessionConfiguration? {
        guard let modelState = value["_meta"]?["modelState"]
                ?? value["modelState"],
              let models = modelState["availableModels"]?.arrayValue else {
            return nil
        }
        let currentModel = modelState["currentModelId"]?.stringValue
        let currentModelDefinition = models.first {
            $0["modelId"]?.stringValue == currentModel
        }
        let metadata = currentModelDefinition?["_meta"]
        let thinking = modelState["currentReasoningEffort"]?.stringValue
            ?? metadata?["currentReasoningEffort"]?.stringValue
            ?? metadata?["reasoningEffort"]?.stringValue
        return LocalACPSessionConfiguration(
            model: currentModel,
            thinking: thinking,
            // Vendor state alone does not advertise writable options. Prefer
            // standard configOptions when the adapter supplies that contract.
            modelOptions: [],
            thinkingOptions: [],
            modelOptionMetadata: modelMetadata(models, idKeys: ["modelId"])
        )
    }

    private func respondToPermissionRequest(
        _ envelope: ACPEnvelope,
        handler: PermissionHandler?
    ) async throws {
        if runtimeKind == .cursor,
           let id = envelope.id,
           let requestSessionID = envelope.params?["sessionId"]?.stringValue,
           let sessionID, requestSessionID != sessionID {
            try respondWithCancelledPermission(id: id)
            return
        }
        guard let id = envelope.id,
              let rawOptions = envelope.params?["options"]?.arrayValue else {
            throw LocalACPClientError.invalidPermissionRequest
        }
        let options = rawOptions.compactMap { value -> LocalACPPermissionOption? in
            guard let id = value["optionId"]?.stringValue,
                  let kind = value["kind"]?.stringValue else { return nil }
            return LocalACPPermissionOption(
                id: id,
                name: value["name"]?.stringValue ?? kind.replacingOccurrences(of: "_", with: " "),
                kind: kind
            )
        }
        guard !options.isEmpty else {
            throw LocalACPClientError.invalidPermissionRequest
        }
        let title = envelope.params?["toolCall"]?["title"]?.stringValue
            ?? envelope.params?["title"]?.stringValue
            ?? "The local agent is requesting permission."
        let request = LocalACPPermissionRequest(title: title, options: options)

        guard !sessionCancellationRequested else {
            try respondWithCancelledPermission(id: id)
            return
        }
        pendingPermissionRequestIDs.append(id)
        let selectedID: String?
        // Cursor's persisted `auto` value means Full access in this client.
        // It does not invoke the native Smart Auto classifier or set sticky --force.
        if runtimeKind == .cursor, cursorPermission == "auto",
           let sessionID, envelope.params?["sessionId"]?.stringValue == sessionID,
           // Cursor's question fallback uses allow_once for answer choices.
           // Those are user input, not approval of a tool operation.
           !options.contains(where: { $0.id == "__ask_question_skip__" }),
           options.filter({ $0.kind == "allow_once" }).count == 1,
           let allowOnce = options.first(where: { $0.kind == "allow_once" }) {
            selectedID = allowOnce.id
        } else {
            selectedID = await handler?(request)
        }
        guard let pendingIndex = pendingPermissionRequestIDs.firstIndex(of: id) else {
            return
        }
        pendingPermissionRequestIDs.remove(at: pendingIndex)
        let selected = selectedID.flatMap { candidate in
            options.first { $0.id == candidate }
        } ?? options.first { $0.kind == "reject_once" }

        if let selected {
            try write(ACPEnvelope(
                id: id,
                result: .object([
                    "outcome": .object([
                        "outcome": .string("selected"),
                        "optionId": .string(selected.id),
                    ])
                ])
            ))
        } else {
            try respondWithCancelledPermission(id: id)
        }
    }

    private func respondToCursorQuestion(
        _ envelope: ACPEnvelope,
        handler: InteractionHandler?
    ) async throws {
        guard let id = envelope.id,
              envelope.params?["toolCallId"]?.stringValue != nil,
              let rawQuestions = envelope.params?["questions"]?.arrayValue else {
            throw LocalACPClientError.invalidCursorExtension("cursor/ask_question")
        }
        let questions = rawQuestions.compactMap { value -> LocalACPQuestion? in
            guard let questionID = value["id"]?.stringValue,
                  let prompt = value["prompt"]?.stringValue,
                  let rawOptions = value["options"]?.arrayValue else { return nil }
            var options = rawOptions.compactMap { option -> LocalACPQuestionOption? in
                guard let optionID = option["id"]?.stringValue,
                      let label = option["label"]?.stringValue else { return nil }
                return LocalACPQuestionOption(id: optionID, label: label)
            }
            guard options.count == rawOptions.count,
                  value["allowMultiple"] == nil
                    || value["allowMultiple"]?.boolValue != nil else { return nil }
            if options.isEmpty {
                options = [LocalACPQuestionOption(id: "ok", label: "OK")]
            }
            return LocalACPQuestion(
                id: questionID,
                prompt: prompt,
                options: options,
                allowsMultiple: value["allowMultiple"]?.boolValue == true
            )
        }
        guard questions.count == rawQuestions.count, !questions.isEmpty else {
            throw LocalACPClientError.invalidCursorExtension("cursor/ask_question")
        }
        let request = LocalACPQuestionRequest(
            title: envelope.params?["title"]?.stringValue,
            questions: questions
        )
        let pending = PendingCursorRequest(id: id, method: "cursor/ask_question")
        pendingCursorRequests.append(pending)
        let response = await handler?(.questions(request)) ?? .cancelled
        guard removePendingCursorRequest(id: id) else { return }

        let answers: [String: ACPJSONValue]
        if case .answers(let values) = response {
            answers = values.mapValues { answer in
                switch answer {
                case .single(let value):
                    .string(value)
                case .multiple(let values):
                    .array(values.map(ACPJSONValue.string))
                }
            }
        } else {
            answers = [:]
        }
        try write(ACPEnvelope(
            id: id,
            result: .object(["answers": .object(answers)])
        ))
    }

    private func respondToCursorPlan(
        _ envelope: ACPEnvelope,
        handler: InteractionHandler?
    ) async throws {
        guard let id = envelope.id,
              envelope.params?["toolCallId"]?.stringValue != nil,
              let markdown = envelope.params?["plan"]?.stringValue,
              envelope.params?["todos"]?.arrayValue != nil else {
            throw LocalACPClientError.invalidCursorExtension("cursor/create_plan")
        }
        let request = LocalACPPlanRequest(
            name: envelope.params?["name"]?.stringValue,
            overview: envelope.params?["overview"]?.stringValue,
            markdown: markdown.isEmpty
                ? "# Plan\n\n(Cursor did not supply plan text.)"
                : markdown
        )
        let pending = PendingCursorRequest(id: id, method: "cursor/create_plan")
        pendingCursorRequests.append(pending)
        let response = await handler?(.plan(request)) ?? .cancelled
        guard removePendingCursorRequest(id: id) else { return }
        let accepted = if case .planAccepted(let accepted) = response {
            accepted
        } else {
            false
        }
        try write(ACPEnvelope(
            id: id,
            result: .object(["accepted": .bool(accepted)])
        ))
    }

    private func removePendingCursorRequest(id: ACPJSONValue) -> Bool {
        guard let index = pendingCursorRequests.firstIndex(where: { $0.id == id }) else {
            return false
        }
        pendingCursorRequests.remove(at: index)
        return true
    }

    private func respondToCancelledCursorRequest(
        _ request: PendingCursorRequest
    ) throws {
        let result: ACPJSONValue = if request.method == "cursor/create_plan" {
            .object(["accepted": .bool(false)])
        } else {
            .object(["answers": .object([:])])
        }
        try write(ACPEnvelope(id: request.id, result: result))
    }

    private func respondWithCancelledPermission(id: ACPJSONValue) throws {
        try write(ACPEnvelope(
            id: id,
            result: .object([
                "outcome": .object(["outcome": .string("cancelled")])
            ])
        ))
    }

    private func write(_ envelope: ACPEnvelope) throws {
        guard !closed else { throw LocalACPClientError.processExited }
        var data = try JSONEncoder().encode(envelope)
        try historyRecorder?("out", data)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private static func decodeEnvelope(_ data: Data) throws -> ACPEnvelope {
        do {
            return try JSONDecoder().decode(ACPEnvelope.self, from: data)
        } catch {
            throw LocalACPClientError.invalidResponse(error.localizedDescription)
        }
    }

    private static func agentError(_ error: ACPErrorBody) -> LocalACPClientError {
        let detail = error.data?["details"]?.stringValue
        let dataMessage = error.data?["message"]?.stringValue
        let message = [error.message, detail, dataMessage]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { messages, candidate in
                if !messages.contains(candidate) {
                    messages.append(candidate)
                }
            }
            .joined(separator: ": ")
        return .agent(
            code: error.code ?? -32_000,
            message: message.isEmpty ? "Unknown ACP error" : message
        )
    }

    private static func isMissingSessionError(
        code: Int,
        message: String,
        runtimeKind: AgentRuntimeKind,
        expectedSessionID: String
    ) -> Bool {
        if code == resourceNotFoundErrorCode {
            return true
        }
        if runtimeKind == .cursor, code == -32_602 {
            return message.localizedCaseInsensitiveContains(
                "session \"\(expectedSessionID)\" not found"
            )
        }
        return runtimeKind == .codex
            && code == -32_603
            && message.localizedCaseInsensitiveContains(
                "no rollout found for thread id"
            )
    }

    private func projectedEvent(
        from envelope: ACPEnvelope,
        workingDirectory: URL
    ) -> LocalACPEvent? {
        guard let update = envelope.params?["update"],
              let kind = update["sessionUpdate"]?.stringValue else { return nil }
        switch kind {
        case "agent_message_chunk":
            activeReasoningPhaseID = nil
            return update["content"]?["text"]?.stringValue.map(LocalACPEvent.assistantChunk)
        case "agent_thought_chunk":
            guard let text = update["content"]?["text"]?.stringValue else { return nil }
            let reasoningID: String
            if let activeReasoningPhaseID {
                reasoningID = activeReasoningPhaseID
            } else {
                reasoningPhaseSequence += 1
                reasoningID = "thought-\(reasoningPhaseSequence)"
                activeReasoningPhaseID = reasoningID
            }
            return .activity(
                AgentRunActivity(
                    id: reasoningID,
                    kind: .thought,
                    phase: "update",
                    title: "Thinking",
                    status: "running",
                    content: text,
                    contentIsDelta: true,
                    rawPayloadJSON: Self.jsonString(update)
                ),
                appendsContent: true
            )
        case "tool_call":
            activeReasoningPhaseID = nil
            return .activity(
                Self.toolActivity(update, phase: "start", workingDirectory: workingDirectory),
                appendsContent: false
            )
        case "tool_call_update":
            activeReasoningPhaseID = nil
            return .activity(
                Self.toolActivity(update, phase: "update", workingDirectory: workingDirectory),
                appendsContent: false
            )
        case "plan":
            activeReasoningPhaseID = nil
            let entries = update["entries"]?.arrayValue?.compactMap { value -> AgentRunPlanEntry? in
                guard let content = value["content"]?.stringValue,
                      let status = value["status"]?.stringValue else { return nil }
                return AgentRunPlanEntry(
                    content: content,
                    priority: value["priority"]?.stringValue,
                    status: status
                )
            } ?? []
            return .activity(
                AgentRunActivity(
                    id: "plan",
                    kind: .plan,
                    phase: entries.isEmpty ? "clear" : "update",
                    title: "Plan",
                    status: entries.allSatisfy { $0.status == "completed" } ? "completed" : "running",
                    planEntries: entries,
                    rawPayloadJSON: Self.jsonString(update)
                ),
                appendsContent: false
            )
        default:
            return nil
        }
    }

    private static func cursorTodoEvent(from envelope: ACPEnvelope) -> LocalACPEvent? {
        guard let params = envelope.params,
              let toolCallID = params["toolCallId"]?.stringValue,
              params["merge"]?.boolValue != nil,
              let rawTodos = params["todos"]?.arrayValue else { return nil }
        let entries = rawTodos.compactMap(cursorPlanEntry)
        return .activity(
            AgentRunActivity(
                id: toolCallID,
                kind: .plan,
                phase: "update",
                title: "Plan",
                status: entries.allSatisfy { $0.status == "completed" }
                    ? "completed"
                    : "running",
                planEntries: entries,
                rawPayloadJSON: jsonString(params)
            ),
            appendsContent: false
        )
    }

    private static func cursorPlanEvent(from envelope: ACPEnvelope) -> LocalACPEvent? {
        guard let params = envelope.params,
              let toolCallID = params["toolCallId"]?.stringValue,
              let markdown = params["plan"]?.stringValue,
              let rawTodos = params["todos"]?.arrayValue else { return nil }
        let entries = rawTodos.compactMap(cursorPlanEntry)
        return .activity(
            AgentRunActivity(
                id: toolCallID,
                kind: .plan,
                phase: "update",
                title: params["name"]?.stringValue ?? "Proposed plan",
                status: "completed",
                content: markdown.nilIfEmpty,
                planEntries: entries,
                rawPayloadJSON: jsonString(params)
            ),
            appendsContent: false
        )
    }

    private static func cursorPlanEntry(_ value: ACPJSONValue) -> AgentRunPlanEntry? {
        let content = value["content"]?.stringValue?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let title = value["title"]?.stringValue?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let step = [content, title]
            .compactMap({ $0 })
            .first(where: { !$0.isEmpty }) else { return nil }
        let status = switch value["status"]?.stringValue {
        case "completed": "completed"
        case "in_progress", "inProgress": "in_progress"
        case "cancelled", "canceled": "cancelled"
        default: "pending"
        }
        return AgentRunPlanEntry(content: step, status: status)
    }

    private static func toolActivity(
        _ update: ACPJSONValue,
        phase: String,
        workingDirectory: URL
    ) -> AgentRunActivity {
        let contentItems = update["content"]?.arrayValue ?? []
        var textParts: [String] = []
        var changes: [AgentRunFileChange] = []
        for item in contentItems {
            switch item["type"]?.stringValue {
            case "content":
                if let text = item["content"]?["text"]?.stringValue, !text.isEmpty {
                    textParts.append(text)
                }
            case "diff":
                if let path = item["path"]?.stringValue,
                   let newText = item["newText"]?.stringValue {
                    changes.append(AgentRunFileChange(
                        path: workspaceRelativePath(path, root: workingDirectory),
                        oldText: item["oldText"]?.stringValue,
                        newText: newText,
                        unifiedDiff: item["diff"]?.stringValue
                    ))
                }
            default:
                break
            }
        }
        let locations = update["locations"]?.arrayValue?.compactMap { value -> AgentRunLocation? in
            guard let path = value["path"]?.stringValue else { return nil }
            return AgentRunLocation(
                path: workspaceRelativePath(path, root: workingDirectory),
                line: value["line"]?.integerValue.flatMap(Int.init(exactly:))
            )
        } ?? []
        let status = update["status"]?.stringValue
        let resolvedPhase = switch status {
        case "completed", "failed": "end"
        case "in_progress": "update"
        default: phase
        }
        return AgentRunActivity(
            id: update["toolCallId"]?.stringValue ?? "tool",
            kind: .tool,
            phase: resolvedPhase,
            title: update["title"]?.stringValue
                ?? (phase == "start" ? displayToolName(update["kind"]?.stringValue) : nil),
            status: status ?? (phase == "start" ? "pending" : nil),
            toolName: update["kind"]?.stringValue,
            content: textParts.joined(separator: "\n\n").nilIfEmpty,
            locations: locations,
            changes: changes,
            rawInputJSON: update["rawInput"].flatMap(jsonString),
            rawOutputJSON: update["rawOutput"].flatMap(jsonString),
            rawPayloadJSON: jsonString(update)
        )
    }

    private static func displayToolName(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Tool" }
        return value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func workspaceRelativePath(_ path: String, root: URL) -> String {
        guard path.hasPrefix("/") else { return path }
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard normalizedPath.hasPrefix(rootPath + "/") else { return path }
        return String(normalizedPath.dropFirst(rootPath.count + 1))
    }

    private static func jsonString(_ value: ACPJSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum LocalACPClientError: LocalizedError, Sendable {
    case invalidLaunchConfiguration
    case lineTooLarge
    case processExited
    case missingSessionID
    case sessionNotInitialized
    case invalidStopReason
    case invalidPermissionRequest
    case activeInputUnsupported
    case invalidActiveInputResponse
    case invalidResponse(String)
    case unsupportedProtocolVersion(Int64?)
    case unsupportedConfiguration(String)
    case configurationNotConfirmed(String)
    case permissionChangeRequiresRestart
    case invalidConfigurationValue(field: String, value: String)
    case invalidCursorExtension(String)
    case agent(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLaunchConfiguration:
            "The local agent's wrapped launch command is invalid."
        case .lineTooLarge:
            "The ACP agent emitted a response larger than 10 MB."
        case .processExited:
            "The ACP agent process exited unexpectedly."
        case .missingSessionID:
            "The ACP agent did not return a session identifier."
        case .sessionNotInitialized:
            "The ACP session has not been initialized."
        case .invalidStopReason:
            "The ACP agent returned an invalid stop reason."
        case .invalidPermissionRequest:
            "The ACP agent returned an invalid permission request."
        case .activeInputUnsupported:
            "This ACP route cannot accept another message during the active turn."
        case .invalidActiveInputResponse:
            "The ACP agent returned an invalid active-message response."
        case .invalidResponse(let detail):
            "The ACP agent returned malformed JSON-RPC: \(detail)"
        case .unsupportedProtocolVersion(let version):
            if let version {
                "The ACP agent negotiated unsupported protocol version \(version)."
            } else {
                "The ACP agent did not return a protocol version."
            }
        case .unsupportedConfiguration(let name):
            "The ACP agent does not expose a selectable \(name) for this session."
        case .configurationNotConfirmed(let name):
            "The ACP agent did not confirm the requested \(name)."
        case .permissionChangeRequiresRestart:
            "This harness requires reconnecting the session to change its permission mode."
        case .invalidConfigurationValue(let field, let value):
            "The ACP agent did not advertise \"\(value)\" as a selectable \(field) for this session."
        case .invalidCursorExtension(let method):
            "Cursor sent an invalid \(method) request."
        case .agent(let code, let message):
            "The ACP agent reported error \(code): \(message)"
        }
    }
}
