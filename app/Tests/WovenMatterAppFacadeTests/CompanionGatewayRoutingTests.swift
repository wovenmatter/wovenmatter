import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionGatewayRoutingTests {
    @Test func remoteGatewayCreationPreservesOriginAndWorkspaceDefaults() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let agentID = try await fixture.store.ensureRemoteHarnessAgent(runtimeKind: .openclaw,
            remoteWorkspaceID: fixture.remote.id, remoteWorkspaceName: fixture.remote.name)
        try fixture.database.saveOpenClawGatewayLink(.init(agentID: agentID, location: .remoteWorkspace,
            endpoint: .init(url: URL(string: "ws://127.0.0.1:1")!, authorization: .remoteWorkspace),
            status: OpenClawGatewayConnectionStatus.ready.rawValue))
        try await fixture.model.configureCompanionFixture(directory: fixture.directory)
        let remoteScope = "remote:" + fixture.remote.id.uuidString.lowercased()
        let remoteDefaults = SessionSelections(model: "remote-model", thinking: "high", permission: "full", tools: ["history"])
        fixture.model.sessionSelectionPreferences.saveDefaults(remoteDefaults, harness: "openclaw", workspace: remoteScope)
        fixture.model.sessionSelectionPreferences.saveDefaults(.init(model: "mac-only-model", tools: ["notes"]),
            harness: "openclaw", workspace: "local:" + fixture.directory.standardizedFileURL.path)
        let folderID = try fixture.database.createFolder(name: "Remote work")
        let conversationID = UUID().uuidString.lowercased()
        let command = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: conversationID, providerID: "gateway:" + agentID.uuidString.lowercased(), folderID: folderID)
        let receipt = try await fixture.model.companionCommands.execute(command, deviceID: fixture.device)
        #expect(receipt.status == .completed, "\(receipt.message ?? "No receipt error")")
        #expect(receipt.conversationID == conversationID)
        let session = try fixture.database.localACPSession(conversationID: conversationID)
        #expect(session.remoteWorkspaceID == fixture.remote.id)
        #expect(session.buzzWorkspaceLinkID == nil && session.buzzAgentID == nil)
        let conversation = try #require(try fixture.database.workspaceOverview().conversations.first { $0.id == conversationID })
        #expect(conversation.agentID == agentID.uuidString.lowercased() && conversation.folderID == folderID)
        let gateway = try fixture.database.openClawGatewaySession(conversationID: conversationID)
        #expect(gateway.agentID == agentID)
        let captured = try #require(fixture.model.sessionSelectionPreferences.conversation(id: conversationID))
        #expect(captured.workspace == remoteScope && captured.desiredSelections == remoteDefaults)
        #expect(!captured.requiresApplication && captured.selections.model == "remote-model")
        #expect(try fixture.database.sessionTools(conversationID).enabled == [.history])
        // Main's remote route attaches its native key. It must never create a
        // remote gateway session with this Mac's filesystem working directory.
        #expect(await fixture.recorder.gatewayCreations.isEmpty)
        let send = CompanionCommand(deviceID: fixture.device, kind: .send, conversationID: conversationID, text: "Use this remote workspace")
        let sent = try await fixture.model.companionCommands.execute(send, deviceID: fixture.device)
        #expect(sent.status == .completed, "\(sent.message ?? "No send error")")
        let delivery = try #require(await fixture.recorder.deliveries.first)
        #expect(delivery.route == .gateway)
        #expect(delivery.delivery?.contains("unset WOVENMATTER_SOCKET") == true)
        #expect(delivery.delivery?.contains("/fixture/remote/wovenmatter") == true)
        #expect(try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) == receipt)
        #expect(try fixture.database.workspaceOverview().conversations.count == 1)
        #expect(await fixture.recorder.gatewayCreations.isEmpty)
        let runID = try #require(sent.runID)
        try await fixture.model.companionCommands.stop(conversationID: conversationID, runID: runID)
    }

    @Test func deletedFolderDuringNativeGatewayCreationCannotLeaveLocalSession() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let folderID = try fixture.database.createFolder(name: "Deleted during native creation")
        let conversationID = UUID().uuidString.lowercased()
        let command = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: conversationID, providerID: fixture.providerID("gateway"), folderID: folderID)
        await fixture.recorder.holdGatewayCreation()
        let pending = Task { try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) }
        do {
            try await fixture.recorder.waitForGatewayCreation()
            #expect(try fixture.database.workspaceOverview().conversations.isEmpty)
            let native = try #require(await fixture.recorder.gatewayCreations.first)
            #expect(native.agentID == fixture.gatewayID && native.recover)
            #expect(native.directory == fixture.directory)
            #expect(native.key.hasSuffix(":" + conversationID))
            _ = try fixture.database.deleteFolder(id: folderID)
        } catch {
            await fixture.recorder.releaseGatewayCreation()
            _ = try? await pending.value
            throw error
        }
        await fixture.recorder.releaseGatewayCreation()
        let receipt = try await pending.value
        #expect(receipt.status == .rejected)
        #expect(try fixture.database.workspaceOverview().conversations.isEmpty)
        #expect(await fixture.recorder.configurations.isEmpty)
        #expect(try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) == receipt)
        #expect(await fixture.recorder.gatewayCreations.count == 1)
        #expect(try fixture.database.workspaceOverview().conversations.isEmpty)
    }

    @Test func localGatewayCapturesDefaultsBeforeNativeCreationAwaits() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let localScope = "local:" + fixture.directory.standardizedFileURL.path
        let initialDefaults = SessionSelections(model: "captured-before-create", thinking: "high",
            permission: "fixture-permission", tools: ["history"])
        fixture.model.sessionSelectionPreferences.saveDefaults(initialDefaults, harness: "openclaw", workspace: localScope)
        let folderID = try fixture.database.createFolder(name: "Gateway work")
        let conversationID = UUID().uuidString.lowercased()
        let command = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: conversationID, providerID: fixture.providerID("gateway"), folderID: folderID)
        await fixture.recorder.holdGatewayCreation()
        let pending = Task { try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) }
        do {
            try await fixture.recorder.waitForGatewayCreation()
            #expect(try fixture.database.workspaceOverview().conversations.isEmpty)
            fixture.model.sessionSelectionPreferences.saveDefaults(.init(model: "changed-during-create", tools: ["notes"]),
                harness: "openclaw", workspace: localScope)
        } catch {
            await fixture.recorder.releaseGatewayCreation()
            _ = try? await pending.value
            throw error
        }
        await fixture.recorder.releaseGatewayCreation()
        let receipt = try await pending.value
        #expect(receipt.status == .completed, "\(receipt.message ?? "No receipt error")")
        let captured = try #require(fixture.model.sessionSelectionPreferences.conversation(id: conversationID))
        #expect(captured.workspace == localScope && captured.desiredSelections == initialDefaults)
        #expect(!captured.requiresApplication && captured.selections.model == initialDefaults.model)
        #expect(try fixture.database.sessionTools(conversationID).enabled == [.history])
        let configurations = await fixture.recorder.configurations
        #expect(configurations.count == 1 && configurations.first?.selections.model == initialDefaults.model)
        #expect(try fixture.database.workspaceOverview().conversations.first?.folderID == folderID)
        let session = try fixture.database.localACPSession(conversationID: conversationID)
        #expect(session.remoteWorkspaceID == nil && session.buzzWorkspaceLinkID == nil)
        #expect(try fixture.database.openClawGatewaySession(conversationID: conversationID).agentID == fixture.gatewayID)
        #expect(try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) == receipt)
        #expect(await fixture.recorder.configurations.count == 1)
        #expect(await fixture.recorder.gatewayCreations.count == 1)
    }
}
