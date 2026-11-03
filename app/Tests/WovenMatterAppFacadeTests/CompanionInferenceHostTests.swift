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
        let host = CompanionInferenceHost(authentication: auth, descriptor: descriptor, directory: root, isActive: { true }, authorize: { _, _ in }, preparePayload: {
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

    @Test func aDelegatedGrantLosesInferenceAsSoonAsItsProvisioningMacIsUnpaired() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InferenceLive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = try CompanionExecutionAuthentication(fileURL: root.appendingPathComponent("devices.json"))
        let library = UUID().uuidString.lowercased(), workspace = UUID().uuidString.lowercased(), device = UUID().uuidString.lowercased()
        let provisioner = UUID().uuidString.lowercased()
        let descriptor = CompanionExecutionWorkspace(id: workspace, libraryID: library, ownerDeviceID: UUID().uuidString, kind: .mac, name: "Mac")
        let bearer = try await auth.provision(deviceID: device, libraryID: library, workspaceID: workspace, provisionedBy: provisioner)
        let probe = InferenceHostProbe()
        let gate = InferenceAuthorizationGate()
        // A fake provider: nothing leaves the process.
        let host = CompanionInferenceHost(authentication: auth, descriptor: descriptor, directory: root, isActive: { true },
            authorize: { deviceID, provisionedBy in try await gate.check(deviceID, provisionedBy) },
            preparePayload: { await probe.prepared(); return Data("{\"config\":{},\"credentials\":{}}".utf8) },
            run: { _, emit in await probe.ran(); try await emit(Data("{\"type\":\"done\"}\n".utf8)) })
        let headers = ["authorization": "Bearer " + bearer, "x-woven-protocol": String(CompanionProtocol.version),
            "x-woven-library": library, "x-woven-workspace": workspace, "x-woven-device": device]
        #expect(await host.handle(.init(method: "GET", target: "/v1/inference/catalog", headers: headers)).status == 200)
        // Checked before credentials are prepared and again before the helper runs.
        #expect(await gate.seen == [provisioner, provisioner])
        // The provisioning Mac is unpaired; the token itself is still on disk
        // (its asynchronous cleanup has not run), yet nothing is prepared.
        await gate.deny()
        #expect(await host.handle(.init(method: "GET", target: "/v1/inference/catalog", headers: headers)).status == 401)
        #expect(await probe.preparationCount == 1)
        // A stream admitted before the unpair is checked again before it starts.
        await gate.allow()
        let body = try JSONSerialization.data(withJSONObject: ["model": ["provider": "fixture", "id": "fixture"]])
        let response = await host.handle(.init(method: "POST", target: "/v1/inference/stream", headers: headers, body: body))
        #expect(response.status == 200)
        await gate.deny()
        let stream = try #require(response.stream)
        let lines = InferenceLines()
        try? await stream { data in lines.append(data) }
        #expect(lines.text.contains("\"type\":\"error\""))
        #expect(await probe.runs == 1)
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
    var runs = 0
    func ran() { runs += 1 }
}

private actor InferenceAuthorizationGate {
    var denied = false
    var seen: [String?] = []
    func deny() { denied = true }
    func allow() { denied = false }
    func check(_ deviceID: String, _ provisionedBy: String?) throws {
        seen.append(provisionedBy)
        if denied { throw CompanionAPIError(code: "unauthorized", message: "This device is no longer paired.") }
    }
}
private final class InferenceLines: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ value: Data) { lock.withLock { data.append(value) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
