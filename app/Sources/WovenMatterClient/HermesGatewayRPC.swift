import Foundation
import WovenMatterCore

protocol HermesGatewayTransport: Sendable {
    var epoch: String? { get async }
    var isConnected: Bool { get async }
    func setHandlers(event: HermesGatewayRPC.EventHandler?, disconnected: (@Sendable () async -> Void)?, request: HermesGatewayRPC.EventHandler?) async
    func connect() async throws
    func disconnect() async
    func call(_ method: String, _ params: HermesValue) async throws -> HermesValue
    func callConfiguration(_ method: String, _ params: HermesValue) async throws -> HermesValue
    func call(_ method: String, _ params: HermesValue, dispatchFence: AgentDispatchFence?) async throws -> HermesValue
    func respond(id: String, result: HermesValue) async throws
    func respond(id: String, result: HermesValue, dispatchFence: AgentDispatchFence?) async throws
    func exportSession(storedID: String) async throws -> HermesSessionImport?
    func archiveSession(storedID: String, recorder: @escaping WorkspaceWireRecorder, afterMessageID: Int64?, runID: String?) async throws -> Int64?
}

extension HermesGatewayTransport {
    func callConfiguration(_ method: String, _ params: HermesValue) async throws -> HermesValue {
        try await call(method, params)
    }
    func exportSession(storedID: String) async throws -> HermesSessionImport? { nil }
    func archiveSession(storedID: String, recorder: @escaping WorkspaceWireRecorder, afterMessageID: Int64?, runID: String?) async throws -> Int64? {
        guard let snapshot = try await exportSession(storedID: storedID) else { return nil }
        var batch = try snapshot.nativeArchiveBatch()
        var maximum: Int64 = 0
        for index in batch.records.indices where batch.records[index].kind == "message" {
            guard let id = Int64(batch.records[index].id.dropFirst("message:".count)) else { continue }
            maximum = max(maximum, id)
            if let afterMessageID, id > afterMessageID { batch.records[index].runID = runID }
        }
        try await recorder("native", NativeHarnessArchive.encode(batch))
        return maximum
    }
    // Fixtures and non-journaling transports keep their existing call contract.
    // The native RPC implementation claims only at its final socket write.
    func call(_ method: String, _ params: HermesValue, dispatchFence: AgentDispatchFence?) async throws -> HermesValue {
        try dispatchFence?.claimDispatch()
        return try await call(method, params)
    }
    func respond(id: String, result: HermesValue, dispatchFence: AgentDispatchFence?) async throws {
        try dispatchFence?.claimDispatch()
        try await respond(id: id, result: result)
    }

}

/// Native Hermes JSON-RPC 2.0, including newline-batched WebSocket frames.
public actor HermesGatewayRPC: HermesGatewayTransport {
    public typealias EventHandler = @Sendable (HermesValue) async -> Void
    public let connection: HermesGatewayConnection
    private let session: URLSession
    private let historyRecorder: WorkspaceWireRecorder?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<HermesValue, any Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var eventHandler: EventHandler?
    private var requestHandler: EventHandler?
    private var disconnectHandler: (@Sendable () async -> Void)?
    public private(set) var epoch: String?
    public var isConnected: Bool { socket != nil }
    private var generation = UUID()
    private var secretRequestIDs: Set<String> = []
    private var configurationRequestIDs: Set<String> = []

    public init(connection: HermesGatewayConnection, historyRecorder: WorkspaceWireRecorder? = nil) {
        self.connection = connection
        self.historyRecorder = historyRecorder
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 45
        session = URLSession(configuration: config)
    }

    public func setHandlers(event: EventHandler?, disconnected: (@Sendable () async -> Void)? = nil, request: EventHandler? = nil) {
        eventHandler = event; disconnectHandler = disconnected; requestHandler = request
    }

    public func connect() async throws {
        if socket != nil { return }
        guard (1...65535).contains(connection.port), !connection.token.isEmpty else {
            throw HermesGatewayError.message("Hermes connection registration is invalid.")
        }
        let current = UUID(); generation = current
        epoch = nil
        var request = URLRequest(url: connection.websocketURL)
        for (key, value) in connection.requestHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 32 * 1_024 * 1_024
        self.socket = socket
        socket.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    for line in data.split(separator: 10) where !line.isEmpty {
                        try await self?.record("in", data: Data(line))
                        let frame = try HermesValue.decode(Data(line))
                        await self?.receive(frame, generation: current)
                    }
                }
            } catch { await self?.failed(generation: current) }
        }
        do {
            let result = try await call("ping")
            guard result["pong"].bool, epoch != nil else {
                throw HermesGatewayError.message("This server does not advertise the Hermes native Gateway replay contract.")
            }
            let profile = try await call("config.get", ["key": "profile"])
            guard URL(fileURLWithPath: profile["home"].text).standardizedFileURL.path == URL(fileURLWithPath: connection.home).standardizedFileURL.path else {
                throw HermesGatewayError.message("Hermes Gateway belongs to a different profile. The saved connection has not been changed.")
            }
        } catch { await disconnect(); throw error }
    }

    public func disconnect() async {
        generation = UUID()
        reader?.cancel(); reader = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        failPending()
        secretRequestIDs.removeAll()
        configurationRequestIDs.removeAll()
    }

    func exportSession(storedID: String) async throws -> HermesSessionImport? {
        try await HermesSessionHistory.load(connection: connection, sessionID: storedID)
    }

    func archiveSession(storedID: String, recorder: @escaping WorkspaceWireRecorder, afterMessageID: Int64?, runID: String?) async throws -> Int64? {
        try await HermesSessionHistory.archive(connection: connection, sessionID: storedID,
            recorder: recorder, afterMessageID: afterMessageID, runID: runID)
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

    public func call(_ method: String, _ params: HermesValue = [:]) async throws -> HermesValue {
        try await call(method, params, dispatchFence: nil)
    }

    public func call(_ method: String, _ params: HermesValue, dispatchFence: AgentDispatchFence?) async throws -> HermesValue {
        try await call(method, params, dispatchFence: dispatchFence, configuration: false)
    }

    func callConfiguration(_ method: String, _ params: HermesValue) async throws -> HermesValue {
        try await call(method, params, dispatchFence: nil, configuration: true)
    }

    private func call(_ method: String, _ params: HermesValue, dispatchFence: AgentDispatchFence?, configuration: Bool) async throws -> HermesValue {
        try dispatchFence?.check()
        guard let socket else { throw HermesGatewayError.message("Hermes Gateway is disconnected.") }
        let id = UUID().uuidString
        if configuration, historyRecorder != nil { configurationRequestIDs.insert(id) }
        let frame: HermesValue = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]
        let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
        let current = generation
        await acquireOutgoing()
        do {
            try await record("out", data: Data(text.utf8))
            try Task.checkCancellation()
            guard current == generation else { throw HermesGatewayError.message("Hermes Gateway disconnected before sending the request.") }
            try dispatchFence?.check()
        } catch { releaseOutgoing(); throw error }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    if !Task.isCancelled { await self?.expire(id) }
                }
                Task {
                    defer { self.releaseOutgoing() }
                    guard self.generation == current, self.pending[id] != nil else { return }
                    do {
                        try dispatchFence?.claimDispatch()
                        try await socket.send(.string(text))
                    } catch {
                        if let dispatchFence, !dispatchFence.hasDispatched {
                            self.timeouts.removeValue(forKey: id)?.cancel()
                            self.pending.removeValue(forKey: id)?.resume(throwing: error)
                        } else { self.expire(id) }
                    }
                }
            }
        } onCancel: {
            let unsent = dispatchFence?.cancel() == true
            Task { await self.cancelRequest(id, unsent: unsent) }
        }
    }

    public func respond(id: String, result: HermesValue) async throws {
        try await send(["jsonrpc": "2.0", "id": .string(id), "result": result])
    }

    public func respond(id: String, result: HermesValue, dispatchFence: AgentDispatchFence?) async throws {
        try await send(["jsonrpc": "2.0", "id": .string(id), "result": result], dispatchFence: dispatchFence)
    }

    private func send(_ frame: HermesValue, dispatchFence: AgentDispatchFence? = nil) async throws {
        try dispatchFence?.check()
        let current = generation
        await acquireOutgoing()
        defer { releaseOutgoing() }
        guard current == generation else { throw HermesGatewayError.message("Hermes Gateway disconnected before sending the response.") }
        guard let socket else { throw HermesGatewayError.message("Hermes Gateway is disconnected.") }
        let data = try JSONEncoder().encode(frame)
        try await record("out", data: data)
        try Task.checkCancellation()
        guard current == generation else { throw HermesGatewayError.message("Hermes Gateway disconnected before sending the response.") }
        try dispatchFence?.claimDispatch()
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Secret/sudo replies are credential transport, not native run content.
    /// Preserve correlation and the decision request without persisting values.
    static func credentialSafeFrame(_ frame: HermesValue, secretRequestIDs: Set<String>) -> HermesValue {
        var result = frame
        let method = frame["method"].text
        if ["sudo.respond", "secret.respond"].contains(method) {
            result["params"] = .object(frame["params"].object.filter { !["password", "value", "secret"].contains($0.key) })
        } else if secretRequestIDs.contains(frame["id"].text), method.isEmpty {
            result["result"] = .object(frame["result"].object.filter { !["password", "value", "secret"].contains($0.key) })
        } else if ["sudo", "secret"].contains(method) {
            result["params"] = .object(frame["params"].object.filter { !["password", "value", "secret"].contains($0.key) })
        } else if method == "event", ["sudo.request", "secret.request"].contains(frame["params"]["type"].text) {
            var event = frame["params"]
            event["payload"] = .object(event["payload"].object.filter { !["password", "value", "secret"].contains($0.key) })
            result["params"] = event
        }
        return result
    }

    // Authentication stays in HTTP headers; it never enters this recorder.
    private func record(_ direction: String, data: Data) async throws {
        guard let historyRecorder else { return }
        let frame = try HermesValue.decode(data)
        if frame["method"].text == "event", frame["params"]["type"].text.hasPrefix("config.") { return }
        // Session configuration can expose credentials outside the native run.
        if direction == "out", let id = frame["id"].string,
           frame["method"].text.hasPrefix("config.") || configurationRequestIDs.contains(id) {
            configurationRequestIDs.insert(id)
            return
        }
        if direction == "in", configurationRequestIDs.remove(frame["id"].text) != nil { return }
        if direction == "in", ["sudo", "secret"].contains(frame["method"].text), let id = frame["id"].string {
            secretRequestIDs.insert(id)
        }
        let safe = Self.credentialSafeFrame(frame, secretRequestIDs: secretRequestIDs)
        try await historyRecorder(direction, safe == frame ? data : NativeHarnessArchive.encode(safe))
        if direction == "out", frame["method"].isNull { secretRequestIDs.remove(frame["id"].text) }
    }

    private func receive(_ frame: HermesValue, generation current: UUID) async {
        guard generation == current else { return }
        if let id = frame["id"].string, frame["method"].string != nil {
            if let requestHandler { await requestHandler(frame) }
            else {
                try? await send(["jsonrpc": "2.0", "id": .string(id),
                    "error": ["code": .number(-32601), "message": "This client does not support this request."]])
            }
        } else if let id = frame["id"].string {
            timeouts.removeValue(forKey: id)?.cancel()
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if !frame["error"].isNull {
                continuation.resume(throwing: HermesGatewayError.rpc(code: Int(frame["error"]["code"].number ?? 0), message: frame["error"]["message"].string ?? "RPC rejected"))
            } else { continuation.resume(returning: frame["result"]) }
        } else if frame["method"].text == "event" {
            let event = frame["params"]
            if event["type"].text == "gateway.ready" { epoch = event["payload"]["replay_epoch"].string }
            // The reader must keep draining while a UI approval or replay RPC is pending.
            await eventHandler?(event)
        }
    }

    private func cancelRequest(_ id: String, unsent: Bool) {
        guard unsent else { expire(id); return }
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func expire(_ id: String) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: HermesGatewayError.message("Hermes request was not acknowledged. It may have been accepted; it has not been resent."))
    }
    private func failPending() {
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: HermesGatewayError.message("Hermes Gateway disconnected. Pending input has not been resent.")) }
    }
    private func failed(generation current: UUID) async {
        guard generation == current else { return }
        socket = nil; failPending()
        // Separate from reader so reconnect can create and drain a new socket.
        let handler = disconnectHandler
        Task { await handler?() }
    }
}
