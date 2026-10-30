import WorkspaceFixtures
import CompanionClient
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct SecondaryMacExecutionWorkspaceTests {


    @Test func toolCreatedFoldersAndNotesUseStableIDsAndDeletionReturnsToReplica() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let libraryID = UUID().uuidString.lowercased()
        try await replica.verifyWorkspace(libraryID)
        let owner = await replica.snapshot().deviceID
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: libraryID,
            ownerDeviceID: owner, kind: .mac, name: "Fixture"), model: fixture.model, replica: replica, directory: fixture.directory)
        let folder = try await fixture.database.createFixtureFolder(name: "Tool folder")
        let content = try NoteDocument(blocks: [.richText(.init(text: "Tool note"))]).encoded()
        let note = try await fixture.database.createNote(folderID: folder, title: "Tool note", content: content)
        try await workspace.capture()
        let projected = await replica.snapshot()
        #expect(projected.folders[folder]?.name == "Tool folder")
        #expect(projected.notes[note]?.folderID == folder)
        #expect(projected.outbox.map(\.mutation.kind) == [.createFolder, .createNote])
        // A tool rename updates the queued creation without changing identity.
        try await fixture.database.renameFolder(id: folder, name: "Renamed tool folder")
        try await workspace.capture()
        let renamed = await replica.snapshot()
        #expect(renamed.folders[folder]?.name == "Renamed tool folder")
        #expect(renamed.notes[note]?.folderID == folder)
        #expect(renamed.outbox.filter { $0.mutation.resourceID == folder }.count == 1)
        #expect(renamed.outbox.first { $0.mutation.resourceID == folder }?.mutation.title == "Renamed tool folder")
        let saved = try #require(try await fixture.database.companionNote(id: note))
        #expect(try await fixture.database.applyCompanionMutation(.init(deviceID: owner, kind: .deleteNote,
            resourceID: note, expectedRevision: saved.revision)).status == .accepted)
        try await workspace.capture()
        #expect(await replica.snapshot().notes[note] == nil)
        #expect(!(await replica.snapshot().outbox.contains { $0.mutation.resourceID == note }))
        try await fixture.database.deleteFolder(id: folder)
        try await workspace.capture()
        let removed = await replica.snapshot()
        #expect(removed.folders[folder] == nil)
        #expect(!removed.outbox.contains { $0.mutation.resourceID == folder })
        let reopened = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let restored = await reopened.snapshot()
        #expect(restored.folders[folder] == nil && restored.notes[note] == nil)
        #expect(!restored.outbox.contains { $0.mutation.resourceID == folder || $0.mutation.resourceID == note })
    }

    @Test func managementRequestCannotCrossAHostRestartAtTheSameEndpoint() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let libraryID = UUID().uuidString.lowercased()
        try await replica.verifyWorkspace(libraryID)
        let owner = await replica.snapshot().deviceID
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: libraryID,
            ownerDeviceID: owner, kind: .mac, name: "Fixture"), model: fixture.model, replica: replica, directory: fixture.directory)
        let serving = SecondaryServingFixture()
        let gate = SecondaryManagementGate()
        let host = SecondaryMacExecutionHost(workspace: workspace, directory: fixture.directory,
            makeExposure: { serving.exposure() }, afterManagementAuthentication: { await gate.pauseIfRequested() })
        defer { host.stop() }
        try await host.start()
        let originalEndpoint = host.endpoint
        let originalGrant = try #require(host.managementGrant)
        let oldHandler = host.requestHandler()
        let deviceID = UUID().uuidString.lowercased()
        func request(_ grant: CompanionExecutionManagementGrant, path: String) throws -> CompanionHTTPRequest {
            .init(method: "POST", target: path, headers: ["authorization": "Bearer " + grant.token,
                "x-woven-protocol": String(CompanionProtocol.version), "x-woven-library": libraryID,
                "x-woven-workspace": owner], body: try JSONEncoder().encode(["deviceID": deviceID]))
        }
        gate.hold = true
        let originalRequest = try request(originalGrant, path: "/v1/execution/manage/devices")
        let pending = Task { await oldHandler(originalRequest) }
        for _ in 0..<300 where !gate.arrived { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.arrived)
        host.stop()
        try await host.start()
        #expect(host.endpoint == originalEndpoint)
        let replacementGrant = try #require(host.managementGrant)
        let handler = host.requestHandler()
        let response = await handler(try request(replacementGrant, path: "/v1/execution/manage/devices"))
        #expect(response.status == 200)
        let credential = try JSONDecoder().decode(CompanionExecutionCredential.self, from: response.body)
        gate.release()
        #expect(await pending.value.status == 503)
        let auth = try CompanionExecutionAuthentication(fileURL: fixture.directory.appending(path: "execution-access.json"))
        #expect(try await auth.authenticate(bearer: credential.token).deviceID == deviceID)
        #expect(await handler(originalRequest).status == 403)
        let revoked = await handler(try request(replacementGrant, path: "/v1/execution/manage/revoke"))
        #expect(revoked.status == 200)
        host.stop(); try await host.waitUntilStopped(); try await host.start()
        let restarted = host.requestHandler()
        let executionRead = CompanionHTTPRequest(method: "GET", target: "/v1/execution", headers: [
            "authorization": "Bearer " + credential.token, "x-woven-protocol": String(CompanionProtocol.version),
            "x-woven-library": libraryID, "x-woven-workspace": owner, "x-woven-device": deviceID])
        #expect(await restarted(executionRead).status == 401)
    }

    @Test func directCommandsAreIdempotentAndActiveRunsBlockRoleChanges() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let libraryID = UUID().uuidString.lowercased()
        try await replica.verifyWorkspace(libraryID)
        let owner = await replica.snapshot().deviceID
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: libraryID,
            ownerDeviceID: owner, kind: .mac, name: "Fixture"), model: fixture.model, replica: replica, directory: fixture.directory)
        let conversation = UUID().uuidString.lowercased()
        let created = try await workspace.command(.init(deviceID: owner, kind: .createSession,
            conversationID: conversation, providerID: "local:codex", workspaceID: owner))
        #expect(created.status == .completed)
        let note = try await replica.createNote(folderID: nil, title: "Context", content: NoteDocument(blocks: [.richText(.init(text: "Bound note"))]).encoded())
        let input = CompanionCommand(deviceID: owner, kind: .send, conversationID: conversation, text: "Exactly once",
            noteID: note.id, noteRevision: note.revision, workspaceID: owner)
        let receipt = try await workspace.command(input)
        #expect(receipt.status == .completed)
        #expect(try await workspace.command(input) == receipt)
        var reused = input; reused.text = "Different request"
        await #expect(throws: (any Error).self) { _ = try await workspace.command(reused) }
        #expect(await fixture.recorder.deliveries.count == 1)
        await #expect(throws: (any Error).self) { try await workspace.prepareToStop() }
        let stopped = try await workspace.command(.init(deviceID: owner, kind: .stop, conversationID: conversation,
            runID: receipt.runID, workspaceID: owner))
        #expect(stopped.status == .completed)
        let nativePayload = String(repeating: "native tool result ", count: 8_000)
        let nativeID = UUID().uuidString.lowercased()
        try await fixture.database.recordHistory(.init(id: nativeID, conversationID: conversation, runID: receipt.runID,
            harness: "codex", kind: "wire.in", payload: nativePayload))
        try await workspace.capture()
        let captured = await workspace.origin.snapshot()
        let parts = captured.entries.values.filter { $0.nativeRecord?.format == "woven-matter-history.v1" }
        let groups = Dictionary(grouping: parts, by: { $0.nativeRecord!.recordID })
        let decoded = try groups.values.map { entries in
            let bytes = entries.sorted { $0.nativeRecord!.partIndex < $1.nativeRecord!.partIndex }.reduce(into: Data()) { $0.append($1.nativeRecord!.data) }
            return try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }
        #expect(decoded.contains { $0?["id"] as? String == nativeID && $0?["payload"] as? String == nativePayload })
        let recordCount = parts.count
        try await workspace.capture()
        #expect(await workspace.origin.snapshot().entries.values.filter { $0.nativeRecord != nil }.count == recordCount)
        try await workspace.prepareToStop()
        await #expect(throws: (any Error).self) { _ = try await workspace.command(input) }
        let journal = await workspace.origin.snapshot()
        #expect(journal.conversations[conversation]?.workspaceID == owner)
        #expect(journal.entries.values.contains { $0.receipt?.commandID == input.commandID })
    }
}

@MainActor private final class SecondaryManagementGate {
    var hold = false
    var arrived = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pauseIfRequested() async {
        guard hold else { return }
        hold = false; arrived = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

@MainActor final class SecondaryServingFixture {
    var child: SecondaryServingChild?
    func exposure() -> CompanionTailscaleServe {
        CompanionTailscaleServe(executable: URL(fileURLWithPath: "/fixture/tailscale"),
            probe: { [self] _, arguments in try await probe(arguments) },
            launch: { [self] _, arguments in
                let value = SecondaryServingChild(port: Int(arguments[1].dropFirst("--https=".count))!, target: arguments[3])
                child = value; return value
            })
    }
    func probe(_ arguments: [String]) throws -> Data {
        if arguments == ["status", "--json"] {
            return Data(#"{"BackendState":"Running","Self":{"DNSName":"secondary.test.ts.net."}}"#.utf8)
        }
        guard let child, child.isRunning else { return Data("{}".utf8) }
        return try JSONSerialization.data(withJSONObject: ["Foreground": ["fixture": [
            "TCP": [String(child.port): ["HTTPS": true]],
            "Web": ["secondary.test.ts.net:\(child.port)": ["Handlers": ["/wovenmatter": ["Proxy": child.target]]]]]]])
    }
}

@MainActor final class SecondaryServingChild: CompanionServingProcess {
    let port: Int
    let target: String
    var isRunning = true
    init(port: Int, target: String) { self.port = port; self.target = target }
    func terminate() { isRunning = false }
}
