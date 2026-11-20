import Foundation
import Observation
import WovenProtocol

/// The UI's connection to one machine's server. It keeps reconnecting with
/// backoff while it is wanted, says whether it is connected now, and opens
/// each followed subscription again after every reconnect.
@MainActor
@Observable
final class ServerConnection {
    let endpoint: ServerEndpoint
    private(set) var isConnected = false
    /// The server's hello on the current or last connection.
    private(set) var remote: Hello?

    @ObservationIgnored private var client: Client?
    /// Counts connections, so a follower can tell a new one from the one it lost.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private let hello: Hello

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
                let transport = try await SocketTransport.connect(endpoint)
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
                delay = .milliseconds(250)
                await transport.closed()
                await client.close()
                if self.client === client { self.client = nil }
                isConnected = false
            } catch {}
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(10))
        }
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
    private func connection(newerThan generation: Int) async -> (Client, Int)? {
        while !Task.isCancelled {
            if let client, self.generation > generation { return (client, self.generation) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}
