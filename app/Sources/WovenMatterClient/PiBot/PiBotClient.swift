import Foundation

/// One WebSocket to a Pi Bot server, with request correlation and reconnects.
/// Native code uses it for sidebar data and host requests; chat and threads run in
/// Pi Bot's own client inside the web view, over that client's own socket.
public actor PiBotClient {
    public enum ConnectionState: String, Sendable { case connecting, open, closed }
    public enum Event: Sendable {
        case state(ConnectionState)
        case hello(PiBotHealth)
        case botsChanged
        case groupsChanged
        case threadsChanged(botID: String)
    }

    public struct RemoteError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let socketURL: URL
    private let onEvent: @Sendable (Event) -> Void
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<GatewayJSONValue, any Error>] = [:]
    private var stopped = true
    private var attempt = 0
    private var reconnect: Task<Void, Never>?
    private var generation = 0
    public private(set) var state = ConnectionState.closed

    public init(baseURL: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        components.query = nil
        socketURL = components.url!
        self.onEvent = onEvent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func connect() {
        stopped = false
        guard task == nil else { return }
        open()
    }

    public func close() {
        stopped = true
        reconnect?.cancel(); reconnect = nil
        generation += 1
        task?.cancel(with: .goingAway, reason: nil); task = nil
        failPending("Connection closed.")
        update(.closed)
    }

    /// Closes the session as well, for a client that will not be reused.
    public func invalidate() {
        close()
        session.invalidateAndCancel()
    }

    private func open() {
        generation += 1
        let current = generation
        update(.connecting)
        let socket = session.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 16 * 1024 * 1024
        task = socket
        socket.resume()
        Task { await self.receive(socket, generation: current) }
    }

    private func receive(_ socket: URLSessionWebSocketTask, generation current: Int) async {
        while generation == current {
            do {
                let message = try await socket.receive()
                guard generation == current else { return }
                if case .string(let text) = message { handle(text) }
                else if case .data(let data) = message { handle(String(decoding: data, as: UTF8.self)) }
            } catch {
                guard generation == current else { return }
                disconnected()
                return
            }
        }
    }

    private func disconnected() {
        task = nil
        failPending("Connection lost.")
        update(.closed)
        guard !stopped else { return }
        let delay = min(0.5 * pow(2, Double(attempt)), 10)
        attempt += 1
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.reopen()
        }
    }

    private func reopen() {
        guard !stopped, task == nil else { return }
        open()
    }

    private func failPending(_ reason: String) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: RemoteError(message: reason)) }
    }

    private func update(_ next: ConnectionState) {
        guard state != next else { return }
        state = next
        onEvent(.state(next))
    }

    private func handle(_ text: String) {
        guard let value = try? JSONDecoder().decode(GatewayJSONValue.self, from: Data(text.utf8)),
              let object = value.objectValue, let type = object["type"]?.stringValue else { return }
        switch type {
        case "hello":
            attempt = 0
            update(.open)
            if let data = try? JSONEncoder().encode(value),
               let hello = try? JSONDecoder().decode(PiBotHello.self, from: data) {
                onEvent(.hello(PiBotHealth(ok: true, version: hello.version, protocol: hello.protocol,
                    installationId: hello.installationId, capabilities: hello.capabilities)))
            }
        case "result":
            guard let id = object["id"]?.intValue, let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(returning: object["data"] ?? .null)
        case "error":
            guard let id = object["id"]?.intValue, let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(throwing: RemoteError(message: object["message"]?.stringValue ?? "Pi Bot returned an error."))
        case "bots.changed": onEvent(.botsChanged)
        case "groups.changed": onEvent(.groupsChanged)
        case "threads.changed":
            if let botID = object["botId"]?.stringValue { onEvent(.threadsChanged(botID: botID)) }
        default: break
        }
    }

    private func call(_ type: String, _ fields: [String: GatewayJSONValue] = [:]) async throws -> GatewayJSONValue {
        guard let socket = task, state == .open else { throw RemoteError(message: "Pi Bot is not connected.") }
        let id = nextID
        nextID += 1
        var body = fields
        body["id"] = .number(Double(id))
        body["type"] = .string(type)
        let text = String(decoding: try JSONEncoder().encode(GatewayJSONValue.object(body)), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await socket.send(.string(text)) }
                catch { self.resolveFailure(id: id, error) }
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.resolveFailure(id: id, RemoteError(message: "\(type) timed out."))
            }
        }
    }

    private func resolveFailure(id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func decode<T: Decodable>(_ value: GatewayJSONValue, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private struct BotsResult: Decodable { let bots: [PiBotSummary] }
    private struct BotResult: Decodable { let bot: PiBotSummary }
    private struct ThreadsResult: Decodable { let threads: [PiBotThread] }
    private struct GroupsResult: Decodable { let groups: [PiBotGroup] }
    private struct GroupResult: Decodable { let group: PiBotGroup }

    public func bots() async throws -> [PiBotSummary] { try decode(try await call("bots.list"), as: BotsResult.self).bots }
    public func threads(botID: String) async throws -> [PiBotThread] {
        try decode(try await call("threads.list", ["botId": .string(botID)]), as: ThreadsResult.self).threads
    }
    public func groups() async throws -> [PiBotGroup] { try decode(try await call("groups.list"), as: GroupsResult.self).groups }
    @discardableResult public func createBot(name: String) async throws -> PiBotSummary {
        try decode(try await call("bots.create", ["name": .string(name)]), as: BotResult.self).bot
    }
    public func renameBot(id: String, name: String) async throws {
        _ = try await call("bots.rename", ["botId": .string(id), "name": .string(name)])
    }
    public func deleteBot(id: String) async throws { _ = try await call("bots.delete", ["botId": .string(id)]) }
    public func setPinned(botID: String, conversationID: Int, pinned: Bool) async throws {
        _ = try await call("thread.setPinned", ["botId": .string(botID), "conversationId": .number(Double(conversationID)), "pinned": .bool(pinned)])
    }
    @discardableResult public func createGroup(name: String) async throws -> PiBotGroup {
        try decode(try await call("groups.create", ["name": .string(name)]), as: GroupResult.self).group
    }
    public func renameGroup(id: String, name: String) async throws {
        _ = try await call("groups.rename", ["groupId": .string(id), "name": .string(name)])
    }
    public func deleteGroup(id: String) async throws { _ = try await call("groups.delete", ["groupId": .string(id)]) }
    public func reorderGroups(ids: [String]) async throws {
        _ = try await call("groups.reorder", ["groupIds": .array(ids.map(GatewayJSONValue.string))])
    }
    public func setGroup(botID: String, groupID: String?) async throws {
        _ = try await call("bots.setGroup", ["botId": .string(botID), "groupId": groupID.map(GatewayJSONValue.string) ?? .null])
    }
    public func wovenStatus() async throws -> PiBotWovenStatus { try decode(try await call("woven.status")) }
    public func wovenConnect(endpointURL: String, bearerToken: String) async throws -> PiBotWovenStatus {
        try decode(try await call("woven.connect", ["endpointURL": .string(endpointURL), "bearerToken": .string(bearerToken)]))
    }
    public func wovenDisconnect() async throws -> PiBotWovenStatus { try decode(try await call("woven.disconnect")) }
    public func send(botID: String, text: String) async throws {
        _ = try await call("message.send", ["botId": .string(botID), "text": .string(text)])
    }
}

private struct PiBotHello: Decodable {
    let version: String
    let `protocol`: Int?
    let installationId: String?
    let capabilities: [String]?
}
