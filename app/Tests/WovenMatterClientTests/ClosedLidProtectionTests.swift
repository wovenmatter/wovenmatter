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

    @Test func pmsetReadFailsClosedForPartialOrUnknownOutput() throws {
        #expect(throws: (any Error).self) { try ClosedLidSystemPower.parseDisabled("System-wide power settings:\n") }
        let prefix = "System-wide power settings:\n"
        let suffix = "Currently in use:\n sleep 1\n"
        #expect(try !ClosedLidSystemPower.parseDisabled(prefix + suffix))
        #expect(try ClosedLidSystemPower.parseDisabled(prefix + " SleepDisabled 1\n" + suffix))
        #expect(try !ClosedLidSystemPower.parseDisabled(prefix + " SleepDisabled 0\n" + suffix))
        #expect(throws: (any Error).self) { try ClosedLidSystemPower.parseDisabled(prefix + " SleepDisabled unexpected\n" + suffix) }
    }

    @Test func signingRequirementRejectsUntrustedInput() throws {
        let requirement = try ClosedLidHelperIdentity.requirement(team: "12345ABCDE", identifiers: ["wovenmatter.desktop"])
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("certificate leaf[subject.OU]"))
        #expect(throws: (any Error).self) { try ClosedLidHelperIdentity.requirement(team: "", identifiers: ["wovenmatter.desktop"]) }
        #expect(throws: (any Error).self) { try ClosedLidHelperIdentity.requirement(team: "12345ABCDE", identifiers: ["x\" or true"]) }
    }


    @Test func externalSettingsPowerTransitionsReleaseAndExpiryPreserveSleepOwnership() {
        let power = FakePower(), first = UUID(), second = UUID()
        let controller = power.controller()
        power.disabled = true
        controller.renew(first, policy: .init(batteryPower: true), now: -2, source: .battery)
        controller.remove(first, now: -1, source: .battery)
        #expect(power.disabled && power.operations.isEmpty)
        power.disabled = false
        controller.renew(first, policy: .init(externalPower: true), now: 0, source: .external)
        #expect(power.operations == ["journal:true", "sleep:true"])
        controller.tick(now: 1, source: .battery)
        #expect(!power.disabled && !power.journal)
        controller.renew(second, policy: .init(batteryPower: true), now: 2, source: .battery)
        #expect(power.disabled)
        controller.remove(first, now: 3, source: .battery)
        #expect(power.disabled)
        controller.remove(second, now: 4, source: .battery)
        #expect(!power.disabled && !power.journal)
        controller.renew(first, policy: .init(externalPower: true), now: 5, source: .external)
        controller.renew(first, policy: .init(externalPower: true), now: 15, source: .external)
        controller.tick(now: 29, source: .external)
        #expect(power.disabled)
        controller.tick(now: 30, source: .external)
        #expect(!power.disabled && !power.journal)
    }

    @Test func failedRecoveryIsRetriedAndCannotBeMaskedByNewWork() {
        let power = FakePower(), controller = power.controller()
        power.journal = true
        power.disabled = true
        power.failWrite = true
        controller.renew(UUID(), policy: .init(externalPower: true), now: 0, source: .external)
        #expect(!controller.isProtecting && controller.errorMessage != nil && power.journal)
        power.failWrite = false
        controller.tick(now: 16, source: .external)
        #expect(!power.disabled && !power.journal && controller.errorMessage == nil)
    }


    @Test func failedJournalCannotDisableSleepAndFailedMutationRetainsRecovery() {
        let power = FakePower(), controller = power.controller(), id = UUID()
        power.failJournal = true
        controller.renew(id, policy: .init(externalPower: true), now: 0, source: .external)
        #expect(!power.disabled && !power.operations.contains("sleep:true"))
        power.failJournal = false
        power.failWrite = true
        controller.tick(now: 1, source: .external)
        #expect(power.journal && !controller.isProtecting)
        power.failWrite = false
        controller.remove(id, now: 2, source: .external)
        #expect(!power.journal && !power.disabled)
    }

    @Test func uncertainEnableRestoresBeforeASecondAttempt() {
        var disabled = false, journal = false, failVerification = true
        var writes: [Bool] = []
        let controller = ClosedLidLeaseController(readDisabled: { disabled }, writeDisabled: {
            disabled = $0
            writes.append($0)
            if $0 && failVerification { throw CocoaError(.fileReadUnknown) }
        }, readJournal: { journal }, writeJournal: { journal = $0 })
        let id = UUID()
        controller.renew(id, policy: .init(externalPower: true), now: 0, source: .external)
        #expect(disabled && journal && !controller.isProtecting)
        failVerification = false
        controller.renew(id, policy: .init(externalPower: true), now: 1, source: .external)
        #expect(writes == [true, false, true])
        #expect(controller.isProtecting && journal)
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
    @Test func frontendNeverLeasesOrOverwritesOwnerPolicy() {
        let fixture = DefaultsFixture(), connection = FakeLeaseConnection()
        defer { withExtendedLifetime(fixture) {} }
        let protection = ClosedLidWorkProtection(ownsExecution: false, defaults: fixture.defaults,
            helperStatus: { .ready }, connect: { connection })
        protection.applyBackendSnapshot(.init(policy: .init(externalPower: true), isProtecting: true))
        protection.setWorking(true)
        protection.setPolicy(.init(batteryPower: true))
        protection.beat()
        #expect(connection.policies.isEmpty)
        #expect(protection.snapshot.policy == .init(externalPower: true))
    }

    @Test func approvalAndLateCallbacksCannotReactivateStoppedOwner() {
        var status = ClosedLidHelperSetup.approvalRequired
        let fixture = DefaultsFixture(), connection = FakeLeaseConnection()
        defer { withExtendedLifetime(fixture) {} }
        let protection = ClosedLidWorkProtection(ownsExecution: true, defaults: fixture.defaults,
            helperStatus: { status }, connect: { connection })
        protection.setPolicy(.init(externalPower: true))
        protection.setWorking(true)
        #expect(connection.policies.isEmpty && protection.snapshot.message != nil)
        status = .ready
        protection.beat()
        #expect(connection.policies.count == 1)
        protection.stop()
        connection.reply?(true, nil)
        protection.setWorking(true)
        protection.beat()
        #expect(connection.isClosed && !protection.snapshot.isProtecting)
        #expect(connection.policies.count == 1)
    }



    private final class DefaultsFixture {
        let name = "wovenmatter.closed-lid.tests." + UUID().uuidString
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

}
