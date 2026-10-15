import Foundation

/// Owner-local state for runtimes without the desktop run database. Persist this
/// value before submitting input. An interrupted claim is never replayed.
public struct WorkspaceGoalLedger: Codable, Equatable, Sendable {
    public var goal: WorkspaceGoal?
    public var runIDs: Set<String> = []
    public var settledRunIDs: Set<String> = []
    public var runTokens: [String: Int64] = [:]
    public var claims: [String: String] = [:]
    public var receipts: [String: Receipt] = [:]
    public struct Receipt: Codable, Equatable, Sendable {
        public var mutation: WorkspaceGoalMutation
        public var result: WorkspaceGoal?
    }
    public init(goal: WorkspaceGoal? = nil) { self.goal = goal }

    public mutating func mutate(_ mutation: WorkspaceGoalMutation, requestID: String? = nil, currentRunID: String? = nil, sessionID: String? = nil) throws -> WorkspaceGoal? {
        if let requestID, let receipt = receipts[requestID] {
            guard receipt.mutation == mutation else { throw WorkspaceToolError.invalid("This request ID belongs to another goal change.") }
            return receipt.result
        }
        switch mutation {
        case let .set(objective, tokens, turns):
            try WorkspaceGoal.validate(objective: objective, tokenBudget: tokens, turnBudget: turns)
            guard goal == nil || goal?.status == .complete else { throw WorkspaceToolError.invalid("Clear or edit the existing goal first.") }
            goal = WorkspaceGoal(sessionID: sessionID ?? goal?.sessionID ?? "", objective: objective, tokenBudget: tokens, turnBudget: turns)
            runIDs = []; settledRunIDs = []; runTokens = [:]; claims = [:]
            if let currentRunID { runIDs.insert(currentRunID) }
        default:
            guard var value = goal else { throw WorkspaceToolError.notFound("No goal is set.") }
            let id: String
            switch mutation {
            case .edit(let target, _, _, _), .pause(let target), .resume(let target), .clear(let target), .complete(let target, _), .block(let target, _), .checkpoint(let target, _): id = target
            case .set: fatalError("Handled above")
            }
            guard id == value.id else { throw WorkspaceToolError.invalid("This goal has changed. Refresh before updating it.") }
            switch mutation {
            case let .edit(_, objective, tokens, turns):
                try WorkspaceGoal.validate(objective: objective, tokenBudget: tokens, turnBudget: turns)
                value.id = UUID().uuidString.lowercased(); value.objective = objective
                value.tokenBudget = tokens; value.turnBudget = turns; value.status = .paused
                value.pendingDeliveryID = nil; claims = [:]
            case .pause:
                guard value.status != .complete else { throw WorkspaceToolError.invalid("Set a new goal after completion.") }
                value.status = .paused; value.pendingDeliveryID = nil; claims = [:]
            case .resume:
                guard value.status != .complete else { throw WorkspaceToolError.invalid("Set a new goal after completion.") }
                if value.status != .active {
                    guard value.tokenBudget == nil || !runIDs.contains(where: { $0 != currentRunID && runTokens[$0] == nil }) else {
                        throw WorkspaceToolError.invalid("Token usage is unavailable; remove the token budget before resuming.")
                    }
                    guard !budgetReached else { throw WorkspaceToolError.invalid("Increase or remove the budget before resuming.") }
                    value.status = .active; value.evidence = nil; value.pendingDeliveryID = nil
                    value.pendingProgressRevision = value.progressRevision - 1
                    claims = [:]
                    if let currentRunID { runIDs.insert(currentRunID) }
                }
            case .clear: goal = nil; claims = [:]
            case .complete(_, let evidence), .block(_, let evidence), .checkpoint(_, let evidence):
                guard value.status == .active else { throw WorkspaceToolError.invalid("Only an active goal can report progress.") }
                let evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !evidence.isEmpty, evidence.utf8.count <= 4096 else { throw WorkspaceToolError.invalid("Provide evidence of at most 4 KiB.") }
                value.evidence = evidence
                if case .complete = mutation { value.status = .complete; value.pendingDeliveryID = nil; claims = [:] }
                else if case .block = mutation { value.status = .blocked; value.pendingDeliveryID = nil; claims = [:] }
                else if evidence != goal?.evidence { value.progressRevision += 1 }
            case .set: break
            }
            if case .clear = mutation {} else { value.updatedAt = Date(); goal = value }
        }
        if let requestID { receipts[requestID] = Receipt(mutation: mutation, result: goal) }
        return goal
    }

    public mutating func enroll(_ runID: String) {
        guard goal?.status == .active else { return }
        runIDs.insert(runID)
        if goal?.pendingDeliveryID == runID { goal?.pendingDeliveryID = nil; claims.removeValue(forKey: runID) }
    }
    public mutating func settle(_ runID: String, tokens: Int64?, succeeded: Bool) {
        guard runIDs.contains(runID), settledRunIDs.insert(runID).inserted else { return }
        if let tokens, tokens >= 0 { runTokens[runID] = tokens }
        if succeeded { goal?.completedTurns += 1 }
        goal?.tokensUsed = settledRunIDs.allSatisfy { runTokens[$0] != nil } ? runTokens.values.reduce(Int64(0)) { total, value in let sum = total.addingReportingOverflow(value); return sum.overflow ? Int64.max : sum.partialValue } : nil
        guard goal?.status == .active else { return }
        if !succeeded { goal?.status = .blocked; goal?.evidence = "The run was interrupted or failed. Review its saved state before resuming." }
        else if goal?.tokenBudget != nil, goal?.tokensUsed == nil { goal?.status = .blocked; goal?.evidence = "Token usage is unavailable; the token budget cannot be enforced." }
        else if budgetReached { goal?.status = .budgetLimited }
        else if let value = goal, value.progressRevision <= value.pendingProgressRevision {
            goal?.status = .blocked; goal?.evidence = "The turn ended without a goal checkpoint. Review progress before resuming."
        }
        goal?.updatedAt = Date()
    }
    public var budgetReached: Bool {
        guard let goal else { return false }
        return goal.turnBudget.map { goal.completedTurns >= $0 } == true || goal.tokenBudget.map { (goal.tokensUsed ?? 0) >= $0 } == true
    }
    public mutating func claimContinuation(id: String) -> String? {
        guard var value = goal, value.status == .active, value.pendingDeliveryID == nil else { return nil }
        guard value.tokenBudget == nil || runIDs.allSatisfy({ runTokens[$0] != nil }) else {
            goal?.status = .blocked; goal?.evidence = "Token usage is unavailable; remove the token budget before resuming."
            return nil
        }
        guard !budgetReached else { goal?.status = .budgetLimited; return nil }
        // A fresh/resumed idle goal gets one initial attempt. Every settled run
        // after that must have produced a new checkpoint.
        if !runIDs.isEmpty && value.progressRevision <= value.pendingProgressRevision { return nil }
        value.pendingDeliveryID = id; value.pendingProgressRevision = value.progressRevision
        goal = value; claims[id] = value.id
        return value.continuationPrompt
    }
    public func authorizes(_ id: String) -> Bool { goal?.status == .active && goal?.pendingDeliveryID == id && claims[id] == goal?.id }
    public mutating func recover() {
        if goal?.status == .active { goal?.status = .paused; goal?.evidence = "Execution owner restarted or was interrupted. Resume explicitly." }
        goal?.pendingDeliveryID = nil; claims = [:]
    }
}

public extension WovenMatterToolCommand {
    func goalMutation() throws -> WorkspaceGoalMutation {
        if action == "set" {
            return .set(objective: try required("objective"),
                tokenBudget: try options["token-budget"].map { _ in Int64(try integer("token-budget", default: 1, range: 1...1_000_000_000)) },
                turnBudget: try options["turn-budget"].map { _ in try integer("turn-budget", default: 1, range: 1...10_000) })
        }
        let id = try required("id")
        switch action {
        case "pause": return .pause(id: id)
        case "resume": return .resume(id: id)
        case "clear": return .clear(id: id)
        case "complete": return .complete(id: id, evidence: try required("evidence"))
        case "block": return .block(id: id, evidence: try required("evidence"))
        case "checkpoint": return .checkpoint(id: id, evidence: try required("evidence"))
        default: throw WorkspaceToolError.invalid("Unsupported goal operation.")
        }
    }
}
