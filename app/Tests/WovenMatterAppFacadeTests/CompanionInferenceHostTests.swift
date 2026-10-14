import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionInferenceHostTests {
    @Test func authenticationAndRevocationFenceCredentialPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InferenceHost-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = try CompanionExecutionAuthentication(fileURL: root.appendingPathComponent("devices.json"))
        let library = UUID().uuidString, workspace = UUID().uuidString, device = UUID().uuidString
        let descriptor = CompanionExecutionWorkspace(id: workspace, libraryID: library, ownerDeviceID: UUID().uuidString, kind: .mac, name: "Mac")
        let bearer = try await auth.provision(deviceID: device, libraryID: library, workspaceID: workspace)
        let probe = InferenceHostProbe()
        let host = CompanionInferenceHost(authentication: auth, descriptor: descriptor, directory: root, isActive: { true }, preparePayload: {
            await probe.prepared(); return Data("{\"config\":{},\"credentials\":{}}".utf8)
        }, run: { _, emit in try await emit(Data("{\"models\":[],\"accounts\":[]}\n".utf8)) })
        let headers = ["authorization": "Bearer " + bearer, "x-woven-protocol": String(CompanionProtocol.version),
            "x-woven-library": library, "x-woven-workspace": workspace, "x-woven-device": device]
        var wrong = headers; wrong["x-woven-device"] = UUID().uuidString
        #expect(await host.handle(.init(method: "GET", target: "/v1/inference/catalog", headers: wrong)).status == 403)
        #expect(await probe.preparationCount == 0)
        let response = await host.handle(.init(method: "GET", target: "/v1/inference/catalog", headers: headers))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self).contains("models"))
        #expect(await probe.preparationCount == 1)
        try await auth.revoke(deviceID: device)
        #expect(await host.handle(.init(method: "GET", target: "/v1/inference/catalog", headers: headers)).status == 401)
        #expect(await probe.preparationCount == 1)
    }

    @Test func helperCancellationTerminatesOnlyItsOwnedControlledProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InferenceProcess-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = "process.stdin.resume(); process.stdout.write(JSON.stringify({type:'start'})+'\\n'); setInterval(()=>{},1000);"
        let helper = CompanionInferenceProcess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node", "-e", script, "--"], directory: root)
        let probe = InferenceHostProbe()
        let running = Task { try await helper.run(body: Data("{}".utf8)) { _ in await probe.started() } }
        for _ in 0..<200 {
            if await probe.didStart { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.didStart)
        let start = ContinuousClock.now
        running.cancel()
        do { try await running.value; Issue.record("Cancelled inference process reported success") }
        catch is CancellationError {}
        catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(start.duration(to: .now) < .seconds(6))
    }
}

private actor InferenceHostProbe {
    var preparationCount = 0
    var didStart = false
    func prepared() { preparationCount += 1 }
    func started() { didStart = true }
}
