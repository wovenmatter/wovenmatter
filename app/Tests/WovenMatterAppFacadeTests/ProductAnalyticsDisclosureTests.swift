import CompanionClient
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

struct ProductAnalyticsDisclosureTests {
    @Test @MainActor func secondaryMacUpdatesUseTheCentralLibraryAndRespectOfflineOptOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobileProductAnalytics(file: directory.appending(path: "analytics.json"))
        let preference = ProductAnalyticsPreference(analyticsID: UUID().uuidString.lowercased(),
            disclosedAt: Date().addingTimeInterval(-60))
        try await store.apply(preference)
        try await store.disclose(enabled: true)
        try await store.synchronize(using: RelayedAnalyticsFixture(preference: preference))
        let domain = "wovenmatter.analytics.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = ProductAnalyticsModel(defaults: defaults)
        await model.configure(client: store)
        await model.record(.updateCheckClicked)
        await model.record(.updateDownloadCompleted, properties: ["target_version": "1.2.3"])
        let event = ProductAnalyticsEvent(preferenceRevision: preference.revision,
            name: .updateInstallCompleted, properties: ["target_version": "1.2.3"])
        let receipt = ProductAnalyticsUpdateReceipt(analyticsID: preference.analyticsID,
            version: "1.2.3", build: 4, event: event, confirmed: true)
        let data = try JSONEncoder().encode(receipt)
        defaults.set(data, forKey: ProductAnalyticsModel.updateReceiptKey)
        await model.confirmUpdateInstallation(version: "1.2.3", build: 4)
        defaults.set(data, forKey: ProductAnalyticsModel.updateReceiptKey)
        await model.confirmUpdateInstallation(version: "1.2.3", build: 4)
        let snapshot = await store.snapshot()
        #expect(model.preference?.analyticsID == preference.analyticsID)
        #expect(snapshot.events.count == 3)
        #expect(snapshot.events.filter { $0.name == .updateInstallCompleted }.count == 1)
        #expect(snapshot.events.allSatisfy { !$0.qualifying && $0.properties["platform"] != "ios" })
        #expect(!model.disclosurePresented)
        try await store.setEnabled(false)
        defaults.set(data, forKey: ProductAnalyticsModel.updateReceiptKey)
        await model.refresh()
        await model.record(.updateDownloadClicked)
        #expect(await store.snapshot().events.isEmpty)
        #expect(defaults.data(forKey: ProductAnalyticsModel.updateReceiptKey) == nil)
    }

    @Test @MainActor func remoteReenableResumesFutureCollectionOnTheCentralMac() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await WorkspaceDatabase(url: directory.appending(path: "library.sqlite"))
        let initial = try await db.productAnalyticsPreference()
        let preference = try await db.setProductAnalyticsPreference(.init(enabled: true,
            expectedRevision: initial.revision, acknowledgeDisclosure: true))
        let domain = "wovenmatter.analytics.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "wovenmatter.analytics.disclosed." + preference.analyticsID)
        let model = ProductAnalyticsModel(defaults: defaults)
        model.configure(database: db, publisher: false)
        await model.openInterface()
        await model.setEnabled(false)
        let disabled = try await db.productAnalyticsPreference()
        _ = try await model.change(.init(enabled: true, expectedRevision: disabled.revision))
        await model.record(.messageSubmitted)
        #expect(model.enabled)
        #expect(try await db.productAnalyticsLog().map(\.event.name) == [.messageSubmitted])
    }

    @Test @MainActor func repeatedInterfaceOpensCountOnceAndUpdatesDoNotQualify() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await WorkspaceDatabase(url: directory.appending(path: "library.sqlite"))
        let initial = try await db.productAnalyticsPreference()
        let preference = try await db.setProductAnalyticsPreference(.init(enabled: true,
            expectedRevision: initial.revision, acknowledgeDisclosure: true))
        let domain = "wovenmatter.analytics.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let key = "wovenmatter.analytics.disclosed." + preference.analyticsID
        defaults.set(true, forKey: key)
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = ProductAnalyticsModel(defaults: defaults)
        model.configure(database: db, publisher: false)
        await model.openInterface()
        await model.openInterface()
        await model.record(.updateDownloadCompleted, properties: ["target_version": "1.2.3"])
        let log = try await db.productAnalyticsLog()
        #expect(log.filter { $0.event.name == .appOpened }.count == 1)
        #expect(log.count == 2)
        #expect(log.allSatisfy { !$0.event.qualifying })
    }

    @Test @MainActor func delayedCompletionAcknowledgementCannotEraseANewerUpdate() async throws {
        let url = URL(fileURLWithPath: "/private/tmp/wm-update-ack-" + UUID().uuidString.prefix(8)).appending(path: "control.sock")
        let preference = ProductAnalyticsPreference(analyticsID: UUID().uuidString.lowercased(),
            disclosedAt: Date().addingTimeInterval(-60))
        let domain = "wovenmatter.analytics.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        defaults.set(true, forKey: "wovenmatter.analytics.disclosed." + preference.analyticsID)
        let fixture = AnalyticsUpdateAcknowledgementFixture(preference: preference)
        let server = BackendRPCServer(socketURL: url)
        try server.start { await fixture.handle($0) }
        defer { server.stop() }
        let model = ProductAnalyticsModel(defaults: defaults)
        model.configure(rpc: BackendRPCClient(socketURL: url))
        await model.openInterface()
        let old = ProductAnalyticsUpdateReceipt(analyticsID: preference.analyticsID, version: "1.2.3", build: 4,
            event: .init(preferenceRevision: preference.revision, name: .updateInstallCompleted), confirmed: true)
        defaults.set(try JSONEncoder().encode(old), forKey: ProductAnalyticsModel.updateReceiptKey)
        let completion = Task { await model.confirmUpdateInstallation(version: "1.2.3", build: 4) }
        await fixture.waitUntilCompletion()
        let newer = ProductAnalyticsUpdateReceipt(analyticsID: preference.analyticsID, version: "1.2.4", build: 5,
            event: .init(preferenceRevision: preference.revision, name: .updateInstallCompleted))
        let newerData = try JSONEncoder().encode(newer)
        defaults.set(newerData, forKey: ProductAnalyticsModel.updateReceiptKey)
        await fixture.releaseAcknowledgement()
        await completion.value
        #expect(defaults.data(forKey: ProductAnalyticsModel.updateReceiptKey) == newerData)
    }

    @Test @MainActor func confirmedInstallRetriesOnceAndOptOutClearsTheReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let domain = "wovenmatter.analytics.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let db = try await WorkspaceDatabase(url: directory.appending(path: "library.sqlite"))
        let initial = try await db.productAnalyticsPreference()
        let preference = try await db.setProductAnalyticsPreference(.init(enabled: true,
            expectedRevision: initial.revision, acknowledgeDisclosure: true))
        defaults.set(true, forKey: "wovenmatter.analytics.disclosed." + preference.analyticsID)
        let model = ProductAnalyticsModel(defaults: defaults)
        model.configure(database: db, publisher: false)
        await model.openInterface()
        let event = ProductAnalyticsEvent(preferenceRevision: preference.revision,
            name: .updateInstallCompleted, properties: ["target_version": "1.2.3"])
        var receipt = ProductAnalyticsUpdateReceipt(analyticsID: preference.analyticsID,
            version: "1.2.3", build: 4, event: event)
        #expect({ receipt.confirmLaunch(marker: URL(fileURLWithPath: "/tmp/.ready-" + event.id),
            version: "1.2.3", build: 4) }())
        let data = try JSONEncoder().encode(receipt)
        defaults.set(data, forKey: ProductAnalyticsModel.updateReceiptKey)
        await model.confirmUpdateInstallation(version: "1.2.2", build: 4)
        #expect(defaults.data(forKey: ProductAnalyticsModel.updateReceiptKey) != nil)
        await model.confirmUpdateInstallation(version: "1.2.3", build: 4)
        #expect(defaults.data(forKey: ProductAnalyticsModel.updateReceiptKey) == nil)
        // Replaying the durable receipt after an interrupted acknowledgement
        // still contributes one completion UUID to the central library log.
        defaults.set(data, forKey: ProductAnalyticsModel.updateReceiptKey)
        await model.confirmUpdateInstallation(version: "1.2.3", build: 4)
        #expect(try await db.productAnalyticsLog().filter { $0.event.name == .updateInstallCompleted }.count == 1)
        defaults.set(data, forKey: ProductAnalyticsModel.updateReceiptKey)
        await model.setEnabled(false)
        #expect(defaults.data(forKey: ProductAnalyticsModel.updateReceiptKey) == nil)
        #expect(try await db.productAnalyticsLog().isEmpty)
    }

    @Test func installationRequiresMatchingReplacementLaunchAndKeepsOneEventIdentity() throws {
        let now = Date()
        let preference = ProductAnalyticsPreference(analyticsID: UUID().uuidString,
            disclosedAt: now.addingTimeInterval(-1))
        let event = ProductAnalyticsEvent(preferenceRevision: preference.revision,
            name: .updateInstallCompleted, properties: ["target_version": "1.2.3"])
        var receipt = ProductAnalyticsUpdateReceipt(analyticsID: preference.analyticsID,
            version: "1.2.3", build: 4, event: event)
        let marker = URL(fileURLWithPath: "/private/tmp/.ready-" + event.id)
        #expect(!receipt.confirmed)
        #expect({ !receipt.confirmLaunch(marker: marker, version: "1.2.2", build: 4) }())
        #expect({ !receipt.confirmLaunch(marker: marker, version: "1.2.3", build: 3) }())
        #expect({ !receipt.confirmLaunch(marker: marker.appendingPathExtension("wrong"),
            version: "1.2.3", build: 4) }())
        #expect({ receipt.confirmLaunch(marker: marker, version: "1.2.3", build: 4, now: now) }())
        #expect(receipt.confirmed && receipt.event.timestamp == now)
        #expect({ !receipt.confirmLaunch(marker: marker, version: "1.2.3", build: 4) }())
        let restored = try JSONDecoder().decode(ProductAnalyticsUpdateReceipt.self,
            from: JSONEncoder().encode(receipt))
        #expect(restored == receipt && restored.event.id == event.id)
        #expect(restored.event.validated(preference: preference) != nil)
        var changed = preference
        changed.enabled = false
        #expect(restored.event.validated(preference: changed) == nil)
        changed.enabled = true; changed.revision += 1
        #expect(restored.event.validated(preference: changed) == nil)
        #expect(!restored.event.qualifying)
        #expect(!restored.event.inspectionJSON(analyticsID: preference.analyticsID).contains("/private"))
    }

    @Test @MainActor func pendingLogReadCannotCollectBeforeLocalDisclosure() async throws {
        let url = URL(
            fileURLWithPath: "/private/tmp/wm-disclosure-" + UUID().uuidString.prefix(8)
        ).appending(path: "control.sock")
        let preference = ProductAnalyticsPreference(
            analyticsID: UUID().uuidString.lowercased(), disclosedAt: Date())
        let domain = "wovenmatter.analytics.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let fixture = AnalyticsDisclosureFixture(preference: preference)
        let server = BackendRPCServer(socketURL: url)
        try server.start { await fixture.handle($0) }
        defer { server.stop() }
        let model = ProductAnalyticsModel(defaults: defaults)
        model.configure(rpc: BackendRPCClient(socketURL: url))
        let opening = Task { await model.openInterface() }
        await fixture.waitUntilLogRead()
        #expect(model.disclosurePresented)
        await model.record(.sessionCreated)
        #expect(await fixture.recordedCount() == 0)
        await fixture.releaseLogRead()
        await opening.value
        #expect(model.disclosurePresented)
    }
}

private actor AnalyticsDisclosureFixture {
    let preference: ProductAnalyticsPreference
    private var logHeld = false
    private var logWaiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var recorded = 0
    init(preference: ProductAnalyticsPreference) { self.preference = preference }
    func handle(_ request: BackendRPCRequest) async -> BackendRPCResponse {
        switch request.method {
        case "analytics.preference":
            return .init(id: request.id, result: try! JSONEncoder().encode(preference))
        case "analytics.log":
            logHeld = true
            await withCheckedContinuation { continuation in
                logWaiter = continuation
                observer?.resume()
                observer = nil
            }
            return .init(id: request.id, result: Data("[]".utf8))
        case "analytics.events":
            recorded += 1
            let acknowledgement = ProductAnalyticsAcknowledgement(
                acceptedEventIDs: [], preference: preference)
            return .init(id: request.id, result: try! JSONEncoder().encode(acknowledgement))
        default:
            return .init(id: request.id, result: Data())
        }
    }
    func waitUntilLogRead() async {
        if logHeld { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseLogRead() { logWaiter?.resume(); logWaiter = nil }
    func recordedCount() -> Int { recorded }
}

private actor AnalyticsUpdateAcknowledgementFixture {
    let preference: ProductAnalyticsPreference
    private var held = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(preference: ProductAnalyticsPreference) { self.preference = preference }
    func handle(_ request: BackendRPCRequest) async -> BackendRPCResponse {
        switch request.method {
        case "analytics.preference": return .init(id: request.id, result: try! JSONEncoder().encode(preference))
        case "analytics.log": return .init(id: request.id, result: Data("[]".utf8))
        case "analytics.events":
            let batch = try! JSONDecoder().decode(ProductAnalyticsBatch.self, from: request.payload)
            if batch.events.contains(where: { $0.name == .updateInstallCompleted }) {
                held = true
                await withCheckedContinuation { continuation in
                    waiter = continuation; observer?.resume(); observer = nil
                }
            }
            let ack = ProductAnalyticsAcknowledgement(acceptedEventIDs: batch.events.map(\.id), preference: preference)
            return .init(id: request.id, result: try! JSONEncoder().encode(ack))
        default: return .init(id: request.id, result: Data())
        }
    }
    func waitUntilCompletion() async {
        if held { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseAcknowledgement() { waiter?.resume(); waiter = nil }
}

private actor RelayedAnalyticsFixture: ProductAnalyticsTransport {
    let preference: ProductAnalyticsPreference
    init(preference: ProductAnalyticsPreference) { self.preference = preference }
    func analyticsPreference() -> ProductAnalyticsPreference { preference }
    func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) -> ProductAnalyticsPreference { preference }
    func sendAnalytics(_ batch: ProductAnalyticsBatch) -> ProductAnalyticsAcknowledgement {
        .init(acceptedEventIDs: batch.events.map(\.id), preference: preference)
    }
}
