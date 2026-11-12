import Foundation
import Testing
import WovenMatterShared
@testable import WovenMatterAppFacade

/// Settings → Permissions & Access, driven by fake macOS probes: no real TCC
/// prompts, System Settings panes or Keychain items are touched.
@MainActor
struct MacAccessSetupModelTests {
    typealias Item = MacAccessSetupModel.Item

    /// Stands in for macOS: what each permission reads as, and what asking does.
    @MainActor final class FakeMac {
        var states: [Item: MacAccessStatus.State] = [:]
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

    @Test func everyPermissionIsListedOnce() {
        #expect(MacAccessSetupModel.setupOrder.count == Item.allCases.count)
        #expect(Set(MacAccessSetupModel.setupOrder) == Set(Item.allCases))
    }

    @Test func summaryCountsWhatIsLeftToAllow() {
        let mac = FakeMac()
        mac.states = Dictionary(uniqueKeysWithValues: Item.allCases.map { ($0, .ready) })
        mac.states[.microphone] = .unknown
        mac.states[.automation] = .needsAttention
        let model = makeModel(mac)
        #expect(model.summary == "2 to allow")
        #expect(model.remaining == [.microphone, .automation])
        mac.states[.microphone] = .ready; mac.states[.automation] = .ready
        model.refresh(keychainReady: true)
        #expect(model.summary == "All allowed" && model.remaining.isEmpty)
    }

    @Test func allowAsksForOnlyThatPermission() async {
        let mac = FakeMac()
        mac.states = [.keychain: .ready, .fullDiskAccess: .needsAttention, .accessibility: .needsAttention,
                      .screenRecording: .ready, .automation: .needsAttention, .microphone: .ready]
        mac.grantsOnRequest = [.automation]
        let model = makeModel(mac)
        await model.setUp(.automation)
        #expect(mac.requests == [.automation])
        #expect(model.access(.automation) == .allowed)
        #expect(model.remaining == [.fullDiskAccess, .accessibility])
    }

    @Test func allowAllBringsUpEachMissingPromptInTurn() async {
        let mac = FakeMac()
        mac.states = [.keychain: .ready, .fullDiskAccess: .needsAttention, .accessibility: .ready,
                      .screenRecording: .needsAttention, .automation: .needsAttention, .microphone: .ready]
        mac.grantsOnRequest = [.automation]
        let model = makeModel(mac)
        model.allowAll()
        #expect(model.allowingAll)
        // Automation's prompt answers itself; Full Disk Access waits for its switch.
        await waitUntil { mac.requests == [.automation, .fullDiskAccess] }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(mac.requests == [.automation, .fullDiskAccess])
        mac.states[.fullDiskAccess] = .ready
        // Switched on: the next prompt comes up without anything to press.
        await waitUntil { mac.requests.last == .screenRecording }
        // Back in the app without switching it on: Allow all is done.
        model.appDidResignActive(); model.appDidBecomeActive()
        await waitUntil { !model.allowingAll }
        #expect(mac.requests == [.automation, .fullDiskAccess, .screenRecording])
    }

    @Test func comingBackWithoutSwitchingOneOnMovesToTheNext() async {
        let mac = FakeMac()
        mac.states = [.keychain: .ready, .fullDiskAccess: .needsAttention, .accessibility: .needsAttention,
                      .screenRecording: .ready, .automation: .ready, .microphone: .ready]
        let model = makeModel(mac)
        model.allowAll()
        await waitUntil { mac.requests == [.fullDiskAccess] }
        // A prompt closing before System Settings took over is not a return.
        model.appDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(mac.requests == [.fullDiskAccess])
        model.appDidResignActive(); model.appDidBecomeActive()
        await waitUntil { mac.requests == [.fullDiskAccess, .accessibility] }
        model.appDidResignActive(); model.appDidBecomeActive()
        await waitUntil { !model.allowingAll }
        #expect(model.remaining == [.fullDiskAccess, .accessibility])
    }

    @Test func aFinishedKeychainRequestLetsAllowAllContinue() async {
        let mac = FakeMac()
        mac.states = [.keychain: .needsAttention, .fullDiskAccess: .ready, .accessibility: .ready,
                      .screenRecording: .ready, .automation: .ready, .microphone: .needsAttention]
        mac.grantsOnRequest = [.microphone]
        let model = makeModel(mac)
        model.allowAll()
        await waitUntil { mac.requests == [.keychain] }
        model.keychainRequestEnded()
        await waitUntil { !model.allowingAll }
        #expect(mac.requests == [.keychain, .microphone])
    }

    @Test func deniedMicrophoneReadsAsSwitchedOff() {
        let mac = FakeMac()
        mac.states = [.microphone: .needsAttention]
        mac.turnedOff = [.microphone]
        let model = makeModel(mac)
        #expect(model.access(.microphone) == .turnedOff)
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
        mac.states[.screenRecording] = .ready
        model.refresh(keychainReady: nil)
        #expect(model.access(.screenRecording) == .allowed && model.requested == nil)
    }
}
