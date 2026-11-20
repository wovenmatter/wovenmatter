import Foundation

// Woven tool settings, per-session tool choices, session relationships,
// cross-session deliveries and the Executor app, as the UI shows them.

enum WorkspaceCalendarAccess: String, CaseIterable, Hashable, Sendable {
    case readOnly, full
    var title: String { self == .full ? "Full access" : "Read only" }
}

/// The synced tool settings every new session starts from.
struct WorkspaceToolSettings: Hashable, Sendable {
    var enabledByDefault: Set<WorkspaceToolGroup> = Set(WorkspaceToolGroup.allCases.filter { $0 != .executor && $0 != .computer })
    var calendarAccess: WorkspaceCalendarAccess = .full
    var maximumManagedSessions = 4
    var maximumRunningSessions = 16
    var executorSetup: ExecutorSetupState?
    var executor: ExecutorConfiguration?
}

/// The Woven tools one session may use.
struct WorkspaceSessionTools: Hashable, Sendable {
    /// Goals and visual replies are always enabled.
    var enabled: Set<WorkspaceToolGroup> {
        didSet { if !enabled.isSuperset(of: [.goals, .html]) { enabled.formUnion([.goals, .html]) } }
    }
    var executorProfiles: Set<String>?

    init(enabled: Set<WorkspaceToolGroup> = Set(WorkspaceToolGroup.allCases.filter { $0 != .executor && $0 != .computer }),
         executorProfiles: Set<String>? = nil) {
        self.enabled = enabled.union([.goals, .html])
        self.executorProfiles = executorProfiles
    }
}

/// Who created a session and which session coordinates it.
struct WorkspaceSessionRelationship: Hashable, Sendable {
    var sessionID: String
    var createdBy: String?
    var coordinatorID: String?
    var purpose: String?
    var notificationsEnabled: Bool
}

/// A session asking to read and coordinate another while conversation history is off.
struct SessionAccessRequest: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let targetID: String
    let sourceTitle: String
    let targetTitle: String
}

extension WorkspaceSessionTimer {
    init(id: String = UUID().uuidString.lowercased(), sessionID: String, instruction: String,
         nextFireAt: Date, intervalSeconds: TimeInterval? = nil, isPaused: Bool = false) {
        self.init(id: id, sessionID: sessionID, botID: nil, machineID: nil, instruction: instruction,
                  nextFireAt: nextFireAt, intervalSeconds: intervalSeconds, isPaused: isPaused)
    }

    func validate() throws {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instruction.utf8.count <= 65_536, nextFireAt.timeIntervalSince1970.isFinite,
              intervalSeconds.map({ $0.isFinite && $0 >= 1 && $0 <= 365 * 86_400 }) ?? true else {
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

// MARK: - Deliveries between sessions

enum WorkspaceSessionDeliveryKind: String, Hashable, Sendable {
    case message, created, timer, notification, calendar, goal
}

enum WorkspaceSessionDeliveryStatus: Hashable, Sendable {
    case sending, queued, accepted, cancelled, failed
}

/// A message one session sent another, shown in both transcripts.
struct WorkspaceSessionDelivery: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let targetID: String
    let text: String
    let kind: WorkspaceSessionDeliveryKind
    let status: WorkspaceSessionDeliveryStatus
    /// The message it became in the target session, once delivered.
    let messageID: String?
    let sourceTitle: String
    let sourceHarness: String
    let targetTitle: String
    let targetHarness: String
    let targetModel: String?
    let purpose: String?
    let createdAt: Date
    /// A native command the target runtime ran instead of a message.
    let nativeCommand: String?
}

enum WorkspaceConversationTimelineItem: Identifiable, Sendable {
    case message(WorkspaceMessageRecord)
    case receipt(WorkspaceSessionDelivery)
    case incomingCommand(WorkspaceSessionDelivery)

    var id: String {
        switch self {
        case .message(let value): value.id
        case .receipt(let value): "tool-receipt:" + value.id
        case .incomingCommand(let value): "tool-command:" + value.id
        }
    }

    /// Messages in their order, with this session's outgoing deliveries woven in by time.
    static func weave(messages: [WorkspaceMessageRecord], receipts: [WorkspaceSessionDelivery], sessionID: String) -> [Self] {
        let outgoing = receipts.filter {
            ($0.sourceID == sessionID && [.message, .created].contains($0.kind))
                || ($0.targetID == sessionID && $0.nativeCommand != nil)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        func action(_ receipt: WorkspaceSessionDelivery) -> Self {
            receipt.targetID == sessionID && receipt.nativeCommand != nil ? .incomingCommand(receipt) : .receipt(receipt)
        }
        var index = 0
        var items: [Self] = []
        for message in messages {
            while index < outgoing.count, outgoing[index].createdAt < message.createdAt {
                items.append(action(outgoing[index]))
                index += 1
            }
            items.append(.message(message))
        }
        items += outgoing.dropFirst(index).map(action)
        return items
    }
}

// MARK: - Executor

/// Where Executor runs and which of its apps new sessions may use.
struct ExecutorConfiguration: Hashable, Sendable {
    enum Location: String, CaseIterable, Hashable, Sendable { case local, remote }
    var id: String = UUID().uuidString.lowercased()
    var location: Location = .local
    /// The Linux machine that runs it, for `.remote`.
    var machineID: String?
    /// That machine's name, as shown.
    var host: String = ""
    var apps: [ExecutorAppTarget] = []
    var defaultProfiles: Set<String> = []
}

struct ExecutorSetupState: Hashable, Sendable {
    var configuration: ExecutorConfiguration
    var running: Bool
    var error: String?
}

struct ExecutorAppTarget: Identifiable, Hashable, Sendable {
    var id: String
    var app: String
    var name: String
    var account: String?
    var targetName: String
}

enum ExecutorControl: Hashable, Sendable {
    case setup(ExecutorConfiguration)
    case refresh
    case dashboard
    case selection(session: String, profiles: Set<String>)
}
