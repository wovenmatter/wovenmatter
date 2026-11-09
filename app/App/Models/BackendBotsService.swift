import Foundation
import WovenMatterClient

extension BackendApplicationService {
    func executeBots(_ command: BotsCommand) async throws -> BackendApplicationResult {
        guard let host = model.botsHost else { throw BotsError.unavailable("Bots are still starting.") }
        return .init(bots: try await host.perform(command))
    }
}
