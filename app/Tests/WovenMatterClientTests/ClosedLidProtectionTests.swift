import Darwin
import Foundation
import Testing
@testable import WovenMatterClient

private final class FakePower {
    var disabled = false
    var journal = false
    var failWrite = false
    var failJournal = false
    var operations: [String] = []
    func controller() -> ClosedLidLeaseController {
        ClosedLidLeaseController(readDisabled: { self.disabled }, writeDisabled: {
            self.operations.append("sleep:\($0)")
            if self.failWrite { throw CocoaError(.fileWriteUnknown) }
            self.disabled = $0
        }, readJournal: { self.journal }, writeJournal: {
            self.operations.append("journal:\($0)")
            if self.failJournal { throw CocoaError(.fileWriteUnknown) }
            self.journal = $0
        })
    }
}

struct ClosedLidProtectionTests {

    @Test func terminalStopRetriesRecoveryAndRejectsQueuedWork() {
        let power = FakePower(), controller = power.controller(), id = UUID()
        controller.renew(id, policy: .init(externalPower: true), now: 0, source: .external)
        power.failWrite = true
        controller.stop(now: 1)
        #expect(power.journal && controller.errorMessage != nil)
        controller.recordRenewal(id, policy: .init(externalPower: true), receivedAt: 2)
        power.failWrite = false
        controller.tick(now: 3, source: .external)
        #expect(!power.disabled && !power.journal && controller.errorMessage == nil)
        controller.renew(id, policy: .init(externalPower: true), now: 4, source: .external)
        #expect(!power.disabled && !controller.isProtecting)
    }


    @Test func recoveryJournalIsDurableExclusiveAndRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal: ClosedLidRecoveryJournal? = try .init(path: directory.path, owner: geteuid())
        #expect(throws: (any Error).self) { try ClosedLidRecoveryJournal(path: directory.path, owner: geteuid()) }
        try journal?.write(true)
        journal = nil
        journal = try .init(path: directory.path, owner: geteuid())
        #expect(try journal?.read() == true)
        try journal?.write(false)
        #expect(try journal?.read() == false)
        let marker = directory.appending(path: "restore-sleep")
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: directory.appending(path: "missing"))
        #expect(throws: (any Error).self) { try journal?.read() }
    }

}

@MainActor private final class FakeLeaseConnection: ClosedLidLeaseSending {
    var policies: [WorkPowerPolicy] = []
    var isClosed = false
    var reply: (@MainActor (Bool, String?) -> Void)?
    func renew(_ policy: WorkPowerPolicy, completion: @escaping @MainActor (Bool, String?) -> Void) {
        policies.append(policy)
        reply = completion
    }
    func close() { isClosed = true }
}

@MainActor struct ClosedLidWorkProtectionTests {
    @Test func helperSetupFailuresAreDistinctAndRecoverWithoutChangingPolicy() {
        let fixture = DefaultsFixture(), connection = FakeLeaseConnection()
        var setup = ClosedLidHelperSetup.unavailable
        let protection = ClosedLidWorkProtection(ownsExecution: true, defaults: fixture.defaults,
            helperStatus: { setup }, connect: { connection })
        defer { protection.stop(); withExtendedLifetime(fixture) {} }
        protection.setPolicy(.init(externalPower: true))
        protection.setWorking(true)
        #expect(protection.snapshot.message == "Closed-lid protection is unavailable in this build.")
        setup = .notRegistered
        protection.beat()
        #expect(protection.snapshot.message == "Set up closed-lid protection in General settings.")
        setup = .approvalRequired
        protection.beat()
        #expect(protection.snapshot.message?.contains("Approve") == true)
        #expect(connection.policies.isEmpty)
        #expect(!protection.snapshot.isProtecting)
        setup = .ready
        protection.beat()
        connection.reply?(true, nil)
        #expect(protection.snapshot.isProtecting && protection.snapshot.message == nil)
        #expect(connection.policies == [.init(externalPower: true)])
        setup = .unavailable
        protection.beat()
        #expect(connection.isClosed && !protection.snapshot.isProtecting)
        connection.reply?(true, nil)
        #expect(!protection.snapshot.isProtecting)
        protection.setPolicy(.init())
        #expect(protection.snapshot.policy == .init() && protection.snapshot.message == nil)
    }

    private final class DefaultsFixture {
        let name = "wovenmatter.closed-lid.tests." + UUID().uuidString
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

}
