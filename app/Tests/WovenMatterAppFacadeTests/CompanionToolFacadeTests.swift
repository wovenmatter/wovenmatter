import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionToolFacadeTests {
    @Test func pairedDeviceControlsEveryWorkspaceEvenWithLegacyDenials() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await importPhone(fixture)
        let identity = try await fixture.database.companionLibraryIdentity()
        let localID = UUID().uuidString.lowercased()
        let remoteID = fixture.remote.id.uuidString.lowercased()
        for (id, kind) in [(localID, CompanionExecutionWorkspace.Kind.mac), (remoteID, .linux)] {
            _ = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
                id: id, libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
                kind: kind, name: "Paired workspace", executionDeviceID: kind == .mac ? identity.hostDeviceID : nil)),
                deviceID: identity.hostDeviceID)
        }
        let device = fixture.device
        // A restored legacy table must never restrict an already paired device.
        try await fixture.database.write { connection in
            try connection.executeUnlocked("CREATE TABLE companion_workspace_access(device_id TEXT,workspace_id TEXT,enabled INTEGER)")
            for id in [localID, remoteID] {
                try connection.companionExecuteUnlocked("INSERT INTO companion_workspace_access VALUES (?,?,0)", values: [device, id])
            }
        }
        try await fixture.database.requireCompanionAutomationAccess(callerID: caller)
        let localChat = try #require(await fixture.model.createLocalACPSession(runtimeKind: .codex))
        let remoteChat = try await fixture.createConversation()
        for chat in [localChat, remoteChat] {
            let response = try await fixture.model.companionCommands.executeTool(.init(conversationID: caller,
                request: .init(arguments: ["sessions", "manage", chat, "--purpose", "Shared access"]),
                enabledGroups: WorkspaceToolGroup.allCases), deviceID: device)
            #expect(response.success, "\(response.error ?? "")")
            let command = CompanionCommand(deviceID: device, kind: .send,
                conversationID: chat, text: "Run through the provider-free fixture")
            let receipt = try await fixture.model.companionCommands.execute(command, deviceID: device)
            #expect(receipt.status == .completed, "\(receipt.message ?? "")")
        }
        #expect(await fixture.recorder.deliveries.count == 2)
    }

    @Test func importedPhoneCallerUsesActualNotesCalendarAndHistoryWithoutProvider() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await importPhone(fixture)
        func request(_ arguments: [String]) -> CompanionToolRequest {
            .init(conversationID: caller, request: .init(arguments: arguments), enabledGroups: WorkspaceToolGroup.allCases)
        }
        let create = request(["notes", "create", "--title", "From phone", "--kind", "html"])
        let result = try await fixture.model.companionCommands.executeTool(create, deviceID: fixture.device)
        #expect(result.success, "\(result.error ?? "")")
        let noteID = try #require(result.result?.objectValue?["id"]?.stringValue)
        #expect(try await fixture.database.companionNote(id: noteID)?.kind == .html)
        let read = try await fixture.model.companionCommands.executeTool(request(["notes", "read", noteID]), deviceID: fixture.device)
        #expect(read.success && read.result?.objectValue?["kind"]?.stringValue == "html", "\(read.error ?? "")")
        let calendar = try await fixture.model.companionCommands.executeTool(request([
            "calendar", "create", "--title", "Phone event", "--starts-at", "2026-12-01T12:00:00Z"
        ]), deviceID: fixture.device)
        #expect(calendar.success, "\(calendar.error ?? "")")
        let listed = try await fixture.model.companionCommands.executeTool(request(["calendar", "list"]), deviceID: fixture.device)
        #expect(listed.success, "\(listed.error ?? "")")
        let history = try await fixture.model.companionCommands.executeTool(request(["history", "conversations"]), deviceID: fixture.device)
        #expect(history.success, "\(history.error ?? "")")
        let replay = try await fixture.model.companionCommands.executeTool(create, deviceID: fixture.device)
        #expect(replay.result == result.result)
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(await fixture.recorder.configurations.isEmpty)
        #expect(try await fixture.database.companionSnapshot().notes.count == 1)
    }

    @Test func httpEndpointUsesPairedIdentityAndCurrentRevocation() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await importPhone(fixture)
        let auth = try CompanionAuthentication(fileURL: fixture.directory.appending(path: "test-devices.json"))
        let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.ts.net/wovenmatter")!)
        let workspaceID = try await fixture.database.companionWorkspaceID()
        let paired = try await auth.pair(.init(token: offer.payload.token, deviceID: fixture.device,
            deviceName: "Fixture phone", protocolVersion: CompanionProtocol.version), workspaceID: workspaceID)
        let api = CompanionWorkspaceAPI(database: fixture.database, authentication: auth,
            commands: fixture.model.companionCommands, isActive: { true })
        let call: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1),
            "method": .string("tools/call"), "params": .object(["name": .string("woven_notes_list"), "arguments": .object([:])])])
        var headers = ["x-woven-protocol": String(CompanionProtocol.version), "x-woven-workspace": workspaceID,
            "x-woven-conversation-id": caller, "x-woven-enabled-groups": "notes"]
        #expect(await api.handle(.init(method: "POST", target: "/mcp", headers: headers,
            body: try JSONEncoder().encode(call))).status == 401)
        headers["authorization"] = "Bearer " + paired.credential
        let accepted = await api.handle(.init(method: "POST", target: "/wovenmatter/mcp", headers: headers,
            body: try JSONEncoder().encode(call)))
        #expect(accepted.status == 200)
        let result = try JSONDecoder().decode(GatewayJSONValue.self, from: accepted.body)
        #expect(result.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        headers["x-woven-conversation-id"] = try await fixture.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Unrelated Mac chat", ownerDeviceID: UUID())
        #expect(await api.handle(.init(method: "POST", target: "/mcp", headers: headers,
            body: try JSONEncoder().encode(call))).status == 403)
        headers["x-woven-conversation-id"] = caller
        try await auth.revoke(deviceID: fixture.device)
        #expect(await api.handle(.init(method: "POST", target: "/mcp", headers: headers,
            body: try JSONEncoder().encode(call))).status == 401)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }

    @Test func companionToolRevocationFencesAutomationEvenAfterReenable() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        fixture.model.clientExecutionDirectory = fixture.directory
        let caller = try await fixture.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Mac caller", ownerDeviceID: UUID())
        try await fixture.database.setSessionTools(.init(enabled: [.browser, .computer]), sessionID: caller)
        let call = WovenMatterToolRequest(arguments: ["browser", "call", "--json", "{\"action\":\"tabs\"}"])
        let tools = try #require(fixture.model.agentTools)
        #expect(await tools.handle(call, callerID: caller).success)
        for enabled in [["browser"], ["browser", "computer"]] {
            let command = CompanionCommand(deviceID: fixture.device, kind: .workspace,
                workspaceAction: .sessionTools(id: caller, enabled: enabled, confirmPausingTimers: true))
            #expect(try await fixture.model.companionCommands.execute(command, deviceID: fixture.device).status == .completed)
        }
        #expect(try await fixture.database.sessionTools(caller).enabled.contains(.computer))
        await #expect(throws: (any Error).self) {
            try await fixture.database.requireAutomationRequest(.browser, callerID: caller, requestID: call.requestID)
        }
    }

    private func importPhone(_ fixture: FacadeFixture) async throws -> String {
        let identity = try await fixture.database.companionLibraryIdentity()
        let caller = UUID().uuidString.lowercased()
        let workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: fixture.device,
            kind: .ios, name: "Phone", executionDeviceID: fixture.device)), deviceID: fixture.device)
        _ = try await fixture.database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: [
            .init(workspaceID: workspace.id, originSequence: 1, conversationID: caller, kind: .conversation,
                  conversation: .init(id: caller, title: "Phone chat", runtimeKind: "piDurable"))
        ]), deviceID: fixture.device)
        return caller
    }
}
