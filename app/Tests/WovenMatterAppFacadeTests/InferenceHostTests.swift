import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct InferenceHostTests {
    /// A phone member signs its inference requests: no grant exists, the
    /// principal is its member device, and removing it ends access at once.
    @Test func signedMembersUseInferenceWithoutAGrant() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.libraryIdentity()
        let mac = MemberDirectory(database: fixture.database, identity: MemberIdentity(deviceID: identity.hostDeviceID, kind: .mac, key: .init()), cacheLifetime: 0)
        try await mac.ensureSelf(name: "Mac", endpoints: [])
        let phone = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .ios, key: .init())
        let linux = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
        try await mac.add(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: phone.publicKey, endpoints: [])
        try await mac.add(deviceID: linux.deviceID, kind: .linux, name: "Linux", publicKey: linux.publicKey, endpoints: [])
        let workspace = UUID().uuidString.lowercased()
        let descriptor = ExecutionWorkspace(id: workspace, libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac")
        let probe = InferenceHostProbe(), principals = InferenceLines()
        let host = InferenceHost(descriptor: descriptor, directory: fixture.directory, isActive: { true }, members: mac,
            preparePayload: { await probe.prepared(); return Data("{\"config\":{},\"credentials\":{}}".utf8) },
            run: { body, emit in
                principals.append(Data(((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["principalID"] as? String ?? "").utf8))
                try await emit(Data("{\"models\":[],\"accounts\":[]}\n".utf8))
            })
        func catalog(_ member: MemberIdentity, audience: String? = nil, workspace named: String? = nil) async throws -> Int {
            var headers = try member.signer.headers(method: "GET", target: "/wovenmatter/v1/inference/catalog?provider=fixture",
                                                    audience: audience ?? identity.hostDeviceID)
            headers["X-Woven-Protocol"] = String(LibraryProtocol.version); headers["X-Woven-Workspace"] = named ?? workspace
            let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
            return await host.handle(.init(method: "GET", target: "/wovenmatter/v1/inference/catalog?provider=fixture", headers: lowered)).status
        }
        #expect(try await catalog(phone) == 200)
        #expect(principals.text == phone.deviceID)
        // Addressed to another member, naming another workspace, or from a Linux host: refused before credentials.
        #expect(try await catalog(phone, audience: UUID().uuidString.lowercased()) == 401)
        #expect(try await catalog(phone, workspace: UUID().uuidString.lowercased()) == 403)
        #expect(try await catalog(linux) == 403)
        #expect(await probe.preparationCount == 1)
        try await mac.remove(phone.deviceID)
        #expect(try await catalog(phone) == 401)
        #expect(await probe.preparationCount == 1)
    }

    @Test func helperCancellationTerminatesOnlyItsOwnedControlledProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InferenceProcess-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = "process.stdin.resume(); process.stdout.write(JSON.stringify({type:'start'})+'\\n'); setInterval(()=>{},1000);"
        let helper = InferenceHostProcess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node", "-e", script, "--"], directory: root)
        let probe = InferenceHostProbe()
        let running = Task { try await helper.run(body: Data("{}".utf8)) { _ in await probe.started() } }
        _ = try await pollUntil(attempts: 200, interval: .milliseconds(10)) { await probe.didStart }
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
        if denied { throw LibraryAPIError(code: "unauthorized", message: "This device is no longer paired.") }
    }
}
private final class InferenceLines: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ value: Data) { lock.withLock { data.append(value) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
