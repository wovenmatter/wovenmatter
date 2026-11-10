import Foundation
import Testing
import WovenMatterCompanion
@testable import WovenMatterAppFacade

/// Settings → Permissions & Access, driven by fake macOS probes: no real TCC
/// prompts, System Settings panes or Keychain items are touched.
@MainActor
struct MacAccessSetupModelTests {
    typealias Item = MacAccessSetupModel.Item

    /// Stands in for macOS: what each permission reads as, and what asking does.
    @MainActor final class FakeMac {
        var states: [Item: CompanionMacAccessStatus.State] = [:]
        var turnedOff: Set<Item> = []
        var requests: [Item] = []
        var grantsOnRequest: Set<Item> = []

        func probe(_: UserDefaults) -> MacAccessSetupModel.Probe { .init(states: states, turnedOff: turnedOff) }
        func request(_ item: Item) async {
            requests.append(item)
            if grantsOnRequest.contains(item) { states[item] = .ready }
        }
    }

    private func makeModel(_ mac: FakeMac) -> MacAccessSetupModel {
        let defaults = UserDefaults(suiteName: "MacAccessSetupModelTests-\(UUID().uuidString)")!
        let model = MacAccessSetupModel(defaults: defaults, probe: { mac.probe($0) },
                                        automationProbe: { _ in nil }, request: { await mac.request($0) },
                                        pollInterval: .milliseconds(5))
        model.keychainRequest = { mac.requests.append(.keychain) }
        return model
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func statusesUseOneVocabulary() {
        #expect(MacAccessSetupModel.access(state: .ready, turnedOff: true, awaitingReopen: true) == .allowed)
        #expect(MacAccessSetupModel.access(state: .needsAttention, turnedOff: false, awaitingReopen: false) == .notAllowed)
        #expect(MacAccessSetupModel.access(state: .unknown, turnedOff: false, awaitingReopen: false) == .notAllowed)
        #expect(MacAccessSetupModel.access(state: .needsAttention, turnedOff: true, awaitingReopen: false) == .turnedOff)
        #expect(MacAccessSetupModel.access(state: .needsAttention, turnedOff: true, awaitingReopen: true) == .needsReopen)
    }

    @Test func everyPermissionAppearsInExactlyOneGroupAndInSetUpAll() {
        let grouped = MacPermissionGroup.allCases.flatMap(\.items)
        #expect(grouped.count == Item.allCases.count && Set(grouped) == Set(Item.allCases))
        #expect(Set(MacAccessSetupModel.setupOrder) == Set(Item.allCases))
        #expect(MacAccessSetupModel.setupOrder.last == .screenRecording)
        #expect(MacPermissionGroup.dictation.items == [.microphone])
    }

    @Test func summaryCountsWhatIsLeftToAllow() {
        let mac = FakeMac()
        mac.states = Dictionary(uniqueKeysWithValues: Item.allCases.map { ($0, .ready) })
        mac.states[.microphone] = .unknown
        mac.states[.automation] = .needsAttention
        let model = makeModel(mac)
        #expect(model.summary == "2 to allow")
        #expect(model.remaining == [.automation, .microphone])
        mac.states[.microphone] = .ready; mac.states[.automation] = .ready
        model.refresh(keychainReady: true)
        #expect(model.summary == "All allowed" && model.remaining.isEmpty)
    }

    @Test func setUpAllAsksInOrderSkipsAllowedItemsAndWaitsForEachGrant() async {
        let mac = FakeMac()
        mac.states = [.keychain: .ready, .fullDiskAccess: .needsAttention, .accessibility: .ready,
                      .screenRecording: .needsAttention, .automation: .needsAttention, .microphone: .ready]
        mac.grantsOnRequest = [.automation]
        let model = makeModel(mac)
        model.startSetUpAll()
        #expect(model.run?.steps == [.fullDiskAccess, .automation, .screenRecording])
        // Full Disk Access opens System Settings and waits until it is switched on there.
        await waitUntil { mac.requests == [.fullDiskAccess] }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.run?.current == .fullDiskAccess && mac.requests == [.fullDiskAccess])
        mac.states[.fullDiskAccess] = .ready
        // Automation is granted by its prompt; Screen Recording is next.
        await waitUntil { model.run?.current == .screenRecording }
        #expect(mac.requests == [.fullDiskAccess, .automation, .screenRecording])
        mac.states[.screenRecording] = .ready
        await waitUntil { model.run == nil }
        #expect(model.run == nil && model.remaining.isEmpty)
    }

    @Test func setUpAllCanSkipAStepAndBeStopped() async {
        let mac = FakeMac()
        mac.states = [.keychain: .needsAttention, .fullDiskAccess: .needsAttention, .accessibility: .ready,
                      .screenRecording: .ready, .automation: .ready, .microphone: .ready]
        let model = makeModel(mac)
        model.startSetUpAll()
        await waitUntil { mac.requests == [.keychain] }
        #expect(model.run?.current == .keychain)
        model.skipStep()
        await waitUntil { model.run?.current == .fullDiskAccess }
        #expect(mac.requests == [.keychain, .fullDiskAccess])
        model.stopSetUpAll()
        #expect(model.run == nil)
        #expect(model.remaining == [.keychain, .fullDiskAccess])
    }

    @Test func deniedMicrophoneReadsAsSwitchedOff() {
        let mac = FakeMac()
        mac.states = [.microphone: .needsAttention]
        mac.turnedOff = [.microphone]
        let model = makeModel(mac)
        #expect(model.access(.microphone) == .turnedOff)
        #expect(Item.microphone.actionTitle(.turnedOff) == "Open System Settings")
        #expect(Item.microphone.actionTitle(.notAllowed) == "Allow")
        #expect(Item.fullDiskAccess.actionTitle(.notAllowed) == "Open System Settings")
        mac.turnedOff = []; mac.states[.microphone] = .ready
        model.refresh(keychainReady: nil)
        #expect(model.access(.microphone) == .allowed)
    }

    @Test func screenRecordingAskedThisLaunchOffersReopenAfterReturningToTheApp() async {
        let mac = FakeMac()
        mac.states = Dictionary(uniqueKeysWithValues: Item.allCases.map { ($0, .ready) })
        mac.states[.screenRecording] = .needsAttention
        let model = makeModel(mac)
        model.appDidBecomeActive()
        #expect(model.access(.screenRecording) == .notAllowed)
        await model.setUp(.screenRecording)
        #expect(model.requested == .screenRecording && model.access(.screenRecording) == .notAllowed)
        model.appDidBecomeActive()
        #expect(model.access(.screenRecording) == .needsReopen && model.awaitingReopen == [.screenRecording])
        // Set up all has nothing it can ask for; only reopening finishes it.
        model.startSetUpAll()
        #expect(model.run == nil)
        mac.states[.screenRecording] = .ready
        model.refresh(keychainReady: nil)
        #expect(model.access(.screenRecording) == .allowed && model.requested == nil)
    }

    @Test func keychainHintNamesAlwaysAllowOnlyForItsOwnStep() {
        let hint = Item.keychain.stepHint(.notAllowed, appName: "Woven Matter")
        #expect(hint.contains("Always Allow"))
        #expect(!Item.fullDiskAccess.stepHint(.notAllowed, appName: "Woven Matter").contains("Always Allow"))
        #expect(Item.screenRecording.stepHint(.needsReopen, appName: "Woven Matter Dev").contains("reopen"))
    }
}
