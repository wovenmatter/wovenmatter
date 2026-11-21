import Foundation
import Observation
#if os(iOS)
import Synchronization
#endif
import WovenProtocol

/// The UI's connection to one machine's server. It keeps reconnecting with
/// backoff while it is wanted, says whether it is connected now, and opens
/// each followed subscription again after every reconnect.
@MainActor
@Observable
final class ServerConnection {
    /// Where the server listens; nil for a server in this process.
    let endpoint: ServerEndpoint?
    private(set) var isConnected = false
    /// The server's hello on the current or last connection.
    private(set) var remote: Hello?

    @ObservationIgnored private var client: Client?
    /// Counts connections, so a follower can tell a new one from the one it lost.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private let hello: Hello
    /// Followers waiting for a new connection, woken when one opens.
    @ObservationIgnored private var connectionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    #if os(iOS)
    /// Opens a new connection to a server in this process, such as the device's own core.
    @ObservationIgnored private var connector: (@Sendable () async throws -> any MessageTransport)?

    init(connector: @escaping @Sendable () async throws -> any MessageTransport) {
        self.endpoint = nil
        self.connector = connector
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        hello = Hello(role: .ui, machine: WovenProtocol.Machine(id: "ui-" + UUID().uuidString.lowercased(), name: "Woven Matter"),
                      appVersion: version)
    }
    #endif

    init(endpoint: ServerEndpoint) {
        self.endpoint = endpoint
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        hello = Hello(role: .ui, machine: WovenProtocol.Machine(id: "ui-" + UUID().uuidString.lowercased(), name: "Woven Matter"),
                      appVersion: version)
    }

    func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in await self?.run() }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        Task { [client] in await client?.close() }
        client = nil
        isConnected = false
    }

    private func run() async {
        var delay = Duration.milliseconds(250)
        while !Task.isCancelled {
            do {
                let (transport, closed) = try await open()
                let client = Client(transport: transport)
                let remote = try await client.open(hello)
                guard !Task.isCancelled else {
                    await client.close()
                    return
                }
                self.client = client
                self.remote = remote
                generation += 1
                isConnected = true
                wakeConnectionWaiters()
                delay = .milliseconds(250)
                await closed()
                await client.close()
                if self.client === client { self.client = nil }
                isConnected = false
            } catch {}
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(10))
        }
    }

    /// A new transport, and what returns once it has closed.
    private func open() async throws -> (any MessageTransport, @Sendable () async -> Void) {
        #if os(iOS)
        if let connector {
            let transport = WatchedTransport(try await connector())
            return (transport, { await transport.closed() })
        }
        #endif
        let transport = try await SocketTransport.connect(endpoint!)
        return (transport, { await transport.closed() })
    }

    // MARK: Requests

    func call<R: Request>(_ request: R) async throws -> R.Reply {
        guard let client else { throw ClientError.notConnected }
        do {
            return try await client.call(request)
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ClientError.notConnected
        }
    }

    /// Keeps `request` open until the calling task is cancelled: `reply` gets
    /// the reply of every opening (the first and one after each reconnect),
    /// `event` each event, `failure` a refusal (it is tried again later).
    func follow<S: Subscription>(
        _ request: S,
        reply: @MainActor (S.Reply) -> Void,
        event: @MainActor (S.Event) -> Void,
        failure: @MainActor (ProtocolError) -> Void = { _ in }
    ) async {
        var used = 0
        while !Task.isCancelled {
            guard let (client, current) = await connection(newerThan: used) else { return }
            do {
                let subscription = try await client.subscribe(request)
                reply(subscription.reply)
                do {
                    for try await value in subscription.events { event(value) }
                } catch {}
                if Task.isCancelled {
                    Task { try? await client.unsubscribe(subscription.id) }
                    return
                }
                // The server ended it on a live connection: open it again there.
                used = self.client === client ? current - 1 : current
                try? await Task.sleep(for: .seconds(1))
            } catch let error as ProtocolError {
                failure(error)
                used = current - 1
                try? await Task.sleep(for: .seconds(5))
            } catch {
                used = current
            }
        }
    }

    /// The current client once its connection is newer than `generation`;
    /// nil when the task is cancelled first.
    /// It waits without polling: a connection to a machine that is away may
    /// not open for hours, and nothing should wake meanwhile.
    private func connection(newerThan generation: Int) async -> (Client, Int)? {
        while !Task.isCancelled {
            if let client, self.generation > generation { return (client, self.generation) }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() } else { connectionWaiters[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.connectionWaiters.removeValue(forKey: id)?.resume() }
            }
        }
        return nil
    }

    private func wakeConnectionWaiters() {
        let waiters = connectionWaiters
        connectionWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }
}

#if os(iOS)
/// Passes another transport through and says when it has closed, as
/// `SocketTransport` does, for a server in this process.
private final class WatchedTransport: MessageTransport, Sendable {
    let incoming: AsyncThrowingStream<String, any Error>
    private let base: any MessageTransport
    private let state = Mutex<(isClosed: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    init(_ base: any MessageTransport) {
        self.base = base
        let (incoming, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        self.incoming = incoming
        let source = base.incoming
        Task { [self] in
            do {
                for try await text in source { continuation.yield(text) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            finish()
        }
    }

    private func finish() {
        let waiters = state.withLock { state in
            state.isClosed = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func send(_ text: String) throws { try base.send(text) }
    func sendWhenWritten(_ text: String) async throws { try await base.sendWhenWritten(text) }
    func close() { base.close() }

    func closed() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state in
                if state.isClosed { return true }
                state.waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}
#endif
