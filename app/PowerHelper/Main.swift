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
    private var terminationSources: [any DispatchSourceSignal] = []
    private var stopping = false
    private let logger = Logger(subsystem: ClosedLidHelperIdentity.service, category: "recovery")
    private var lastError: String?

    init(journal: ClosedLidRecoveryJournal, requirement: String) {
        self.requirement = requirement
        controller = ClosedLidLeaseController(readDisabled: ClosedLidSystemPower.readDisabled,
            writeDisabled: ClosedLidSystemPower.writeDisabled,
            readJournal: journal.read, writeJournal: journal.write)
    }

    func start() {
        // launchd normally stops a disabled/replaced helper with SIGTERM. Restore
        // before exiting; if macOS refuses, keep retrying until launchd ends us.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.stop() }
            terminationSources.append(source)
            source.resume()
        }
        queue.sync { tick() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in self?.tick() }
        watchdog = timer
        timer.resume()
    }

    private func stop() {
        stopping = true
        controller.stop(now: Self.now)
        reportRecovery()
    }

    private func tick() {
        controller.tick(now: Self.now, source: stopping ? .unknown : ClosedLidSystemPower.source())
        reportRecovery()
    }

    private func reportRecovery() {
        if controller.errorMessage != lastError {
            lastError = controller.errorMessage
            if let lastError { logger.error("\(lastError, privacy: .public)") }
        }
        if stopping && controller.errorMessage == nil { exit(0) }
    }

    static var now: TimeInterval {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        return Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1_000_000_000
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = UUID()
        let admitted = queue.sync {
            guard !stopping, sessions.count < 32 else { return false }
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
                self.controller.recordDisconnect(id)
            }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        return true
    }

    func renew(id: UUID, policy: WorkPowerPolicy, receivedAt: TimeInterval,
               reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async {
            guard !self.stopping, self.sessions.contains(id) else {
                reply(false, "The power helper connection closed.")
                return
            }
            self.controller.recordRenewal(id, policy: policy, receivedAt: receivedAt)
            // Only the watchdog performs potentially slow power-service I/O.
            // Renewal replies report its most recent verified protection state.
            reply(self.controller.isProtecting, self.controller.errorMessage)
        }
    }
}

final class PowerHelperSession: NSObject, ClosedLidPowerProtocol, @unchecked Sendable {
    private let id: UUID
    private let helper: PowerHelper
    private let lock = NSLock()
    private var pending = false
    init(id: UUID, helper: PowerHelper) { self.id = id; self.helper = helper }
    func renew(externalPower: Bool, batteryPower: Bool, reply: @escaping @Sendable (Bool, String?) -> Void) {
        let receivedAt = PowerHelper.now
        let admitted = lock.withLock {
            guard !pending else { return false }
            pending = true
            return true
        }
        guard admitted else { reply(false, "A power helper request is already pending."); return }
        helper.renew(id: id, policy: .init(externalPower: externalPower, batteryPower: batteryPower),
                     receivedAt: receivedAt) { [self] active, error in
            lock.withLock { pending = false }
            reply(active, error)
        }
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
