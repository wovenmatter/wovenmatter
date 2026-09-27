import Foundation

/// Keeps the execution owner awake for active runs while allowing display sleep.
/// Dispatch leases cover preparation and transport awaits; session state covers
/// providers that acknowledge a send before the run finishes.
@MainActor
public final class ActiveWorkSleepPrevention {
    static let options: ProcessInfo.ActivityOptions = .userInitiated
    static let reason = "Woven Matter is running agent work"

    private let ownsExecution: Bool
    private let beginActivity: (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol
    private let endActivity: (any NSObjectProtocol) -> Void
    private var activity: (any NSObjectProtocol)?
    private var dispatches: Set<UUID> = []
    private var runningConversationIDs: Set<String> = []
    private var stopped = false
    private let onWorkChanged: (Bool) -> Void
    private var wasWorking = false

    public convenience init(ownsExecution: Bool, onWorkChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(ownsExecution: ownsExecution,
                  beginActivity: { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
                  endActivity: { ProcessInfo.processInfo.endActivity($0) },
                  onWorkChanged: onWorkChanged)
    }

    init(ownsExecution: Bool,
         beginActivity: @escaping (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol,
         endActivity: @escaping (any NSObjectProtocol) -> Void,
         onWorkChanged: @escaping (Bool) -> Void = { _ in }) {
        self.ownsExecution = ownsExecution
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        self.onWorkChanged = onWorkChanged
    }

    public func beginDispatch() -> UUID {
        let id = UUID()
        guard ownsExecution, !stopped else { return id }
        dispatches.insert(id)
        synchronize()
        return id
    }

    public func endDispatch(_ id: UUID) {
        dispatches.remove(id)
        synchronize()
    }

    public func setRunningConversationIDs(_ ids: Set<String>) {
        guard ownsExecution, !stopped else { return }
        runningConversationIDs = ids
        synchronize()
    }

    /// Terminal shutdown: late transport callbacks cannot reacquire an assertion.
    public func stop() {
        stopped = true
        dispatches.removeAll()
        runningConversationIDs.removeAll()
        synchronize()
    }

    private func synchronize() {
        let needsActivity = ownsExecution && !stopped
            && (!dispatches.isEmpty || !runningConversationIDs.isEmpty)
        if wasWorking != needsActivity {
            wasWorking = needsActivity
            onWorkChanged(needsActivity)
        }
        if needsActivity {
            if activity == nil { activity = beginActivity(Self.options, Self.reason) }
        } else if let activity {
            endActivity(activity)
            self.activity = nil
        }
    }

    // Foundation also ends the activity if its token is deallocated, so releasing
    // this owner cannot leak an assertion even without an explicit stop().
}
