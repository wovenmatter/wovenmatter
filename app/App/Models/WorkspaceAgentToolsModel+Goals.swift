import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceAgentToolsModel {
    func mutateGoalFromUI(sessionID: String, mutation: WorkspaceGoalMutation) async throws {
        if let backendMutation { try await backendMutation(.goal(sessionID: sessionID, mutation: mutation)) }
        else if let goalControl { try await goalControl(sessionID, mutation) }
        else { throw WorkspaceToolError.invalid("The execution service is unavailable.") }
        try await reload()
    }
}
