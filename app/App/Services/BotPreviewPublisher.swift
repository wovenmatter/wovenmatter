import Foundation
import WovenMatterDashboardStore

/// A shared container port. The runtime already carries it to a loopback activity proxy
/// over Engine API exec streams; this publishes that proxy with Tailscale Serve on its own
/// HTTPS port of this Mac's tailnet name. Inbound only; never Funnel.
struct BotPreview: Codable, Equatable, Sendable {
    let botID: String
    /// The runtime's loopback proxy port.
    let port: Int
    let containerPort: Int
    let url: URL
}

@MainActor
final class BotPreviewPublisher {
    typealias MakeServe = @MainActor () -> TailscaleServe
    private struct Key: Hashable { let botID: String; let port: Int }
    private struct Published { var preview: BotPreview; let serve: TailscaleServe }
    private let makeServe: MakeServe
    private var published: [Key: Published] = [:]
    static let maximumPreviews = 32

    init(makeServe: @escaping MakeServe = { TailscaleServe() }) { self.makeServe = makeServe }

    /// Idempotent for the same bot and port; the runtime sends it again after a restart.
    func publish(botID: String, port: Int, containerPort: Int) async throws -> URL {
        guard let loopback = UInt16(exactly: port), loopback >= 1024 else { throw BotsHostAPIError.invalid("Invalid preview port.") }
        let key = Key(botID: botID, port: port)
        if let existing = published[key], existing.serve.isRunning { return existing.preview.url }
        await remove(botID: botID, port: port)
        guard published.count < Self.maximumPreviews else { throw BotsHostAPIError.invalid("Stop sharing another preview first.") }
        let serve = makeServe()
        do {
            let url = try await serve.start(loopbackPort: loopback, allowPortFallback: true, path: "/")
            published[key] = .init(preview: .init(botID: botID, port: port, containerPort: containerPort, url: url), serve: serve)
            return url
        } catch {
            serve.stop()
            throw error
        }
    }

    func remove(botID: String, port: Int) async {
        guard let entry = published.removeValue(forKey: .init(botID: botID, port: port)) else { return }
        entry.serve.stop()
    }

    func removeAll() async {
        for key in Array(published.keys) { await remove(botID: key.botID, port: key.port) }
    }

    var previews: [BotPreview] { published.values.map(\.preview).sorted { ($0.botID, $0.port) < ($1.botID, $1.port) } }
}
