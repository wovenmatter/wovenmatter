import Darwin
import Foundation
import os

/// All mutable helper state is confined to this queue, including XPC disconnects
/// and the independent watchdog. No app heartbeat can postpone a failed restore.
final class PowerHelper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "wovenmatter.power-helper")
    private let controller: ClosedLidLeaseController
    private let requirement: String
    private var sessions: Set<UUID> = []
    private var watchdog: (any DispatchSourceTimer)?
    private let logger = Logger(subsystem: ClosedLidHelperIdentity.service, category: "recovery")
    private var lastError: String?

    init(journal: ClosedLidRecoveryJournal, requirement: String) {
        self.requirement = requirement
        controller = ClosedLidLeaseController(readDisabled: ClosedLidSystemPower.readDisabled,
            writeDisabled: ClosedLidSystemPower.writeDisabled,
            readJournal: journal.read, writeJournal: journal.write)
    }

    func start() {
        queue.sync { tick() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in self?.tick() }
        watchdog = timer
        timer.resume()
    }

    private func tick() {
        controller.tick(now: Self.now, source: ClosedLidSystemPower.source())
        if controller.errorMessage != lastError {
            lastError = controller.errorMessage
            if let lastError { logger.error("\(lastError, privacy: .public)") }
        }
    }

    static var now: TimeInterval {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        return Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1_000_000_000
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = UUID()
        let admitted = queue.sync {
            guard sessions.count < 32 else { return false }
            sessions.insert(id)
            return true
        }
        guard admitted else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: (any ClosedLidPowerProtocol).self)
        connection.exportedObject = PowerHelperSession(id: id, helper: self)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.sessions.remove(id)
                self.controller.remove(id, now: Self.now, source: ClosedLidSystemPower.source())
            }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        return true
    }

    func renew(id: UUID, policy: WorkPowerPolicy, reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async {
            guard self.sessions.contains(id) else { reply(false, "The power helper connection closed."); return }
            self.controller.renew(id, policy: policy, now: Self.now, source: ClosedLidSystemPower.source())
            reply(self.controller.isProtecting, self.controller.errorMessage)
        }
    }
}

final class PowerHelperSession: NSObject, ClosedLidPowerProtocol, @unchecked Sendable {
    private let id: UUID
    private let helper: PowerHelper
    init(id: UUID, helper: PowerHelper) { self.id = id; self.helper = helper }
    func renew(externalPower: Bool, batteryPower: Bool, reply: @escaping @Sendable (Bool, String?) -> Void) {
        helper.renew(id: id, policy: .init(externalPower: externalPower, batteryPower: batteryPower), reply: reply)
    }
}

@main struct PowerHelperMain {
    static func main() {
        do {
            // These identifiers are embedded at build time and covered by the
            // helper's signature. Ad-hoc/unsigned helpers fail closed.
            let team = try ClosedLidHelperIdentity.signingTeam()
            guard let identifiers = Bundle.main.object(forInfoDictionaryKey: "WMAllowedClients") as? [String] else {
                throw ClosedLidPowerError.unavailable("Missing power helper client identities.")
            }
            let requirement = try ClosedLidHelperIdentity.requirement(team: team, identifiers: identifiers)
            let helper = try PowerHelper(journal: ClosedLidRecoveryJournal(), requirement: requirement)
            helper.start()
            let listener = NSXPCListener(machServiceName: ClosedLidHelperIdentity.service)
            listener.setConnectionCodeSigningRequirement(requirement)
            listener.delegate = helper
            listener.resume()
            // launchd/XPC and the watchdog use dispatch sources. A Foundation
            // run loop with no attached sources may return immediately.
            withExtendedLifetime((helper, listener)) { dispatchMain() }
        } catch {
            Logger(subsystem: ClosedLidHelperIdentity.service, category: "startup")
                .fault("Power helper startup failed: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }
}
