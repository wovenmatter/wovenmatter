import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

struct ProductAnalyticsDisclosureTests {
    @Test @MainActor func pendingLogReadCannotCollectBeforeLocalDisclosure() async throws {
        let url = URL(
            fileURLWithPath: "/private/tmp/wm-disclosure-" + UUID().uuidString.prefix(8)
        ).appending(path: "control.sock")
        let preference = ProductAnalyticsPreference(
            analyticsID: UUID().uuidString.lowercased(), disclosedAt: Date())
        let key = "wovenmatter.analytics.disclosed." + preference.analyticsID
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let fixture = AnalyticsDisclosureFixture(preference: preference)
        let server = BackendRPCServer(socketURL: url)
        try server.start { await fixture.handle($0) }
        defer { server.stop() }
        let model = ProductAnalyticsModel()
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
