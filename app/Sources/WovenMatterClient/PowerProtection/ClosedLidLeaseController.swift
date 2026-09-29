import Foundation

/// Used only by the privileged helper, on its serial queue. Tests supply an
/// in-memory power system: constructing this type never changes macOS settings.
final class ClosedLidLeaseController {
    static let leaseLifetime: TimeInterval = 15
    private struct Lease {
        var policy: WorkPowerPolicy
        var expires: TimeInterval
    }
    private var leases: [UUID: Lease] = [:]
    private let readDisabled: () throws -> Bool
    private let writeDisabled: (Bool) throws -> Void
    private let readJournal: () throws -> Bool
    private let writeJournal: (Bool) throws -> Void
    private var recoveryPending = true
    private var stopped = false
    private(set) var isProtecting = false
    private(set) var errorMessage: String?

    init(readDisabled: @escaping () throws -> Bool, writeDisabled: @escaping (Bool) throws -> Void,
         readJournal: @escaping () throws -> Bool, writeJournal: @escaping (Bool) throws -> Void) {
        self.readDisabled = readDisabled
        self.writeDisabled = writeDisabled
        self.readJournal = readJournal
        self.writeJournal = writeJournal
    }

    /// Receipt time belongs to XPC intake, not the moment a queued request is
    /// processed. A delayed request must never acquire a fresh lease.
    func recordRenewal(_ id: UUID, policy: WorkPowerPolicy, receivedAt: TimeInterval) {
        guard !stopped else { return }
        if policy.isEnabled {
            leases[id] = Lease(policy: policy, expires: receivedAt + Self.leaseLifetime)
        } else {
            leases[id] = nil
        }
    }

    func recordDisconnect(_ id: UUID) { leases[id] = nil }

    func renew(_ id: UUID, policy: WorkPowerPolicy, now: TimeInterval, source: WorkPowerSource) {
        recordRenewal(id, policy: policy, receivedAt: now)
        tick(now: now, source: source)
    }

    func remove(_ id: UUID, now: TimeInterval, source: WorkPowerSource) {
        recordDisconnect(id)
        tick(now: now, source: source)
    }

    /// Termination is irreversible. New or already queued requests cannot
    /// reacquire the override while launchd is stopping this helper.
    func stop(now: TimeInterval) {
        stopped = true
        leases.removeAll()
        recoveryPending = true
        tick(now: now, source: .unknown)
    }

    private func restore() throws {
        // Keep this set through both the system write and durable journal clear.
        // A new lease must not bypass a previously failed restoration.
        recoveryPending = true
        if try readJournal() {
            try writeDisabled(false)
            try writeJournal(false)
        }
        recoveryPending = false
    }

    func tick(now: TimeInterval, source: WorkPowerSource) {
        leases = leases.filter { $0.value.expires > now }
        do {
            // Restart, failed restoration, and uncertain enable operations all
            // restore the journal before considering any newly requested work.
            if recoveryPending { try restore() }
            let requested = !stopped && leases.values.contains { $0.policy.permits(source) }
            if requested {
                if try !readDisabled() {
                    // Claim only a false -> true transition. Never undo another
                    // utility's pre-existing SleepDisabled setting.
                    recoveryPending = true
                    try writeJournal(true)
                    try writeDisabled(true)
                    recoveryPending = false
                }
                isProtecting = true
            } else {
                try restore()
                isProtecting = false
            }
            errorMessage = nil
        } catch {
            isProtecting = false
            errorMessage = "Closed-lid protection could not update macOS sleep settings. \(error.localizedDescription)"
        }
    }
}
