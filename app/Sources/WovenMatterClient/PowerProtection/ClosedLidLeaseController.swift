import Foundation

/// Used only by the privileged helper, on its serial queue. Tests supply an
/// in-memory power system: constructing this type never changes macOS settings.
final class ClosedLidLeaseController {
    static let leaseLifetime: TimeInterval = 15
    private struct Lease {
        var policy: ClosedLidPolicy
        var expires: TimeInterval
    }
    private var leases: [UUID: Lease] = [:]
    private let readDisabled: () throws -> Bool
    private let writeDisabled: (Bool) throws -> Void
    private let readJournal: () throws -> Bool
    private let writeJournal: (Bool) throws -> Void
    private var recovered = false
    private(set) var isProtecting = false
    private(set) var errorMessage: String?

    init(readDisabled: @escaping () throws -> Bool, writeDisabled: @escaping (Bool) throws -> Void,
         readJournal: @escaping () throws -> Bool, writeJournal: @escaping (Bool) throws -> Void) {
        self.readDisabled = readDisabled
        self.writeDisabled = writeDisabled
        self.readJournal = readJournal
        self.writeJournal = writeJournal
    }

    func renew(_ id: UUID, policy: ClosedLidPolicy, now: TimeInterval, source: WorkPowerSource) {
        if policy.isEnabled {
            leases[id] = Lease(policy: policy, expires: now + Self.leaseLifetime)
        } else {
            leases[id] = nil
        }
        tick(now: now, source: source)
    }

    func remove(_ id: UUID, now: TimeInterval, source: WorkPowerSource) {
        leases[id] = nil
        tick(now: now, source: source)
    }

    func tick(now: TimeInterval, source: WorkPowerSource) {
        leases = leases.filter { $0.value.expires > now }
        do {
            // A restarted daemon must restore its previous transaction first.
            // The journal remains until restoration succeeds, including retries.
            if !recovered {
                if try readJournal() {
                    try writeDisabled(false)
                    try writeJournal(false)
                }
                recovered = true
            }
            let requested = leases.values.contains { $0.policy.permits(source) }
            if requested {
                if try !readDisabled() {
                    // Claim only a false -> true transition. Never undo another
                    // utility's pre-existing SleepDisabled setting.
                    try writeJournal(true)
                    try writeDisabled(true)
                }
                isProtecting = true
            } else {
                if try readJournal() {
                    try writeDisabled(false)
                    try writeJournal(false)
                }
                isProtecting = false
            }
            errorMessage = nil
        } catch {
            isProtecting = false
            errorMessage = "Closed-lid protection could not update macOS sleep settings. \(error.localizedDescription)"
        }
    }
}
