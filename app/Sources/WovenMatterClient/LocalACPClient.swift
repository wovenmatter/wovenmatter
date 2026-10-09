import Darwin
import Foundation
import WovenMatterCore

public enum LocalACPEvent: Equatable, Sendable {
    case assistantChunk(String)
    case assistantAsset(LibraryAsset)
    case assistantSnapshot(String)
    case sessionIdentity(String)
    case assistantBoundary
    case activity(AgentRunActivity, appendsContent: Bool)
    case programStatus(ProgramStatus, runID: String?)
    case usage(UsageTokenCounts)
    case composerPrefill(String)
}

public struct LocalACPPermissionOption: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct LocalACPPermissionRequest: Codable, Equatable, Sendable {
    public let title: String
    public let options: [LocalACPPermissionOption]

    public init(title: String, options: [LocalACPPermissionOption]) {
        self.title = title
        self.options = options
    }
}

public struct LocalACPQuestionOption: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct LocalACPQuestion: Codable, Equatable, Identifiable, Sendable {
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

public struct LocalACPQuestionRequest: Codable, Equatable, Sendable {
    public let title: String?
    public let questions: [LocalACPQuestion]

    public init(title: String? = nil, questions: [LocalACPQuestion]) {
        self.title = title
        self.questions = questions
    }
}

public enum LocalACPQuestionAnswer: Codable, Equatable, Sendable {
    case single(String)
    case multiple([String])
}

public struct LocalACPPlanRequest: Codable, Equatable, Sendable {
    public let name: String?
    public let overview: String?
    public let markdown: String

    public init(name: String? = nil, overview: String? = nil, markdown: String) {
        self.name = name
        self.overview = overview
        self.markdown = markdown
    }
}

public enum LocalACPInteractionRequest: Codable, Equatable, Sendable {
    case questions(LocalACPQuestionRequest)
    case plan(LocalACPPlanRequest)
    case secret(prompt: String)
}

public enum LocalACPInteractionResponse: Codable, Equatable, Sendable {
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

public enum LocalACPActiveInputRoute: String, Codable, Equatable, Sendable {
    case acpSteering
    case grokInterjection
    case hermesGateway
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
    public let fallbackNotice: String?
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
        fallbackNotice: String? = nil,
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
        self.fallbackNotice = fallbackNotice
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
    public let recoveredDefaultAgentRuns: [DefaultAgentRunSnapshot]
    public let confirmedRemoteIdleSessionID: String?
    public let configuration: LocalACPSessionConfiguration

    public init(
        sessionID: String,
        loadedExistingSession: Bool,
        configuration: LocalACPSessionConfiguration = .empty,
        recoveredDefaultAgentRuns: [DefaultAgentRunSnapshot] = [],
        confirmedRemoteIdleSessionID: String? = nil
    ) {
        self.sessionID = sessionID
        self.loadedExistingSession = loadedExistingSession
        self.recoveredDefaultAgentRuns = recoveredDefaultAgentRuns
        self.confirmedRemoteIdleSessionID = confirmedRemoteIdleSessionID
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

enum ACPInputFrame: Equatable, Sendable {
    case inline(Data)
    /// The receiving client must remove this transient file after ingestion.
    case spooled(URL, byteCount: Int)
}

public final class ACPLineCursor: @unchecked Sendable {
    public static let maximumLineBytes = 10_000_000
    // A 64 MiB native record plus its small protocol envelope.
    static let maximumArchiveLineBytes = 65 * 1_024 * 1_024
    static let maximumSpooledFrameBytes = 1_024 * 1_024 * 1_024
    static let spoolThresholdBytes = 1_024 * 1_024
    private let handle: FileHandle
    private let lineByteLimit: Int?
    private let spoolDirectory: URL
    // FileHandle.AsyncBytes shares a blocking I/O actor across handles on macOS.
    // An idle session must not prevent another session from reading its response.
    // All mutable framing state is confined to this cursor's queue.
    private let queue = DispatchQueue(label: "com.wovenmatter.acp-line-reader", qos: .userInitiated)
    private var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
    private var chunkCount = 0
    private var chunkOffset = 0
    private var buffer = Data()
    private var frameBytes = 0
    private var spool: (url: URL, handle: FileHandle)?
    private var terminalError: (any Error)?

    public init(handle: FileHandle, maximumLineBytes: Int? = ACPLineCursor.maximumLineBytes,
         spoolDirectory: URL = FileManager.default.temporaryDirectory) {
        self.handle = handle
        self.lineByteLimit = maximumLineBytes
        self.spoolDirectory = spoolDirectory
    }

    deinit {
        if let spool {
            try? spool.handle.close()
            try? FileManager.default.removeItem(at: spool.url)
        }
    }

    public func next() async throws -> Data? {
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let frame = try self.readFrame(cancellation: cancellation, maximumBytes: self.lineByteLimit, spoolThreshold: nil)
                        switch frame {
                        case .inline(let data)?: continuation.resume(returning: data)
                        case nil: continuation.resume(returning: nil)
                        case .spooled(let url, _)?:
                            try? FileManager.default.removeItem(at: url)
                            continuation.resume(throwing: LocalACPClientError.invalidResponse("Unexpected spooled control frame"))
                        }
                    }
                    catch { self.discardPartialFrame(error: error); continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Large native snapshots are framed on a dispatch worker and spooled to
    /// disk. Memory is bounded by the threshold plus one 64 KiB read chunk.
    func nextFrame(maximumBytes: Int = ACPLineCursor.maximumSpooledFrameBytes) async throws -> ACPInputFrame? {
        guard maximumBytes > 0 else { throw LocalACPClientError.invalidResponse("Invalid native frame limit") }
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        continuation.resume(returning: try self.readFrame(cancellation: cancellation,
                            maximumBytes: maximumBytes, spoolThreshold: Self.spoolThresholdBytes))
                    } catch { self.discardPartialFrame(error: error); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func discardPartialFrame(error: any Error) {
        if let spool {
            try? spool.handle.close()
            try? FileManager.default.removeItem(at: spool.url)
            self.spool = nil
        }
        buffer.removeAll(keepingCapacity: false)
        frameBytes = 0
        // Dropping a partial frame loses its delimiter position. Retire this
        // reader rather than interpreting its remainder as another response.
        terminalError = terminalError ?? error
    }

    private func appendFrameBytes(_ bytes: ArraySlice<UInt8>, maximumBytes: Int?, spoolThreshold: Int?) throws {
        if let maximumBytes, bytes.count > maximumBytes - frameBytes {
            throw LocalACPClientError.lineTooLarge
        }
        frameBytes += bytes.count
        if spool == nil, let spoolThreshold, frameBytes > spoolThreshold {
            let url = spoolDirectory.appending(path: "woven-native-frame-" + UUID().uuidString)
            let descriptor = url.path.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR) }
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            spool = (url, writer)
            try writer.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: false)
        }
        if let spool { try spool.handle.write(contentsOf: Data(bytes)) }
        else { buffer.append(contentsOf: bytes) }
    }

    private func finishFrame() throws -> ACPInputFrame? {
        guard frameBytes > 0 else { return nil }
        let count = frameBytes
        frameBytes = 0
        if let saved = spool {
            try saved.handle.close()
            spool = nil
            return .spooled(saved.url, byteCount: count)
        }
        let data = buffer
        buffer.removeAll(keepingCapacity: false)
        return .inline(data)
    }

    private func readFrame(cancellation: ReadCancellation, maximumBytes: Int?, spoolThreshold: Int?) throws -> ACPInputFrame? {
        if let terminalError { throw terminalError }
        while true {
            try cancellation.check()
            while chunkOffset < chunkCount {
                let start = chunkOffset
                while chunkOffset < chunkCount && chunk[chunkOffset] != 0x0A { chunkOffset += 1 }
                try appendFrameBytes(chunk[start..<chunkOffset], maximumBytes: maximumBytes, spoolThreshold: spoolThreshold)
                if chunkOffset < chunkCount {
                    chunkOffset += 1
                    if let frame = try finishFrame() { return frame }
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
                return try finishFrame()
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
    private var defaultAgentRunID: String?
    private var defaultAgentRemote = false
    private var durableRemoteACP = false
    private let accountCoordinator: ProviderAccountCoordinator?
    private var defaultAgentScope = "local"
    private var executionScope = "local"
    private var historyReplayOrdinal: Int?
    private var defaultAgentCredentialRevision: String?
    public func setDefaultAgentRunID(_ value: String) async throws {
        defaultAgentRunID = value
        try await prepareDefaultAgent()
    }
    private func prepareCredentialPayload(_ scope: String) async throws -> DefaultAgentPayload {
        let coordinator = if let accountCoordinator { accountCoordinator } else { await ProviderAccountCoordinator.shared }
        return try await coordinator.prepare(scope)
    }
    private func prepareDefaultAgent() async throws {
        guard runtimeKind == .defaultAgent, !defaultAgentRemote else { return }
        let payload = try await prepareCredentialPayload("local")
        guard payload.revision != defaultAgentCredentialRevision else { return }
        let parameters = try JSONDecoder().decode(ACPJSONValue.self, from: payload.data())
        let result = try await request(method: "woven/configure", params: parameters)
        defaultAgentCredentialRevision = payload.revision
        captureSessionConfiguration(from: result)
        await configurationHandler?(configuration)
    }
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
    private var permissionStateRevision: UInt64 = 0
    private let cursorPermission: String
    private let requestedPermission: String?
    private var sessionCancellationRequested = false
    private var pendingPermissionRequestIDs: [ACPJSONValue] = []
    private var interactiveResponses: [UUID: (id: ACPJSONValue, fence: AgentDispatchFence)] = [:]
    private struct PendingCursorRequest {
        let id: ACPJSONValue
        let method: String
    }
    private var pendingCursorRequests: [PendingCursorRequest] = []
    private struct PendingRequest {
        let codexExpectedGeneration: Int64?
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
    private struct ActivePrompt {
        let id: UUID
        let onEvent: EventHandler?
        let onPermission: PermissionHandler?
        let onInteraction: InteractionHandler?
    }
    private var activePrompts: [ActivePrompt] = []
    private var retainedRunHandlers: ActivePrompt?
    private var activeEventHandler: EventHandler? { (activePrompts.last ?? retainedRunHandlers)?.onEvent }
    private var activePermissionHandler: PermissionHandler? { (activePrompts.last ?? retainedRunHandlers)?.onPermission }
    private var resumePermissionHandler: PermissionHandler?
    private var activeInteractionHandler: InteractionHandler? { (activePrompts.last ?? retainedRunHandlers)?.onInteraction }
    var activePromptRequestCount: Int { activePrompts.count }
    // A steer receipt is separate from completion. In particular Codex can
    // start a continuation when the original turn ends during admission.
    private var codexSteeringObservers: [UUID: AsyncThrowingStream<ACPRequestResponse, any Error>.Continuation] = [:]
    private var codexNativeGeneration: Int64 = 0
    private var codexThreadIsActive = false
    // ACP does not provide an identifier for thought chunks. Keep one stable
    // identity for adjacent deltas, then advance it when another stream kind
    // separates reasoning phases so distinct commentary is not merged.
    private var reasoningPhaseSequence = 0
    private var activeReasoningPhaseID: String?
    private var assistantSnapshotAssembly = NativeTextSnapshotAssembler()
    private var thoughtSnapshotAssemblies: [String: NativeTextSnapshotAssembler] = [:]
    private let cliConnection: AgentCLIContext?
    private var closed = false
    private var shutdownTask: Task<Void, Never>?

    private init(
        process: Process,
        input: FileHandle,
        cursor: ACPLineCursor,
        runtimeKind: AgentRuntimeKind,
        workingDirectory: URL,
        requestedPermission: String?,
        historyRecorder: WorkspaceWireRecorder? = nil,
        cliConnection: AgentCLIContext? = nil,
        accountCoordinator: ProviderAccountCoordinator?
    ) {
        self.cliConnection = cliConnection
        self.accountCoordinator = accountCoordinator
        self.historyRecorder = historyRecorder
        self.requestedPermission = requestedPermission
        self.cursorPermission = requestedPermission ?? "native-default"
        self.process = process
        self.input = input
        self.cursor = cursor
        self.runtimeKind = runtimeKind
        self.durableRemoteACP = process.environment?["WOVEN_DURABLE_REMOTE_ACP"] == "1"
        let scope = process.environment?["WOVEN_DEFAULT_AGENT_SCOPE"] ?? "local"
        self.defaultAgentScope = scope
        self.executionScope = process.environment?["WOVEN_EXECUTION_SCOPE"] ?? scope
        self.defaultAgentRemote = process.arguments?.contains("/usr/bin/ssh") == true
        self.workingDirectory = workingDirectory.standardizedFileURL
    }

    public static func start(
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL,
        accountCoordinator: ProviderAccountCoordinator? = nil
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
            #"ulimit -c 0; set -m; exec "$@""#,
            "wovenmatter-local-acp",
        ] + NativeCLIAdapter.command(launch: launch, arguments: preparedLaunch.arguments)
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
            // Native history responses can contain an exposed attachment or
            // unpaged snapshot larger than the normal control-frame limit.
            cursor: ACPLineCursor(handle: stdout.fileHandleForReading,
                maximumLineBytes: launch.historyRecorder == nil ? ACPLineCursor.maximumLineBytes : ACPLineCursor.maximumArchiveLineBytes),
            runtimeKind: launch.runtimeKind,
            workingDirectory: workingDirectory,
            requestedPermission: preparedLaunch.explicitPermission,
            historyRecorder: launch.historyRecorder,
            cliConnection: launch.cliConnection,
            accountCoordinator: accountCoordinator
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
        try await prepareDefaultAgent()
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
                historyReplayOrdinal = 0
                defer { historyReplayOrdinal = nil }
                let loaded = try await request(
                    method: "session/load",
                    params: .object([
                        "sessionId": .string(existingSessionID),
                        "cwd": .string(workingDirectory.path),
                        "mcpServers": .array([]),
                        "_meta": .object(try nativeConnectionMetadata()),
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
                try await reconcileBuiltInNativeHistory()
                return LocalACPInitializedSession(
                    sessionID: existingSessionID,
                    loadedExistingSession: true,
                    configuration: configuration,
                    recoveredDefaultAgentRuns: (runtimeKind != .defaultAgent && durableRemoteACP) ? ((try? JSONDecoder().decode([DefaultAgentRunSnapshot].self, from: JSONEncoder().encode(loaded?["_meta"]?["recoveredRuns"] ?? .array([])))) ?? []) : [],
                    confirmedRemoteIdleSessionID: runtimeKind != .defaultAgent && loaded?["_meta"]?["recoveryComplete"]?.boolValue == true
                        ? loaded?["_meta"]?["recoverySessionID"]?.stringValue : nil
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

    private func nativeConnectionMetadata() throws -> [String: ACPJSONValue] {
        guard let cliConnection else { return [:] }
        return ["wovenToolsConnection": try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(cliConnection))]
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
        var metadata = try nativeConnectionMetadata()
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
        try await reconcileBuiltInNativeHistory()
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

    public func sessionConfiguration() -> LocalACPSessionConfiguration {
        configuration
    }

    public func setResumePermissionHandler(_ handler: @escaping PermissionHandler) {
        resumePermissionHandler = handler
    }

    public func setConfigurationHandler(_ handler: @escaping @Sendable (LocalACPSessionConfiguration) async -> Void) async {
        configurationHandler = handler
        await handler(configuration)
    }

    public func setSessionPermission(_ permission: String) async throws -> LocalACPSessionConfiguration {
        guard let sessionID else { throw LocalACPClientError.sessionNotInitialized }
        let supportedOptions = configuration.permissionOptions
        guard !supportedOptions.isEmpty else {
            throw LocalACPClientError.unsupportedConfiguration("permission")
        }
        guard supportedOptions.contains(permission) else {
            throw LocalACPClientError.invalidConfigurationValue(field: "permission", value: permission)
        }
        if configuration.permission == permission { return configuration }
        if runtimeKind == .cursor { throw LocalACPClientError.permissionChangeRequiresRestart }
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
        onInteraction: InteractionHandler? = nil,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPStopReason {
        try await prompt(
            AgentMessageInput(text: text),
            onEvent: onEvent,
            onPermission: onPermission,
            onInteraction: onInteraction,
            dispatchFence: dispatchFence
        )
    }

    public func prompt(
        _ input: AgentMessageInput,
        onEvent: EventHandler? = nil,
        onPermission: PermissionHandler? = nil,
        onInteraction: InteractionHandler? = nil,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPStopReason {
        try dispatchFence?.check()
        sessionCancellationRequested = false
        return try await beginPrompt(
            input,
            onEvent: onEvent,
            onPermission: onPermission,
            onInteraction: onInteraction,
            dispatchFence: dispatchFence
        ).value
    }

    /// Accepts another user message while the session has an active prompt.
    /// Returns on admission; the receipt retains any continuation's completion.
    /// Never cancel the current prompt to simulate steering.
    public func beginActiveInput(
        _ text: String,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPActiveInputReceipt {
        try await beginActiveInput(AgentMessageInput(text: text), dispatchFence: dispatchFence)
    }

    public func beginActiveInput(
        _ input: AgentMessageInput,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPActiveInputReceipt {
        try dispatchFence?.check()
        guard let sessionID else {
            throw LocalACPClientError.sessionNotInitialized
        }
        guard !sessionCancellationRequested else { throw LocalACPClientError.activeInputUnsupported }
        switch Self.activeInputRoute(
            runtimeKind: runtimeKind,
            steeringSupported: steeringSupported
        ) {
        case .acpSteering:
            // Register before dispatch: the new turn may finish before its
            // steering acknowledgement reaches us. Buffer native lifecycle
            // events without blocking their ordered transcript processing.
            let observerID = UUID()
            // Ignore the old turn's idle event even if it arrives before the
            // receipt and the continuation's active event arrives after it.
            let previousGeneration = max(codexNativeGeneration,
                pendingRequests.values.compactMap(\.codexExpectedGeneration).max() ?? codexNativeGeneration)
            let lifecycle = AsyncThrowingStream<ACPRequestResponse, any Error>.makeStream()
            if runtimeKind == .codex { codexSteeringObservers[observerID] = lifecycle.continuation }
            var followsDetachedTurn = false
            defer {
                if !followsDetachedTurn {
                    codexSteeringObservers.removeValue(forKey: observerID)?.finish()
                }
            }
            var steeringMetadata: [String: ACPJSONValue] = [
                "steering": .object(["idleBehavior": .string("promptRequired")]),
            ]
            if let context = input.cliContext {
                steeringMetadata["wovenTools"] = try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(context))
            }
            let promptBlocks = try Self.promptBlocks(input)
            let commandOnly = runtimeKind == .codex && Self.codexCommandCompletesWithoutTurn(
                promptBlocks.arrayValue?.first?["text"]?.stringValue ?? ""
            )
            if commandOnly { steeringMetadata["wovenCommandOnly"] = .bool(true) }
            if durableRemoteACP, let defaultAgentRunID {
                steeringMetadata["wovenRunID"] = .string(defaultAgentRunID)
            }
            let response = try await request(
                method: "_session/steering",
                params: .object([
                    "sessionId": .string(sessionID),
                    "prompt": promptBlocks,
                    "_meta": .object(steeringMetadata),
                ]),
                waitsForNotifications: false,
                dispatchFence: dispatchFence
            )
            switch response?["outcome"]?.stringValue {
            case "injected":
                return LocalACPActiveInputReceipt(completion: Task { nil })
            case "startedNewTurn" where runtimeKind == .codex:
                // Codex ACP also uses this outcome after a command-only prompt
                // has already completed. Those commands never emit active/idle.
                if commandOnly {
                    let barrier = notificationTask
                    return LocalACPActiveInputReceipt(completion: Task {
                        try await barrier?.value
                        return self.sessionCancellationRequested ? .cancelled : .endTurn
                    })
                }
                if sessionCancellationRequested { try await cancel() }
                followsDetachedTurn = true
                lifecycle.continuation.yield(ACPRequestResponse(value: .object(["type": .string("steeringAccepted")]), notificationBarrier: nil))
                return LocalACPActiveInputReceipt(completion: Task {
                    defer {
                        self.codexSteeringObservers.removeValue(forKey: observerID)?.finish()
                    }
                    var started = false
                    var acknowledged = false
                    var terminal: ACPRequestResponse?
                    for try await status in lifecycle.stream {
                        switch status.value?["type"]?.stringValue {
                        case "active" where (status.value?["wovenGeneration"]?.integerValue ?? 0) > previousGeneration:
                            started = true; terminal = nil
                        case "idle" where started: terminal = status
                        case "systemError", "notLoaded": if started { terminal = status }
                        case "steeringAccepted": acknowledged = true
                        default: break
                        }
                        if acknowledged, let terminal {
                            try await terminal.notificationBarrier?.value
                            guard terminal.value?["type"]?.stringValue == "idle" else {
                                throw LocalACPClientError.invalidResponse("Codex stopped before completing the steering message.")
                            }
                            return self.sessionCancellationRequested ? .cancelled : .endTurn
                        }
                    }
                    throw LocalACPClientError.processExited
                })
            case "promptRequired":
                return await LocalACPActiveInputReceipt(
                    completion: try beginActivePrompt(input, dispatchFence: dispatchFence)
                )
            default:
                throw LocalACPClientError.invalidActiveInputResponse
            }
        case .grokInterjection:
            if !input.files.isEmpty {
                return await LocalACPActiveInputReceipt(
                    completion: try beginActivePrompt(input, dispatchFence: dispatchFence)
                )
            }
            do {
                var params: [String: ACPJSONValue] = [
                    "sessionId": .string(sessionID),
                    "text": .string(input.transportText()),
                ]
                if let context = input.cliContext {
                    params["_meta"] = .object([
                        "wovenTools": try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(context)),
                    ])
                }
                _ = try await request(
                    method: "_x.ai/interject",
                    params: .object(params),
                    waitsForNotifications: false,
                    dispatchFence: dispatchFence
                )
                return LocalACPActiveInputReceipt(completion: Task { nil })
            } catch LocalACPClientError.agent(let code, _) where code == -32_601 {
                return await LocalACPActiveInputReceipt(
                    completion: try beginActivePrompt(input, dispatchFence: dispatchFence)
                )
            }
        case .concurrentPrompt:
            return await LocalACPActiveInputReceipt(
                completion: try beginActivePrompt(input, dispatchFence: dispatchFence)
            )
        case .hermesGateway, .piRPC, .unsupported:
            throw LocalACPClientError.activeInputUnsupported
        }
    }

    public func activeInputCapability() -> LocalACPActiveInputRoute {
        Self.activeInputRoute(runtimeKind: runtimeKind, steeringSupported: steeringSupported)
    }

    public nonisolated static func activeInputRoute(
        runtimeKind: AgentRuntimeKind,
        steeringSupported: Bool
    ) -> LocalACPActiveInputRoute {
        switch runtimeKind {
        case .codex, .claudeCode, .defaultAgent:
            steeringSupported ? .acpSteering : .unsupported
        case .grokBuild:
            .grokInterjection
        case .hermes:
            .hermesGateway
        case .cursor, .opencode, .openclaw:
            .concurrentPrompt
        case .pi:
            .piRPC
        }
    }

    private func beginActivePrompt(
        _ input: AgentMessageInput,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> Task<LocalACPStopReason?, any Error> {
        // A promptRequired receipt may arrive after Stop. Never start its
        // fallback prompt after the native cancellation has already been sent.
        guard !sessionCancellationRequested else { throw LocalACPClientError.activeInputUnsupported }
        let prompt = try await beginPrompt(
            input,
            onEvent: activeEventHandler,
            onPermission: activePermissionHandler,
            onInteraction: activeInteractionHandler,
            dispatchFence: dispatchFence
        )
        return Task { try await prompt.value }
    }

    nonisolated static func codexCommandCompletesWithoutTurn(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let parts = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let command = parts.first else { return false }
        let argument = parts.dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Codex ACP 1.13.1 CodexCommands: these branches are entirely local to
        // the adapter. Review, compact, goal creation and unknown commands may
        // start native work and must retain the lifecycle observer.
        switch command.lowercased() {
        case "plan", "status", "rename", "logout", "skills", "mcp": return true
        case "review-branch", "review-commit": return argument.isEmpty
        case "goal": return ["", "pause", "clear"].contains(argument.lowercased()) || argument.utf16.count > 4_000
        default: return false
        }
    }

    private func beginPrompt(
        _ input: AgentMessageInput,
        onEvent: EventHandler?,
        onPermission: PermissionHandler?,
        onInteraction: InteractionHandler?,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> Task<LocalACPStopReason, any Error> {
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
        // Validate attachments before reserving state, then reserve before the
        // async history write. Another prompt or notification can arrive there.
        let blocks = try Self.promptBlocks(input, text: prefixedText)
        let promptID = UUID()
        if initialSystemPrompt != nil { initialSystemPromptInFlight = true }
        activePrompts.append(ActivePrompt(id: promptID, onEvent: onEvent,
            onPermission: onPermission, onInteraction: onInteraction))
        let response: Task<ACPRequestResponse, any Error>
        let promptRunID = defaultAgentRunID ?? UUID().uuidString.lowercased()
        do {
            var metadata: [String: ACPJSONValue] = [:]
            if runtimeKind == .defaultAgent || durableRemoteACP {
                metadata["wovenRunID"] = .string(promptRunID)
                metadata["wovenInputID"] = .string(UUID().uuidString.lowercased())
            }
            if let context = input.cliContext {
                metadata["wovenTools"] = try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(context))
            }
            response = try await beginRequest(
                method: "session/prompt",
                params: .object([
                    "sessionId": .string(sessionID),
                    "prompt": blocks,
                    "_meta": .object(metadata),
                ]),
                dispatchFence: dispatchFence
            )
        } catch {
            if initialSystemPrompt != nil { resolveInitialSystemPrompt(succeeded: false) }
            promptRequestFinished(promptID)
            throw error
        }
        retainedRunHandlers = ActivePrompt(id: promptID, onEvent: onEvent,
            onPermission: onPermission, onInteraction: onInteraction)
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
                self.promptRequestFinished(promptID)
                return reason
            } catch {
                if initialSystemPrompt != nil {
                    self.resolveInitialSystemPrompt(succeeded: false)
                }
                self.promptRequestFinished(promptID)
                throw error
            }
        }
    }

    /// Called by the coordinator only after every admitted input has settled.
    public func finishRun() async {
        // No native thought-end notification exists in ACP. The coordinator
        // calls this only after every admitted input and native update settles.
        if let reasoningID = activeReasoningPhaseID {
            try? await completeReasoningPhase(reasoningID)
        }
        activeReasoningPhaseID = nil
        retainedRunHandlers = nil
        activePrompts.removeAll()
        assistantSnapshotAssembly.reset()
        thoughtSnapshotAssemblies.removeAll()
    }

    private func promptRequestFinished(_ id: UUID) {
        // Removing one request must preserve handlers owned by other prompts,
        // including when a queued send fails or replies finish out of order.
        activePrompts.removeAll { $0.id == id }
    }

    private func resolveInitialSystemPrompt(succeeded: Bool) {
        initialSystemPromptInFlight = false
        if succeeded {
            pendingInitialSystemPrompt = nil
        }
    }

    nonisolated static func promptBlocks(
        _ input: AgentMessageInput,
        text: String? = nil
    ) throws -> ACPJSONValue {
        var fileBlocks: [ACPJSONValue] = []
        var linkedPaths: [String] = []
        for file in input.files {
            let data: Data
            do {
                data = try Data(contentsOf: file.localURL, options: [.mappedIfSafe])
            } catch {
                throw AgentMessageAttachmentError.unreadableFile(file.fileName)
            }
            // URIs must resolve where the agent runs: the staged container
            // path for a remote workspace, the local blob otherwise.
            let uri = file.remotePath.map { URL(filePath: $0).absoluteString }
                ?? file.localURL.absoluteString
            if file.kind == .image {
                fileBlocks.append(.object([
                    "type": .string("image"),
                    "mimeType": .string(file.mimeType),
                    "data": .string(data.base64EncodedString()),
                ]))
            } else if file.mimeType.hasPrefix("text/"),
                      let text = String(data: data, encoding: .utf8) {
                fileBlocks.append(.object([
                    "type": .string("resource"),
                    "resource": .object([
                        "uri": .string(uri),
                        "mimeType": .string(file.mimeType),
                        "text": .string(text),
                    ]),
                ]))
            } else {
                linkedPaths.append(file.remotePath ?? file.localURL.path)
                fileBlocks.append(.object([
                    "type": .string("resource_link"),
                    "uri": .string(uri),
                    "name": .string(file.fileName),
                    "mimeType": .string(file.mimeType),
                    "size": .integer(file.sizeBytes),
                ]))
            }
        }
        var outboundText = text ?? input.transportText()
        // Some ACP adapters (Codex, Claude Code) reduce a resource link to an
        // `@name` mention and drop its path, so linked files are also named
        // in the text. Inlined images and text need no such help.
        if !linkedPaths.isEmpty {
            outboundText += (outboundText.isEmpty ? "" : "\n\n")
                + "Attached files available to this session:\n"
                + linkedPaths.map { "- \($0)" }.joined(separator: "\n")
        }
        var blocks: [ACPJSONValue] = []
        if !outboundText.isEmpty {
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(outboundText),
            ]))
        }
        blocks.append(contentsOf: fileBlocks)
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

    public func cancel() async throws {
        guard let sessionID else { return }
        sessionCancellationRequested = true
        for response in interactiveResponses.values { response.fence.cancel() }
        let pending = pendingPermissionRequestIDs.filter { id in
            !interactiveResponses.values.contains { $0.id == id && $0.fence.hasDispatched }
        }
        let cursorRequests = pendingCursorRequests.filter { request in
            !interactiveResponses.values.contains { $0.id == request.id && $0.fence.hasDispatched }
        }
        pendingPermissionRequestIDs.removeAll()
        pendingCursorRequests.removeAll()
        for id in pending {
            try await respondWithCancelledPermission(id: id)
        }
        for request in cursorRequests {
            try await respondToCancelledCursorRequest(request)
        }
        try await write(ACPEnvelope(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)])
        ))
    }

    /// Normal retirement must include committed background compaction and its
    /// archive notifications. Forced shutdown remains an independent abort path.
    public func awaitIdle() async throws {
        guard runtimeKind == .defaultAgent, let sessionID else { return }
        let result = try await request(method: "woven/idle", params: .object(["sessionId": .string(sessionID)]))
        guard self.sessionID == sessionID, result?["idle"]?.boolValue == true else {
            throw LocalACPClientError.invalidResponse("Pi Durable native work did not confirm idle retirement")
        }
        // Detached remote execution cannot push commits after the primary
        // response. Reconcile its completed background work before release.
        try await reconcileBuiltInNativeHistory()
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !closed else { return }
        closed = true
        await finishRun()
        for response in interactiveResponses.values { response.fence.cancel() }
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
        waitsForNotifications: Bool = true,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> ACPJSONValue? {
        let response = try await beginRequest(
            method: method,
            params: params,
            dispatchFence: dispatchFence
        ).value
        if waitsForNotifications {
            try await response.notificationBarrier?.value
        }
        return response.value
    }

    private func beginRequest(
        method: String,
        params: ACPJSONValue,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> Task<ACPRequestResponse, any Error> {
        startReaderIfNeeded()
        let id = nextID
        nextID += 1
        let pair = AsyncThrowingStream<ACPRequestResponse, any Error>.makeStream()
        pendingRequests[id] = PendingRequest(
            codexExpectedGeneration: method == "session/prompt" ? codexNativeGeneration + (codexThreadIsActive ? 0 : 1) : nil,
            continuation: pair.continuation
        )
        do {
            try await write(ACPEnvelope(
                id: .integer(id),
                method: method,
                params: params
            ), dispatchFence: dispatchFence)
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

    private func receive(_ data: Data) async throws {
        if runtimeKind != .defaultAgent { try await historyRecorder?("in", data) }
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
        if runtimeKind == .defaultAgent, envelope.method == "session/update",
           pendingNewSessionUpdates == nil, belongsToActiveSession(envelope),
           let update = envelope.params?["update"],
           update["sessionUpdate"]?.stringValue == "woven_native_record",
           let batch = update["recordBatch"], let sessionID {
            // Native copies have no interactive UI callback. Ingest before the
            // next frame for bounded backpressure, even when a dialog holds the
            // ordinary notification queue. Response barriers remain ordered.
            try await recordBuiltInNativeHistory(batch, sessionID: sessionID)
            return
        }
        if envelope.method == "session/update", pendingNewSessionUpdates != nil {
            pendingNewSessionUpdates?.append(envelope)
            return
        }
        if envelope.method == "session/request_permission",
           pendingNewSessionUpdates == nil,
           !belongsToActiveSession(envelope) {
            // A child must not wait behind an unrelated parent approval. This
            // settles only foreign requests; parent delivery keeps its barrier.
            if let id = envelope.id { try await respondWithCancelledPermission(id: id) }
            return
        }
        enqueueNotification(envelope)
        if runtimeKind == .codex, envelope.method == "session/update", belongsToActiveSession(envelope),
           let status = envelope.params?["update"]?["_meta"]?["codex"]?["threadStatus"] {
            let isActive = status["type"]?.stringValue == "active"
            if isActive && !codexThreadIsActive { codexNativeGeneration += 1 }
            codexThreadIsActive = isActive
            let sequencedStatus: ACPJSONValue = .object([
                "type": status["type"] ?? .null,
                "wovenGeneration": .integer(codexNativeGeneration),
            ])
            for observer in codexSteeringObservers.values {
                observer.yield(ACPRequestResponse(value: sequencedStatus, notificationBarrier: notificationTask))
            }
        }
    }

    private func enqueueNotification(_ envelope: ACPEnvelope) {
        let previous = notificationTask
        let task = Task<Void, any Error> { [weak self] in
            try await withTaskCancellationHandler {
                try await previous?.value
            } onCancel: { previous?.cancel() }
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
        if envelope.method == "woven/credentials", runtimeKind == .defaultAgent {
            do {
                let payload = try await prepareCredentialPayload(defaultAgentScope)
                try await write(ACPEnvelope(id: envelope.id, result: JSONDecoder().decode(ACPJSONValue.self, from: payload.data())))
            } catch {
                try await write(ACPEnvelope(id: envelope.id, error: .init(code: -32000, message: "Pi Durable credentials are unavailable.")))
            }
        } else if envelope.method == "session/update" {
            guard belongsToActiveSession(envelope) else { return }
            let update = envelope.params?["update"]
            if runtimeKind == .defaultAgent,
               update?["sessionUpdate"]?.stringValue == "woven_native_record" {
                // The Pi Durable control channel carries credentials. Only the
                // engine's explicit committed-record projection is archived;
                // recording the whole wire would persist credential exchanges.
                guard let sessionID, let batch = update?["recordBatch"] else {
                    throw LocalACPClientError.invalidResponse("Missing Pi Durable native archive batch")
                }
                try await recordBuiltInNativeHistory(batch, sessionID: sessionID)
                return
            }
            if runtimeKind != .defaultAgent, let sessionID, let update {
                let ordinal = historyReplayOrdinal
                if let ordinal { historyReplayOrdinal = ordinal + 1 }
                let record = try ACPNativeHistoryCapture.record(update,
                    runID: ordinal == nil ? defaultAgentRunID : nil, replayOrdinal: ordinal)
                try await NativeHarnessArchive.capture(sourceID: "acp:\(runtimeKind.rawValue):\(executionScope)",
                    sessionID: sessionID, records: [record], recorder: historyRecorder)
            }
            switch update?["sessionUpdate"]?.stringValue {
            case "config_option_update", "available_commands_update", "current_mode_update":
                let previousConfiguration = configuration
                captureSessionConfiguration(from: update)
                if previousConfiguration != configuration { await configurationHandler?(configuration) }
            default:
                break
            }
            let previousReasoningID = activeReasoningPhaseID
            let event = projectedEvent(
                from: envelope,
                workingDirectory: workingDirectory
            )
            if let previousReasoningID, previousReasoningID != activeReasoningPhaseID {
                try await completeReasoningPhase(previousReasoningID)
            }
            if let event {
                try await activeEventHandler?(event)
            }
        } else if envelope.method == "session/request_permission" {
            guard belongsToActiveSession(envelope) else {
                // Multiplexed child requests must settle on the same connection,
                // without exposing or authorizing them as this session's work.
                if let id = envelope.id { try await respondWithCancelledPermission(id: id) }
                return
            }
            try await respondToPermissionRequest(
                envelope,
                handler: activePermissionHandler ?? (durableRemoteACP ? resumePermissionHandler : nil)
            )
        } else if envelope.method == "cursor/ask_question" {
            try await respondToCursorQuestion(
                envelope,
                handler: activeInteractionHandler
            )
        } else if envelope.method == "cursor/create_plan" {
            guard belongsToActiveSession(envelope) else {
                if let id = envelope.id {
                    try await respondToCancelledCursorRequest(PendingCursorRequest(id: id, method: "cursor/create_plan"))
                }
                return
            }
            if let id = activeReasoningPhaseID {
                activeReasoningPhaseID = nil
                try await completeReasoningPhase(id)
            }
            if let event = Self.cursorPlanEvent(from: envelope) {
                try await activeEventHandler?(event)
            }
            try await respondToCursorPlan(
                envelope,
                handler: activeInteractionHandler
            )
        } else if envelope.method == "cursor/update_todos" {
            guard belongsToActiveSession(envelope) else { return }
            if let id = activeReasoningPhaseID {
                activeReasoningPhaseID = nil
                try await completeReasoningPhase(id)
            }
            if let event = Self.cursorTodoEvent(from: envelope) {
                try await activeEventHandler?(event)
            }
        } else if envelope.method != nil, envelope.id != nil {
            try await write(ACPEnvelope(
                id: envelope.id,
                error: ACPErrorBody(code: -32601, message: "Method not found")
            ))
        }
    }

    private func completeReasoningPhase(_ id: String) async throws {
        try await activeEventHandler?(.activity(AgentRunActivity(
            id: id, kind: .thought, phase: "end", title: "Thinking", status: "completed"
        ), appendsContent: false))
    }

    private func belongsToActiveSession(_ envelope: ACPEnvelope) -> Bool {
        guard pendingNewSessionUpdates == nil else { return false }
        // Older adapters omit the identity on their single-session connection.
        // An explicit identity, including an invalid one, never uses that fallback.
        guard let value = envelope.params?["sessionId"] else { return true }
        guard let incomingSessionID = value.stringValue, !incomingSessionID.isEmpty else { return false }
        return incomingSessionID == sessionID
    }

    /// Reconciliation is independent of the activity projection and run status.
    /// A reconnect copies the native committed records even when a previous run
    /// already has its final assistant message in the presentation database.
    private func reconcileBuiltInNativeHistory() async throws {
        guard runtimeKind == .defaultAgent, historyRecorder != nil, let sessionID else { return }
        var after = try BuiltInNativeHistoryCursor(.integer(0))
        while true {
            try Task.checkCancellation()
            let page = try await request(method: "woven/history", params: .object([
                "sessionId": .string(sessionID), "after": after.value, "limit": .integer(200),
            ]))
            guard self.sessionID == sessionID,
                  let batch = page?["recordBatch"],
                  let nextValue = page?["nextAfter"],
                  let hasMore = page?["hasMore"]?.boolValue,
                  let next = try? BuiltInNativeHistoryCursor(nextValue),
                  next >= after, !hasMore || next > after else {
                throw LocalACPClientError.invalidResponse("Invalid Pi Durable native archive page")
            }
            try await recordBuiltInNativeHistory(batch, sessionID: sessionID)
            if !hasMore { return }
            after = next
        }
    }

    private func recordBuiltInNativeHistory(_ value: ACPJSONValue, sessionID: String) async throws {
        guard let historyRecorder else { return }
        let prefix = defaultAgentRemote ? "remote:\(defaultAgentScope):" : "local:"
        let data = try BuiltInNativeHistoryCapture.batchData(value, sessionID: sessionID,
            sourcePrefix: prefix)
        try await historyRecorder("native", data)
    }

    private func readerFailed(_ error: any Error) {
        notificationTask?.cancel()
        for response in interactiveResponses.values { response.fence.cancel() }
        failPendingRequests(with: error)
    }

    private func failPendingRequests(with error: any Error) {
        for observer in codexSteeringObservers.values { observer.finish(throwing: error) }
        codexSteeringObservers.removeAll()
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
            configuration = LocalACPSessionConfiguration(
                model: configuration.model, thinking: configuration.thinking,
                modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: modes["currentModeId"]?.stringValue,
                permissionOptions: available.compactMap { $0["id"]?.stringValue },
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
                fallbackNotice: value["_meta"]?["fallbackReason"]?.stringValue,
                permission: parsed.permission?.currentValue ?? (hadPermissionOption ? nil : configuration.permission),
                permissionOptions: parsed.permission?.options ?? (hadPermissionOption ? [] : configuration.permissionOptions),
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
                permissionOptions: LocalACPSessionPermissions.grokOptions,
                permissionOptionMetadata: LocalACPSessionPermissions.grokMetadata
            )
        }
        if runtimeKind == .cursor {
            // ACP agent/plan/ask are execution modes; permissions are native process flags.
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
                    description: option["description"]?.stringValue,
                    modelName: option["_meta"]?["modelName"]?.stringValue)
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
            try await respondWithCancelledPermission(id: id)
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
            try await respondWithCancelledPermission(id: id)
            return
        }
        pendingPermissionRequestIDs.append(id)
        let selectedID = await handler?(request)
        guard pendingPermissionRequestIDs.contains(id) else { return }
        let selected = selectedID.flatMap { candidate in
            options.first { $0.id == candidate }
        }

        if let selected {
            try await writeInteractiveResponse(ACPEnvelope(
                id: id,
                result: .object([
                    "outcome": .object([
                        "outcome": .string("selected"),
                        "optionId": .string(selected.id),
                    ])
                ])
            ))
        } else {
            pendingPermissionRequestIDs.removeAll { $0 == id }
            try await respondWithCancelledPermission(id: id)
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
        guard !sessionCancellationRequested else {
            try await respondToCancelledCursorRequest(pending)
            return
        }
        pendingCursorRequests.append(pending)
        let response = await handler?(.questions(request)) ?? .cancelled
        guard pendingCursorRequests.contains(where: { $0.id == id }) else { return }

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
        try await writeInteractiveResponse(ACPEnvelope(
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
        guard !sessionCancellationRequested else {
            try await respondToCancelledCursorRequest(pending)
            return
        }
        pendingCursorRequests.append(pending)
        let response = await handler?(.plan(request)) ?? .cancelled
        guard pendingCursorRequests.contains(where: { $0.id == id }) else { return }
        let accepted = if case .planAccepted(let accepted) = response {
            accepted
        } else {
            false
        }
        try await writeInteractiveResponse(ACPEnvelope(
            id: id,
            result: .object(["accepted": .bool(accepted)])
        ))
    }

    private func writeInteractiveResponse(_ envelope: ACPEnvelope) async throws {
        guard let id = envelope.id else { return }
        let key = UUID()
        let fence = AgentDispatchFence()
        interactiveResponses[key] = (id, fence)
        defer {
            interactiveResponses.removeValue(forKey: key)
            pendingPermissionRequestIDs.removeAll { $0 == id }
            _ = removePendingCursorRequest(id: id)
        }
        do {
            try await write(envelope, dispatchFence: fence)
        } catch is CancellationError where !fence.hasDispatched {
            // Stop snapshots the IDs before yielding and owns those cancellations.
            if !sessionCancellationRequested, pendingPermissionRequestIDs.contains(id) {
                try await respondWithCancelledPermission(id: id)
            }
            return
        }
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
    ) async throws {
        let result: ACPJSONValue = if request.method == "cursor/create_plan" {
            .object(["accepted": .bool(false)])
        } else {
            .object(["answers": .object([:])])
        }
        try await write(ACPEnvelope(id: request.id, result: result))
    }

    private func respondWithCancelledPermission(id: ACPJSONValue) async throws {
        try await write(ACPEnvelope(
            id: id,
            result: .object([
                "outcome": .object(["outcome": .string("cancelled")])
            ])
        ))
    }

    private var outgoingBusy = false
    private var outgoingWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireOutgoing() async {
        if outgoingBusy {
            await withCheckedContinuation { outgoingWaiters.append($0) }
        } else { outgoingBusy = true }
    }

    private func releaseOutgoing() {
        if outgoingWaiters.isEmpty { outgoingBusy = false }
        else { outgoingWaiters.removeFirst().resume() }
    }

    private func write(_ envelope: ACPEnvelope, dispatchFence: AgentDispatchFence? = nil) async throws {
        await acquireOutgoing()
        defer { releaseOutgoing() }
        guard !closed else { throw LocalACPClientError.processExited }
        if envelope.method == "session/prompt" { try Task.checkCancellation() }
        var data = try JSONEncoder().encode(envelope)
        if runtimeKind != .defaultAgent { try await historyRecorder?("out", data) }
        guard !closed else { throw LocalACPClientError.processExited }
        let isInput = ["session/prompt", "_session/steering", "_x.ai/interject"].contains(envelope.method ?? "")
        if isInput, Task.isCancelled || sessionCancellationRequested { throw LocalACPClientError.activeInputUnsupported }
        do { try dispatchFence?.claimDispatch() }
        catch {
            if isInput { throw LocalACPClientError.activeInputUnsupported }
            throw error
        }
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
        if error.data?["deliveryUncertain"]?.boolValue == true {
            return .deliveryUncertain(error.message ?? "The remote steering receipt was lost.")
        }
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
        case "woven_program_status":
            guard runtimeKind == .defaultAgent, let raw = Self.jsonString(update["status"] ?? .null),
                  let report = try? JSONDecoder().decode(ProgramStatus.self, from: Data(raw.utf8)),
                  let valid = report.validated,
                  let runID = update["_meta"]?["wovenRunID"]?.stringValue, !runID.isEmpty else { return nil }
            return .programStatus(valid, runID: runID)
        case "woven_subagents":
            guard runtimeKind == .defaultAgent,
                  let raw = Self.jsonString(update),
                  let activity = AgentRunActivity.builtInSubagentSnapshot(rawPayloadJSON: raw) else { return nil }
            return .activity(activity, appendsContent: false)
        case "agent_message_chunk":
            activeReasoningPhaseID = nil
            if runtimeKind == .defaultAgent, update["_meta"]?["wovenAssistantSnapshot"]?.boolValue == true {
                guard let text = update["content"]?["text"]?.stringValue,
                      let complete = assistantSnapshotAssembly.receive(text,
                        starts: update["_meta"]?["wovenSnapshotStart"]?.boolValue == true,
                        ends: update["_meta"]?["wovenSnapshotEnd"]?.boolValue == true) else { return nil }
                return .assistantSnapshot(complete)
            }
            if let text = update["content"]?["text"]?.stringValue { return .assistantChunk(text) }
            guard let block = update["content"] else { return nil }
            let resource = block["resource"] ?? block
            let mime = resource["mimeType"]?.stringValue ?? block["mimeType"]?.stringValue
            let source = resource["uri"]?.stringValue ?? block["uri"]?.stringValue ?? ""
            let data = (resource["blob"]?.stringValue ?? block["data"]?.stringValue).flatMap { encoded -> Data? in
                guard encoded.utf8.count <= Int(AgentMessageAttachmentLimits.maximumFileBytes * 4 / 3 + 8) else { return nil }
                return Data(base64Encoded: encoded)
            } ?? resource["text"]?.stringValue.map { Data($0.utf8) }
            guard !source.isEmpty || data != nil else { return nil }
            let name = block["name"]?.stringValue ?? resource["name"]?.stringValue
                ?? (source.isEmpty ? (mime?.hasPrefix("image/") == true ? "Image" : "Attachment") : URL(string: source)?.lastPathComponent ?? "Attachment")
            return .assistantAsset(LibraryAsset(source: source, title: name,
                kind: LibraryLinkDiscovery.kind(source: source, mimeType: mime), mimeType: mime, data: data))
        case "woven_assistant_boundary":
            guard runtimeKind == .defaultAgent else { return nil }
            activeReasoningPhaseID = nil
            return .assistantBoundary
        case "agent_thought_chunk":
            guard let text = update["content"]?["text"]?.stringValue else { return nil }
            let reasoningID: String
            if runtimeKind == .defaultAgent, let blockID = update["_meta"]?["wovenThoughtID"]?.stringValue {
                reasoningID = blockID
                activeReasoningPhaseID = blockID
            } else if let activeReasoningPhaseID {
                reasoningID = activeReasoningPhaseID
            } else {
                reasoningPhaseSequence += 1
                reasoningID = "thought-\(reasoningPhaseSequence)"
                activeReasoningPhaseID = reasoningID
            }
            if runtimeKind == .defaultAgent, update["_meta"]?["wovenThoughtSnapshot"]?.boolValue == true {
                var assembly = thoughtSnapshotAssemblies[reasoningID] ?? NativeTextSnapshotAssembler()
                let complete = assembly.receive(text,
                    starts: update["_meta"]?["wovenSnapshotStart"]?.boolValue == true,
                    ends: update["_meta"]?["wovenSnapshotEnd"]?.boolValue == true)
                thoughtSnapshotAssemblies[reasoningID] = assembly
                guard let complete else { return nil }
                thoughtSnapshotAssemblies.removeValue(forKey: reasoningID)
                return .activity(AgentRunActivity(id: reasoningID, kind: .thought, phase: "update",
                    title: "Thinking", status: "running", content: complete, contentIsDelta: false,
                    rawPayloadJSON: Self.jsonString(update)), appendsContent: false)
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
            let activity = Self.toolActivity(update, phase: "update", workingDirectory: workingDirectory)
            return .activity(
                activity, appendsContent: activity.contentIsDelta == true
            )
        case "plan":
            activeReasoningPhaseID = nil
            let entries = update["entries"]?.arrayValue?.compactMap { value -> AgentRunPlanEntry? in
                guard let content = value["content"]?.stringValue,
                      let status = value["status"]?.stringValue else { return nil }
                return AgentRunPlanEntry(
                    content: content,
                    priority: value["priority"]?.stringValue,
                    status: status,
                    nativeID: value["id"]?.stringValue
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
                    rawPayloadJSON: Self.jsonString(update),
                    planKind: "checklist", planOperation: entries.isEmpty ? "clear" : "replace"
                ),
                appendsContent: false
            )
        default:
            return nil
        }
    }

    private static func cursorTodoEvent(from envelope: ACPEnvelope) -> LocalACPEvent? {
        guard let params = envelope.params,
              params["toolCallId"]?.stringValue != nil,
              let merge = params["merge"]?.boolValue,
              let rawTodos = params["todos"]?.arrayValue else { return nil }
        let entries = rawTodos.compactMap(cursorPlanEntry)
        return .activity(
            AgentRunActivity(
                id: "cursor-todos",
                kind: .plan,
                phase: !merge && entries.isEmpty ? "clear" : "update",
                title: "Plan",
                status: entries.allSatisfy { $0.status == "completed" }
                    ? "completed"
                    : "running",
                planEntries: entries,
                rawPayloadJSON: jsonString(params),
                planKind: "checklist", planOperation: merge ? "merge" : "replace"
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
                rawPayloadJSON: jsonString(params),
                planKind: "proposal", planOperation: "replace"
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
        return AgentRunPlanEntry(content: step, status: status, nativeID: value["id"]?.stringValue)
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
        // Codex ACP streams terminal output in metadata instead of content
        // blocks. Preserve its exact chunks as readable output as well as in
        // the canonical wire capture. Standard content blocks remain snapshots.
        let terminalDelta = textParts.isEmpty
            ? update["_meta"]?["terminal_output_delta"]?["data"]?.stringValue : nil
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
            content: terminalDelta ?? textParts.joined(separator: "\n\n").nilIfEmpty,
            contentIsDelta: terminalDelta != nil,
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
    case deliveryUncertain(String)
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
        case .deliveryUncertain(let message): message
        case .invalidLaunchConfiguration:
            "The local agent's wrapped launch command is invalid."
        case .lineTooLarge:
            "The agent response exceeded the configured transport size limit."
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
