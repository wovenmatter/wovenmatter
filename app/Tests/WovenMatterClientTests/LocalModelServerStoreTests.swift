import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite struct LocalModelServerStoreTests {
    @Test func activeServerIdentityCannotBeRetargetedWithAnotherHostsKey() async {
        let existing = LocalModelServer(url: "http://localhost:32100/v1", models: ["local/active"])
        do {
            _ = try await LocalModelServerStore.connect(url: "http://localhost:32101/v1", key: "different-host-fixture-key", replacing: existing)
            Issue.record("An existing server identity was retargeted")
        } catch {
            #expect(error.localizedDescription == "Add a new connection to use a different server URL.")
        }
    }
}
