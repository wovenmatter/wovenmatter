import Foundation

extension BackendApplicationService {
    func executeBots(_ command: BotsCommand) async throws -> BackendApplicationResult {
        guard let supervisor = model.piBotSupervisor else { throw ApplicationModelError.dashboardStoreUnavailable }
        return .init(bots: try await supervisor.perform(command))
    }
}
