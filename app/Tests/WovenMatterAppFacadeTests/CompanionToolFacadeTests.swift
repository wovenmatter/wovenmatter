import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionToolFacadeTests {
    @Test func importedPhoneCallerUsesActualCLINotesCalendarAndHistoryWithoutProvider() async throws {
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

    @Test func importedCallerRequiresExplicitCentralSessionDestination() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await importPhone(fixture)
        let source = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == caller })
        let explicit = try WovenMatterToolCommand(["sessions", "create", "--harness", "codex", "--workspace", "local",
            "--title", "Central", "--text", "Work", "--purpose", "Review"])
        let configured = try await fixture.model.resolveToolSessionCreation(source: source, command: explicit, title: "Central")
        #expect(configured.runtimeKind == .codex && configured.workspaceID == nil)
        let implicit = try WovenMatterToolCommand(["sessions", "create", "--harness", "codex",
            "--title", "Central", "--text", "Work", "--purpose", "Review"])
        await #expect(throws: (any Error).self) {
            _ = try await fixture.model.resolveToolSessionCreation(source: source, command: implicit, title: "Central")
        }
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(await fixture.recorder.configurations.isEmpty)
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
        var call = CompanionToolRequest(conversationID: caller, request: .init(arguments: ["notes", "list"]),
            enabledGroups: [.notes])
        var headers = ["x-woven-protocol": String(CompanionProtocol.version), "x-woven-workspace": workspaceID]
        #expect(await api.handle(.init(method: "POST", target: "/v1/tools", headers: headers,
            body: try JSONEncoder().encode(call))).status == 401)
        headers["authorization"] = "Bearer " + paired.credential
        let accepted = await api.handle(.init(method: "POST", target: "/wovenmatter/v1/tools", headers: headers,
            body: try JSONEncoder().encode(call)))
        #expect(accepted.status == 200)
        #expect(try JSONDecoder().decode(WovenMatterToolResponse.self, from: accepted.body).success)
        call.conversationID = try await fixture.database.createLocalACPSession(runtimeKind: .codex, title: "Unrelated Mac chat", ownerDeviceID: UUID())
        #expect(await api.handle(.init(method: "POST", target: "/v1/tools", headers: headers,
            body: try JSONEncoder().encode(call))).status == 403)
        call.conversationID = caller
        try await auth.revoke(deviceID: fixture.device)
        #expect(await api.handle(.init(method: "POST", target: "/v1/tools", headers: headers,
            body: try JSONEncoder().encode(call))).status == 401)
        #expect(await fixture.recorder.deliveries.isEmpty)
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
