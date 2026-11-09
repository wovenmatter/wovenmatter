import Foundation
import WovenMatterClient

/// The engine bots run in on this Mac: Woven's own Linux VM running Docker Engine.
/// The Mac VM workstream provides the production implementation; the bots host
/// codes only against this protocol. See docs/architecture/WOVEN_EVERYWHERE.md.
@MainActor
protocol BotEngineHost: AnyObject {
    /// Starts the VM if needed, applies `resources`, and returns once Docker Engine
    /// answers on the returned Unix socket. Repeated calls while running are cheap.
    func ensureRunning(resources: BotResourceSettings) async throws -> BotEngineStatus
    func status() async -> BotEngineStatus
    /// Applies the RAM pool and disk cap to the VM. Raising disk is immediate;
    /// lowering it stops at what is already used.
    func apply(resources: BotResourceSettings) async throws
    /// What bots already store, for the disk cap's lower bound. nil when unknown.
    func diskUsedByBots() async -> Int64?
    /// Forwards a container port inside the VM to a loopback port on this Mac.
    func forwardPort(botID: String, containerPort: Int) async throws -> UInt16
    func removeForward(botID: String, containerPort: Int) async
    /// Stops containers and the VM, for quit or when bots are turned off here.
    func stop() async
}

struct BotEngineStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case stopped, starting, running, failed, unavailable }
    var state: State
    /// The Docker Engine API socket under the app's support directory.
    var socketPath: String?
    var message: String?
}

/// Used until the VM implementation is linked in: bots stay off with a clear reason.
@MainActor
final class UnavailableBotEngineHost: BotEngineHost {
    private let reason: String
    init(reason: String = "This build doesn't include the bots VM yet.") { self.reason = reason }
    func ensureRunning(resources: BotResourceSettings) async throws -> BotEngineStatus {
        throw BotsError.unavailable(reason)
    }
    func status() async -> BotEngineStatus { .init(state: .unavailable, message: reason) }
    func apply(resources: BotResourceSettings) async throws {}
    func diskUsedByBots() async -> Int64? { nil }
    func forwardPort(botID: String, containerPort: Int) async throws -> UInt16 { throw BotsError.unavailable(reason) }
    func removeForward(botID: String, containerPort: Int) async {}
    func stop() async {}
}

enum BotEngineHostFactory {
    /// Integration replaces this with the VM workstream's implementation.
    @MainActor static var make: @MainActor (_ supportDirectory: URL) -> any BotEngineHost = { _ in UnavailableBotEngineHost() }
}
