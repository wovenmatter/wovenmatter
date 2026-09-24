import Foundation
import WovenMatterCore

extension BackendApplicationService {
    func executeToolsMutation(_ mutation: BackendToolsMutation) async throws -> BackendApplicationResult {
        guard let tools = model.agentTools, let database = model.dashboardStore?.database else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        do {
            switch mutation {
            case let .saveSettings(value): try database.saveToolSettings(value)
            case let .setEnabled(group, enabled, id, confirmed):
                try tools.setEnabled(group, enabled: enabled, sessionID: id, confirmedPausingTimers: confirmed)
            case let .endCoordination(id): try database.endCoordination(targetID: id)
            case let .notifications(id, enabled):
                if let source = try database.sessionRelationship(id).coordinatorID {
                    try database.setCoordinationNotifications(sourceID: source, targetID: id, enabled: enabled)
                }
            case let .pauseTimer(id, paused): try database.pauseSessionTimer(id: id, paused: paused)
            case let .removeTimer(id): try database.removeSessionTimer(id: id)
            }
            try tools.reload()
            await invalidations.publish(scopes: [.settings])
            return .init()
        } catch WorkspaceToolError.timerPauseConfirmation {
            return .init(accepted: false, requiresTimerPauseConfirmation: true)
        }
    }
}
