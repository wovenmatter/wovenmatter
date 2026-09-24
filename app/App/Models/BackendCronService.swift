import Foundation
import WovenMatterClient
import WovenMatterCore

/// Scheduled-job operations resolve agent and job identities on the execution owner.
enum BackendCronCommand: Codable, Sendable {
    case refreshHermes
    case continueHermes(agentID: UUID, resultID: String)
    case createHermes(agentID: UUID, name: String, schedule: String, prompt: String)
    case routeHermes(agentID: UUID, jobID: String, destination: String)
    case changeHermes(agentID: UUID, jobID: String, action: String)
    case refreshOpenClaw
    case saveOpenClaw(agentID: UUID, jobID: String?, name: String, message: String,
                      expression: String, timeZone: String, declarationKey: String,
                      destination: String, preserveSchedule: Bool)
    case actionOpenClaw(agentID: UUID, jobID: String, action: String)
    case routeOpenClaw(agentID: UUID, jobID: String, destination: String)
    case emptyOpenClawTrash
    case openClawContext(agentID: UUID, context: String?)
}

struct BackendCronSnapshot: Codable, Sendable {
    var hermesAgentIDs: Set<UUID>
    var hermesJobs: [UUID: [HermesValue]]
    var hermesResults: [UUID: [HermesScheduledResult]]
    var hermesRoutes: [UUID: [String: String]]
    var hermesErrors: [UUID: String]
    var refreshingHermes: Bool
    var openClawJobs: [OpenClawCronJob]
    var openClawRuns: [OpenClawCronRun]
    var openClawRoutes: [UUID: [String: String]]
    var refreshingOpenClaw: Bool
    var openClawBusy: Bool
    var openClawError: String?
}

struct BackendCronResponse: Codable, Sendable {
    var snapshot: BackendCronSnapshot
    var accepted: Bool = true
    var conversationID: String?
    var error: String?
}
