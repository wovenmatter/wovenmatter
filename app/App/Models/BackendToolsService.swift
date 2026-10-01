import Foundation
import WovenMatterCore

extension BackendApplicationService {
    func executeToolsMutation(_ mutation: BackendToolsMutation) async throws -> BackendApplicationResult {
        guard let tools = model.agentTools, let database = model.dashboardStore?.database else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        do {
            switch mutation {
            case let .saveTimer(timer):
                _ = try await database.saveSessionTimer(timer, callerID: timer.sessionID)
            case let .saveSettings(value): try await database.saveToolSettings(value)
            case let .setEnabled(group, enabled, id, confirmed):
                try await tools.setEnabled(group, enabled: enabled, sessionID: id, confirmedPausingTimers: confirmed)
            case let .endCoordination(id): try await database.endCoordination(targetID: id)
            case let .notifications(id, enabled):
                if let source = try await database.sessionRelationship(id).coordinatorID {
                    try await database.setCoordinationNotifications(sourceID: source, targetID: id, enabled: enabled)
                }
            case let .pauseTimer(id, paused): try await database.pauseSessionTimer(id: id, paused: paused)
            case let .removeTimer(id): try await database.removeSessionTimer(id: id)
            }
            try await tools.reload()
            await invalidations.publish(scopes: [.settings])
            return .init()
        } catch WorkspaceToolError.timerPauseConfirmation {
            return .init(accepted: false, requiresTimerPauseConfirmation: true)
        }
    }
}
