import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionHostLifecycleTests {
    @Test func realHostWaitsForOwnedCleanupBeforeCreatingReplacementExposure() async throws {
        let fixture = try HostFixture()
        defer { fixture.remove() }
        await fixture.host.start()
        let address = try #require(fixture.host.endpoint)
        #expect(fixture.children.count == 1)
        fixture.host.stopSharing()
        #expect(fixture.children[0].isRunning)
        await fixture.host.start()
        #expect(fixture.host.endpoint == address)
        #expect(fixture.host.errorMessage == nil)
        #expect(fixture.exposureCount == 2 && fixture.children.count == 2)
        #expect(!fixture.replacementCreatedWhileStopping)
        #expect(!fixture.children[0].isRunning && fixture.children[1].isRunning)
        #expect(fixture.existingPorts == [443])
    }

    @Test func staleHostStartupCannotStopReplacementExposure() async throws {
        let fixture = try HostFixture()
        defer { fixture.remove() }
        fixture.holdFirstStatus = true
        let old = Task { await fixture.host.start() }
        try await waitUntil { fixture.firstStatusArrived }
        fixture.host.stopSharing()
        await fixture.host.start()
        let replacement = try #require(fixture.host.endpoint)
        #expect(fixture.children.count == 1 && fixture.children[0].isRunning)
        fixture.releaseFirstStatus()
        await old.value
        #expect(fixture.host.endpoint == replacement)
        #expect(fixture.host.errorMessage == nil)
        #expect(fixture.children[0].isRunning)
        #expect(fixture.children[0].terminationCount == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostFixtureError.timeout
    }
}

private enum HostFixtureError: Error { case timeout }

@MainActor private final class HostFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let model: ApplicationModel
    lazy var host = CompanionHostController(model: model, defaults: defaults, supportDirectory: directory,
        makeExposure: { [unowned self] in makeExposure() })
    let existingPorts: Set<Int> = [443]
    var exposureCount = 0
    var children: [HostServingChild] = []
    var replacementCreatedWhileStopping = false
    var holdFirstStatus = false
    var firstStatusArrived = false
    private var firstStatusWaiter: CheckedContinuation<Void, Never>?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "companion-host-\(UUID())")
        suite = "companion.host.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let store = try DashboardStore(supportDirectory: directory)
        model = ApplicationModel(applicationDefaults: defaults, dashboardStore: store, startsAutomatically: false)
    }
    func makeExposure() -> CompanionTailscaleServe {
        replacementCreatedWhileStopping = replacementCreatedWhileStopping || children.contains { $0.stoppedAt != nil && $0.isRunning }
        exposureCount += 1
        let attempt = exposureCount
        return CompanionTailscaleServe(executable: URL(fileURLWithPath: "/fixture/tailscale"),
            probe: { [self] _, arguments in try await probe(arguments, attempt: attempt) },
            launch: { [self] _, arguments in
                let child = HostServingChild(port: Int(arguments[1].dropFirst("--https=".count))!, target: arguments[3])
                children.append(child)
                return child
            })
    }
    func probe(_ arguments: [String], attempt: Int) async throws -> Data {
        if arguments == ["status", "--json"] {
            if attempt == 1 && holdFirstStatus {
                firstStatusArrived = true
                await withCheckedContinuation { firstStatusWaiter = $0 }
            }
            return Data(#"{"BackendState":"Running","Self":{"DNSName":"fixture.test.ts.net."}}"#.utf8)
        }
        let tcp = Dictionary(uniqueKeysWithValues: existingPorts.map { (String($0), ["HTTPS": true]) })
        var foreground: [String: Any] = [:]
        for (index, child) in children.enumerated() where child.isRunning {
            foreground[String(index)] = ["TCP": [String(child.port): ["HTTPS": true]],
                "Web": ["fixture.test.ts.net:\(child.port)": ["Handlers": ["/wovenmatter": ["Proxy": child.target]]]]]
        }
        return try JSONSerialization.data(withJSONObject: ["TCP": tcp, "Foreground": foreground])
    }
    func releaseFirstStatus() { firstStatusWaiter?.resume(); firstStatusWaiter = nil }
    func remove() {
        releaseFirstStatus()
        host.stopSharing()
        children.forEach { $0.forceStopped = true }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private final class HostServingChild: CompanionServingProcess {
    let port: Int
    let target: String
    var stoppedAt: TimeInterval?
    var forceStopped = false
    var terminationCount = 0
    init(port: Int, target: String) { self.port = port; self.target = target }
    var isRunning: Bool {
        !forceStopped && stoppedAt.map { ProcessInfo.processInfo.systemUptime - $0 < 0.4 } ?? !forceStopped
    }
    func terminate() { terminationCount += 1; stoppedAt = ProcessInfo.processInfo.systemUptime }
}
