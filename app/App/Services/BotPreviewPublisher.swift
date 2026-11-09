import Foundation
import Network
import WovenMatterDashboardStore

/// One shared container port: VM forward → activity proxy → Tailscale Serve on its own
/// HTTPS port of this Mac's tailnet name. Inbound only; never Funnel.
struct BotPreview: Codable, Equatable, Sendable {
    let botID: String
    let port: Int
    let url: URL
    /// The last byte through the proxy, for the bot's idle check.
    var lastActivityAt: Date
}

@MainActor
final class BotPreviewPublisher {
    typealias MakeServe = @MainActor () -> CompanionTailscaleServe
    private struct Key: Hashable { let botID: String; let port: Int }
    private struct Published {
        var preview: BotPreview
        let proxy: BotActivityProxy
        let serve: CompanionTailscaleServe
    }
    private let engine: any BotEngineHost
    private let makeServe: MakeServe
    private var published: [Key: Published] = [:]
    static let maximumPreviews = 32

    init(engine: any BotEngineHost, makeServe: @escaping MakeServe = { CompanionTailscaleServe() }) {
        self.engine = engine; self.makeServe = makeServe
    }

    func publish(botID: String, port: Int) async throws -> URL {
        guard (1...65535).contains(port) else { throw BotsHostAPIError.invalid("Choose a container port from 1 to 65535.") }
        let key = Key(botID: botID, port: port)
        if let existing = published[key], existing.serve.isRunning { return existing.preview.url }
        await remove(botID: botID, port: port)
        guard published.count < Self.maximumPreviews else { throw BotsHostAPIError.invalid("Stop sharing another preview first.") }
        let forwarded = try await engine.forwardPort(botID: botID, containerPort: port)
        let proxy = BotActivityProxy(targetPort: forwarded)
        let serve = makeServe()
        do {
            let proxyPort = try await proxy.start()
            let url = try await serve.start(loopbackPort: proxyPort, allowPortFallback: true, path: "/")
            published[key] = .init(preview: .init(botID: botID, port: port, url: url, lastActivityAt: Date()), proxy: proxy, serve: serve)
            return url
        } catch {
            proxy.stop(); serve.stop()
            await engine.removeForward(botID: botID, containerPort: port)
            throw error
        }
    }

    func remove(botID: String, port: Int) async {
        guard let entry = published.removeValue(forKey: .init(botID: botID, port: port)) else { return }
        entry.serve.stop(); entry.proxy.stop()
        await engine.removeForward(botID: botID, containerPort: port)
    }

    func removeAll() async {
        for key in Array(published.keys) { await remove(botID: key.botID, port: key.port) }
    }

    var previews: [BotPreview] {
        published.values.map { entry in
            var preview = entry.preview
            preview.lastActivityAt = max(preview.lastActivityAt, entry.proxy.lastActivityAt)
            return preview
        }.sorted { ($0.botID, $0.port) < ($1.botID, $1.port) }
    }
}

/// A loopback TCP relay that records when bytes last moved, so preview traffic keeps a
/// bot awake. It does not parse or log what passes through.
final class BotActivityProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.wovenmatter.bots.preview-proxy")
    private let targetPort: UInt16
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var activity = Date()
    private let lock = NSLock()

    init(targetPort: UInt16) { self.targetPort = targetPort }

    var lastActivityAt: Date { lock.withLock { activity } }
    private func touch() { lock.withLock { activity = Date() } }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
        let once = BotResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ inbound: NWConnection) {
        guard connections.count < 256, let port = NWEndpoint.Port(rawValue: targetPort) else { inbound.cancel(); return }
        let outbound = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        for connection in [inbound, outbound] {
            connections[ObjectIdentifier(connection)] = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close(inbound, outbound)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        touch()
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.touch()
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    if sendError != nil { self?.close(source, destination); return }
                    if complete || error != nil { destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
                    else { self?.pump(from: source, to: destination) }
                })
            } else if complete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                if error != nil { self.close(source, destination) }
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    private func close(_ first: NWConnection, _ second: NWConnection) {
        for connection in [first, second] {
            connections.removeValue(forKey: ObjectIdentifier(connection))
            connection.cancel()
        }
    }
}

private final class BotResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
