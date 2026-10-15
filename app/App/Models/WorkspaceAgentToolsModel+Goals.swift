import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceAgentToolsModel {
    func goal(_ command: WovenMatterToolCommand, callerID: String, requestID: String) async throws -> WovenMatterToolResponse {
        if command.action == "get" {
            return try .value(await database.sessionGoals().first { $0.sessionID == callerID })
        }
        let mutation: WorkspaceGoalMutation
        if command.action == "set" {
            let tokens = try command.options["token-budget"].map { _ in Int64(try command.integer("token-budget", default: 1, range: 1...1_000_000_000)) }
            let turns = try command.options["turn-budget"].map { _ in try command.integer("turn-budget", default: 1, range: 1...10_000) }
            mutation = .set(objective: try command.required("objective"), tokenBudget: tokens, turnBudget: turns)
        } else {
            let id = try command.required("id")
            switch command.action {
            case "pause": mutation = .pause(id: id)
            case "resume": mutation = .resume(id: id)
            case "clear": mutation = .clear(id: id)
            case "complete": mutation = .complete(id: id, evidence: try command.required("evidence"))
            case "block": mutation = .block(id: id, evidence: try command.required("evidence"))
            case "checkpoint": mutation = .checkpoint(id: id, evidence: try command.required("evidence"))
            default: throw WorkspaceToolError.invalid("Unsupported goal operation.")
            }
        }
        return try .value(await database.mutateGoal(sessionID: callerID, mutation: mutation,
            callerID: callerID, requestID: requestID))
    }

    func mutateGoalFromUI(sessionID: String, mutation: WorkspaceGoalMutation) async throws {
        if let backendMutation { try await backendMutation(.goal(sessionID: sessionID, mutation: mutation)) }
        else if let goalControl { try await goalControl(sessionID, mutation) }
        else { throw WorkspaceToolError.invalid("The execution service is unavailable.") }
        try await reload()
    }
}
