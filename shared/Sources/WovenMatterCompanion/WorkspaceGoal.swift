import Foundation

public enum WorkspaceGoalStatus: String, Codable, Sendable {
    case active, paused, blocked, complete
    case budgetLimited = "budget_limited"

    public var title: String {
        switch self {
        case .active: "Pursuing goal"
        case .paused: "Paused goal"
        case .blocked: "Goal stalled"
        case .complete: "Goal achieved"
        case .budgetLimited: "Goal budget reached"
        }
    }
}

/// One durable objective per conversation. Native provider sessions remain the
/// execution context; Woven Matter owns continuation across supported harnesses.
public struct WorkspaceGoal: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    public var objective: String
    public var status: WorkspaceGoalStatus = .active {
        didSet {
            guard status != oldValue else { return }
            let now = Date()
            if oldValue == .active, let activeSince {
                activeSeconds = (activeSeconds ?? 0) + max(0, now.timeIntervalSince(activeSince))
            }
            if status == .active {
                activeSeconds = activeSeconds ?? 0
                activeSince = now
            } else {
                activeSince = nil
            }
        }
    }
    /// Optional for saved goals created before elapsed pursuit tracking existed.
    public var activeSeconds: TimeInterval?
    public var activeSince: Date?
    public var tokenBudget: Int64?
    public var turnBudget: Int?
    public var tokensUsed: Int64?
    public var completedTurns = 0
    public var evidence: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var baselineRunSequence: Int64
    public var observedRunSequence: Int64
    public var enrolledRunSequence: Int64
    public var pendingDeliveryID: String?
    public var progressRevision = 0
    public var pendingProgressRevision = 0

    public init(sessionID: String, objective: String, tokenBudget: Int64? = nil,
                turnBudget: Int? = nil, baselineRunSequence: Int64 = 0, now: Date = Date()) {
        id = UUID().uuidString.lowercased()
        self.sessionID = sessionID; self.objective = objective
        self.tokenBudget = tokenBudget; self.turnBudget = turnBudget
        self.baselineRunSequence = baselineRunSequence
        observedRunSequence = baselineRunSequence
        enrolledRunSequence = baselineRunSequence
        createdAt = now; updatedAt = now
        activeSeconds = 0; activeSince = now
    }

    public func elapsedPursuitText(at now: Date) -> String {
        guard let activeSeconds else { return "Elapsed unavailable" }
        let elapsed = activeSeconds + (status == .active ? activeSince.map { max(0, now.timeIntervalSince($0)) } ?? 0 : 0)
        guard elapsed.isFinite, elapsed >= 0, elapsed < Double(Int.max) else { return "Elapsed unavailable" }
        let seconds = Int(elapsed)
        let duration = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(duration) elapsed"
    }

    public static func validate(objective: String, tokenBudget: Int64?, turnBudget: Int?) throws {
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !objective.contains("\0"), objective.utf8.count <= 16_384 else {
            throw WorkspaceToolError.invalid("A goal needs an objective of at most 16 KiB.")
        }
        guard tokenBudget.map({ (1...1_000_000_000).contains($0) }) ?? true,
              turnBudget.map({ (1...10_000).contains($0) }) ?? true else {
            throw WorkspaceToolError.invalid("Goal budgets must be positive: at most one billion tokens or 10,000 turns.")
        }
    }

    public static let guidance = """
    \n<wovenmatter-goals>
    When the user explicitly requests a goal, use `wovenmatter goals set --objective TEXT --request-id UUID`. Read `wovenmatter goals get`. Report verified completion with complete, useful unfinished progress with checkpoint, and blockers with block; supply --id, --evidence and a stable --request-id. Never complete because a turn or budget ended. Set, pause, resume and clear only when requested. Do not start a provider-native goal loop.
    </wovenmatter-goals>
    """

    public static func displayPrompt(_ text: String) -> String {
        if text.hasPrefix("<wovenmatter-goal-continuation>\n") { return "Continuing toward the goal." }
        let marker = "\n<wovenmatter-goals>\n"
        guard text.hasSuffix("</wovenmatter-goals>"),
              let range = text.range(of: marker, options: .backwards),
              text[range.upperBound...].contains("When the user explicitly requests a goal, use `wovenmatter goals set") else { return text }
        return String(text[..<range.lowerBound])
    }

    public var continuationPrompt: String {
        """
        <wovenmatter-goal-continuation>
        Continue the Woven Matter goal in this conversation:
        \(objective)

        Goal ID: \(id)
        Read `wovenmatter goals get` before working. This goal persists across turns.
        Use the current model, permissions, workspace and tools. Respect new user instructions.
        Do not start a provider-native /goal or a second continuation loop.
        Before ending, audit the objective against concrete evidence. If achieved, run
        `wovenmatter goals complete --id \(id) --evidence 'verification results' --request-id UUID`.
        If unfinished, make useful progress and run `wovenmatter goals checkpoint --id \(id)
        --evidence 'what changed, verification results, and next step' --request-id UUID`.
        If no useful path remains, use `wovenmatter goals block --id \(id) --evidence 'blocker and required input' --request-id UUID`.
        Never mark a goal complete because a turn ended or a budget was reached.
        Pause, resume, clear and set goals only when the user explicitly requests it.
        """
    }
}

public enum WorkspaceGoalMutation: Codable, Equatable, Sendable {
    case set(objective: String, tokenBudget: Int64?, turnBudget: Int?)
    case edit(id: String, objective: String, tokenBudget: Int64?, turnBudget: Int?)
    case pause(id: String), resume(id: String), clear(id: String)
    case complete(id: String, evidence: String), block(id: String, evidence: String)
    case checkpoint(id: String, evidence: String)
}

/// App-owned slash commands never reach a provider's native goal loop.
public enum WorkspaceGoalCommand: Equatable, Sendable {
    case request, show, pause, resume, clear, set(String)
    /// Translate app-owned intent before any provider parses native slash commands.
    public var agentPrompt: String {
        switch self {
        case .set(let objective):
            "Set a Woven Matter goal using the goal tools, then work toward this objective:\n\(objective)"
        case .request: "Establish a Woven Matter goal from our current conversation using the goal tools, then work toward it. If the intended objective is unclear, ask me to clarify before setting the goal."
        case .show: "Read the current Woven Matter goal using the goal tools and report its status."
        case .pause: "Pause the current Woven Matter goal using the goal tools."
        case .resume: "Resume the current Woven Matter goal using the goal tools and continue working toward it."
        case .clear: "Delete the current Woven Matter goal using the goal tools."
        }
    }

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.first?.lowercased() == "/goal" else { return nil }
        let value = parts.dropFirst().first.map(String.init) ?? ""
        switch value.lowercased() {
        case "": self = .request
        case "show": self = .show
        case "pause": self = .pause
        case "resume": self = .resume
        case "clear": self = .clear
        default: self = .set(value)
        }
    }
}
