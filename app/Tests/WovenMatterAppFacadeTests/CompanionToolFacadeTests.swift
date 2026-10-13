import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionToolFacadeTests {
    @Test(arguments: [false, true])
    func executionPolicyGatesCLITargetButKeepsSharedDataAndOtherWorkspaces(remoteDenied: Bool) async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await importPhone(fixture)
        let identity = try await fixture.database.companionLibraryIdentity()
        let localID = UUID().uuidString.lowercased()
        let remoteID = fixture.remote.id.uuidString.lowercased()
        for (id, kind) in [(localID, CompanionExecutionWorkspace.Kind.mac), (remoteID, .linux)] {
            _ = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
                id: id, libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
                kind: kind, name: "Execution policy fixture", executionDeviceID: kind == .mac ? identity.hostDeviceID : nil)),
                deviceID: identity.hostDeviceID)
        }
        let localChat = try await fixture.database.createLocalACPSession(runtimeKind: .codex, title: "Central", ownerDeviceID: UUID())
        let remoteChat = try await fixture.createConversation(gateway: false)
        let deniedChat = remoteDenied ? remoteChat : localChat
        let allowedChat = remoteDenied ? localChat : remoteChat
        try await fixture.database.setCompanionWorkspaceAccess(deviceID: fixture.device,
            workspaceID: remoteDenied ? remoteID : localID, enabled: false, authorizedBy: identity.hostDeviceID)
        func request(_ arguments: [String]) -> CompanionToolRequest {
            .init(conversationID: caller, request: .init(arguments: arguments), enabledGroups: WorkspaceToolGroup.allCases)
        }
        let scheduledID = try await fixture.database.saveCalendarEvent(draft: .init(title: "Existing scheduled task",
            startsAt: Date(timeIntervalSince1970: 1_900_000_000), task: .init(prompt: "Later",
                configuration: .init(runtimeKind: .codex, workspaceID: remoteDenied ? fixture.remote.id : nil, title: "Later"))), creating: true)
        let scheduled = try await fixture.database.calendarEvent(id: scheduledID, callerID: caller)
        var deniedCalls = [
            request(["sessions", "create", "--workspace", remoteDenied ? remoteID.uppercased() : "local", "--harness", "codex",
                     "--title", "Denied", "--text", "Never execute", "--purpose", "Policy test"]),
            request(["sessions", "send", deniedChat, "--text", "Never execute"]),
            request(["sessions", "manage", deniedChat, "--purpose", "Never control"]),
            request(["calendar", "create", "--title", "Denied schedule", "--starts-at", "2026-12-01T12:00:00Z",
                     "--prompt", "Never execute", "--workspace", remoteDenied ? remoteID : "local", "--harness", "codex"]),
            request(["calendar", "update", scheduledID, "--revision", String(scheduled.calendar.revision), "--title", "Denied change"]),
            request(["calendar", "copy", scheduledID, "--starts-at", "2026-12-02T12:00:00Z"])
        ]
        if !remoteDenied { deniedCalls.append(request(["executor", "execute", "--code", "throw new Error('must not execute')"])) }
        for call in deniedCalls {
            do {
                _ = try await fixture.model.companionCommands.executeTool(call, deviceID: fixture.device)
                Issue.record("Disabled workspace accepted CLI execution")
            } catch let error as CompanionAPIError { #expect(error.code == "execution_disabled") }
        }
        let configure = CompanionCommand(deviceID: fixture.device, kind: .workspace,
            workspaceAction: .configureSession(id: deniedChat, model: "fixture-model", thinking: nil, permission: nil))
        do {
            _ = try await fixture.model.companionCommands.execute(configure, deviceID: fixture.device)
            Issue.record("Disabled workspace accepted session configuration")
        } catch let error as CompanionAPIError { #expect(error.code == "execution_disabled") }
        let legacySchedule = CompanionCommand(deviceID: fixture.device, kind: .workspace,
            workspaceAction: .saveCalendar(id: UUID().uuidString.lowercased(), revision: nil,
                draft: .init(title: "Denied legacy schedule", startsAt: Date(timeIntervalSince1970: 1_900_000_000),
                    task: .init(prompt: "Never execute", runtime: "codex", workspaceID: remoteDenied ? remoteID : nil))))
        do {
            _ = try await fixture.model.companionCommands.execute(legacySchedule, deviceID: fixture.device)
            Issue.record("Disabled workspace accepted legacy scheduled task")
        } catch let error as CompanionAPIError { #expect(error.code == "execution_disabled") }
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(await fixture.recorder.configurations.isEmpty)
        let allowed = try await fixture.model.companionCommands.executeTool(
            request(["sessions", "manage", allowedChat, "--purpose", "Allowed workspace"]), deviceID: fixture.device)
        #expect(allowed.success, "\(allowed.error ?? "")")
        let note = request(["notes", "create", "--title", "Still shared", "--kind", "html"])
        let saved = try await fixture.model.companionCommands.executeTool(note, deviceID: fixture.device)
        #expect(saved.success)
        let replay = try await fixture.model.companionCommands.executeTool(note, deviceID: fixture.device)
        #expect(saved == replay)
        let calendar = try await fixture.model.companionCommands.executeTool(request([
            "calendar", "create", "--title", "Still shared", "--starts-at", "2026-12-01T12:00:00Z"
        ]), deviceID: fixture.device)
        #expect(calendar.success)
        let unscheduled = try await fixture.model.companionCommands.executeTool(request([
            "calendar", "update", scheduledID, "--revision", String(scheduled.calendar.revision), "--regular-event"
        ]), deviceID: fixture.device)
        #expect(unscheduled.success)
        #expect(try await fixture.database.calendarEvent(id: scheduledID, callerID: caller).calendar.task == nil)
        #expect(try await fixture.database.companionSnapshot().notes.count == 1)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }

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
