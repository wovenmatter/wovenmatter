import Foundation

protocol HermesGatewayTransport: Sendable {
    var epoch: String? { get async }
    var isConnected: Bool { get async }
    func setHandlers(event: HermesGatewayRPC.EventHandler?, disconnected: (@Sendable () async -> Void)?, request: HermesGatewayRPC.EventHandler?) async
    func connect() async throws
    func disconnect() async
    func call(_ method: String, _ params: HermesValue) async throws -> HermesValue
    func respond(id: String, result: HermesValue) async throws
}

/// Native Hermes JSON-RPC 2.0, including newline-batched WebSocket frames.
public actor HermesGatewayRPC: HermesGatewayTransport {
    public typealias EventHandler = @Sendable (HermesValue) async -> Void
    public let connection: HermesGatewayConnection
    private let session: URLSession
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

    public init(connection: HermesGatewayConnection) {
        self.connection = connection
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
    }

    public func call(_ method: String, _ params: HermesValue = [:]) async throws -> HermesValue {
        guard let socket else { throw HermesGatewayError.message("Hermes Gateway is disconnected.") }
        let id = UUID().uuidString
        let frame: HermesValue = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]
        let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    if !Task.isCancelled { await self?.expire(id) }
                }
                Task {
                    do { try await socket.send(.string(text)) }
                    catch { self.expire(id) }
                }
            }
        } onCancel: { Task { await self.expire(id) } }
    }

    public func respond(id: String, result: HermesValue) async throws {
        try await send(["jsonrpc": "2.0", "id": .string(id), "result": result])
    }

    private func send(_ frame: HermesValue) async throws {
        guard let socket else { throw HermesGatewayError.message("Hermes Gateway is disconnected.") }
        try await socket.send(.string(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)))
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
