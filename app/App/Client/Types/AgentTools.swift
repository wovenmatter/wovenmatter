import Foundation
import WovenProtocol

// Woven tool settings, per-session tool choices and session timers, as the UI shows them.

/// The synced tool settings every new session starts from.
struct WorkspaceToolSettings: Hashable, Sendable {
    var enabledByDefault: Set<WorkspaceToolGroup> = ToolGroup.standard
}

/// The Woven tools one session may use.
struct WorkspaceSessionTools: Hashable, Sendable {
    var enabled: Set<WorkspaceToolGroup>
}

/// A session's Woven timer or wake-up: an instruction that reaches the session when it fires.
/// It is an entry of the scheduler on the session's machine.
struct WorkspaceSessionTimer: Identifiable, Equatable, Sendable {
    let id: String
    var sessionID: String
    /// The machine whose scheduler runs it: the session's.
    var machineID: String
    var instruction: String
    var nextFireAt: Date
    var intervalSeconds: TimeInterval?
    var isPaused: Bool
}

extension WorkspaceSessionTimer {
    init(sessionID: String, machineID: String, instruction: String, nextFireAt: Date) {
        self.init(id: "", sessionID: sessionID, machineID: machineID, instruction: instruction,
                  nextFireAt: nextFireAt, intervalSeconds: nil, isPaused: false)
    }

    /// Not saved yet.
    var isNew: Bool { id.isEmpty }

    func validate() throws {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instruction.utf8.count <= 65_536, nextFireAt.timeIntervalSince1970.isFinite,
              intervalSeconds.map({ $0.isFinite && $0 >= 60 && $0 <= 365 * 86_400 }) ?? true else {
            throw WorkspaceToolError.invalid("A timer needs an instruction, a valid date and a positive interval.")
        }
    }
}

/// The timer editor keeps the exact cadence while other fields change.
struct WorkspaceSessionTimerDraft: Sendable {
    private let original: WorkspaceSessionTimer
    var instruction: String
    var nextFireAt: Date
    var repeats: Bool
    var intervalSeconds: TimeInterval

    init(_ timer: WorkspaceSessionTimer) {
        original = timer
        instruction = timer.instruction
        nextFireAt = timer.nextFireAt
        repeats = timer.intervalSeconds != nil
        intervalSeconds = timer.intervalSeconds ?? 3_600
    }

    func timer() throws -> WorkspaceSessionTimer {
        var value = original
        value.instruction = instruction
        value.nextFireAt = nextFireAt
        value.intervalSeconds = repeats ? intervalSeconds : nil
        try value.validate()
        return value
    }
}

/// What sent a user message on the session's behalf.
enum WorkspaceSessionDeliveryKind: String, Hashable, Sendable {
    case message, timer, goal
}
