import Foundation
import Observation

public struct IdleSleepProtectionSnapshot: Codable, Equatable, Sendable {
    public var policy: WorkPowerPolicy
    public var isProtecting: Bool

    public init(policy: WorkPowerPolicy = .displaySleepDefault, isProtecting: Bool = false) {
        self.policy = policy
        self.isProtecting = isProtecting
    }
}

/// Dispatch leases cover preparation and transport awaits; session state covers
/// providers that acknowledge a send before the run finishes. The selected power
/// policies control idle sleep independently of the lifetime of the work itself.
@Observable @MainActor
public final class ActiveWorkSleepPrevention {
    static let options: ProcessInfo.ActivityOptions = .userInitiated
    static let reason = "Woven Matter is running agent work"
    static let externalKey = "wovenmatter.display-sleep.external-power"
    static let batteryKey = "wovenmatter.display-sleep.battery-power"
    public private(set) var snapshot: IdleSleepProtectionSnapshot

    @ObservationIgnored private let ownsExecution: Bool
    @ObservationIgnored private let beginActivity: (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol
    @ObservationIgnored private let endActivity: (any NSObjectProtocol) -> Void
    @ObservationIgnored private let currentPowerSource: () -> WorkPowerSource
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let onWorkChanged: (Bool) -> Void
    @ObservationIgnored private var closedLidPolicy: WorkPowerPolicy
    @ObservationIgnored private var powerObservation: WorkPowerSourceObservation?
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var activityOptions: ProcessInfo.ActivityOptions?
    @ObservationIgnored private var dispatches: Set<UUID> = []
    @ObservationIgnored private var runningConversationIDs: Set<String> = []
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var wasWorking = false

    public convenience init(ownsExecution: Bool, defaults: UserDefaults = .standard,
                            closedLidPolicy: WorkPowerPolicy = .init(),
                            onWorkChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(ownsExecution: ownsExecution, policy: Self.savedPolicy(defaults: defaults),
                  closedLidPolicy: closedLidPolicy, currentPowerSource: ClosedLidSystemPower.source,
                  defaults: defaults,
                  beginActivity: { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
                  endActivity: { ProcessInfo.processInfo.endActivity($0) },
                  onWorkChanged: onWorkChanged)
        if ownsExecution {
            powerObservation = WorkPowerSourceObservation { [weak self] in self?.powerSourceChanged() }
        }
    }

    init(ownsExecution: Bool, policy: WorkPowerPolicy = .displaySleepDefault,
         closedLidPolicy: WorkPowerPolicy = .init(),
         currentPowerSource: @escaping () -> WorkPowerSource = { .external },
         defaults: UserDefaults? = nil,
         beginActivity: @escaping (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol,
         endActivity: @escaping (any NSObjectProtocol) -> Void,
         onWorkChanged: @escaping (Bool) -> Void = { _ in }) {
        self.ownsExecution = ownsExecution
        self.snapshot = .init(policy: policy)
        self.closedLidPolicy = closedLidPolicy
        self.currentPowerSource = currentPowerSource
        self.defaults = defaults
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        self.onWorkChanged = onWorkChanged
    }

    static func savedPolicy(defaults: UserDefaults) -> WorkPowerPolicy {
        .init(externalPower: defaults.object(forKey: externalKey) == nil ? true : defaults.bool(forKey: externalKey),
              batteryPower: defaults.object(forKey: batteryKey) == nil ? true : defaults.bool(forKey: batteryKey))
    }

    public func setPolicy(_ policy: WorkPowerPolicy) {
        guard ownsExecution, !stopped else { return }
        defaults?.set(policy.externalPower, forKey: Self.externalKey)
        defaults?.set(policy.batteryPower, forKey: Self.batteryKey)
        snapshot.policy = policy
        synchronize()
    }

    /// The higher level includes ordinary idle-sleep protection, even if its
    /// separate normal-level switch is off or helper approval is still pending.
    public func setClosedLidPolicy(_ policy: WorkPowerPolicy) {
        guard ownsExecution, !stopped else { return }
        closedLidPolicy = policy
        synchronize()
    }

    public func applyBackendSnapshot(_ value: IdleSleepProtectionSnapshot) {
        guard !ownsExecution else { return }
        snapshot = value
    }

    func powerSourceChanged() { synchronize() }

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
        powerObservation = nil
        dispatches.removeAll()
        runningConversationIDs.removeAll()
        synchronize()
    }

    private func synchronize() {
        let isWorking = ownsExecution && !stopped
            && (!dispatches.isEmpty || !runningConversationIDs.isEmpty)
        let source = currentPowerSource()
        let preventsSleep = isWorking && (snapshot.policy.permits(source) || closedLidPolicy.permits(source))
        if isWorking {
            // Retain App Nap protection while work is active, but allow system
            // sleep when neither level is selected for this power source.
            let options: ProcessInfo.ActivityOptions = preventsSleep ? Self.options : .userInitiatedAllowingIdleSystemSleep
            if activity == nil || activityOptions != options {
                let previous = activity
                activity = beginActivity(options, Self.reason)
                activityOptions = options
                if let previous { endActivity(previous) }
            }
        } else if let activity {
            endActivity(activity)
            self.activity = nil
            activityOptions = nil
        }
        if snapshot.isProtecting != preventsSleep { snapshot.isProtecting = preventsSleep }
        if wasWorking != isWorking {
            wasWorking = isWorking
            onWorkChanged(isWorking)
        }
    }

    // Foundation also ends the activity if its token is deallocated, so releasing
    // this owner cannot leak an assertion even without an explicit stop().
}
