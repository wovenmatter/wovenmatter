import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite struct DurableACPUncertaintyTests {
    @Test(arguments: [false, true])
    func unknownReceiptSurvivesRestartUntilScopedRecovery(hasTerminalSnapshot: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "durable-uncertain-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let workspaceID = UUID()
        let conversation = try await database.createRemoteACPSession(runtimeKind: .codex,
            remoteWorkspaceID: workspaceID, remoteWorkspaceName: "Fixture", title: "Remote", ownerDeviceID: UUID())
        let run = try await database.beginLocalACPRun(conversationID: conversation, content: "first")
        // The allocated identity becomes durable before the first native claim.
        try await database.registerDurableLocalACPRun(runID: run.runID, remoteWorkspaceID: workspaceID, sessionID: "native")
        #expect(try await database.localACPSession(conversationID: conversation).acpSessionID == "native")
        try await database.recoverInterruptedLocalACPRuns()
        #expect(try await database.conversationContent(id: conversation).runs.first?.status == "uncertain")
        #expect(try await database.activeDeviceOwnedConversationIDs().contains(conversation))
        await #expect(throws: LocalACPSessionDatabaseError.runAlreadyActive) {
            try await database.beginLocalACPRun(conversationID: conversation, content: "duplicate")
        }
        let terminal = [DefaultAgentRunSnapshot(runID: run.runID, content: "recovered", error: nil)]
        // An unfenced response (possibly the original turn before a delayed
        // continuation) cannot settle uncertainty, even with the same run ID.
        try await database.recoverRemoteAgentRuns(conversationID: conversation, snapshots: terminal)
        #expect(try await database.conversationContent(id: conversation).runs.first?.status == "uncertain")
        try await database.reconcileUncertainRemoteRuns(conversationID: conversation,
            remoteWorkspaceID: workspaceID, sessionID: "another-native-session", snapshots: terminal)
        #expect(try await database.conversationContent(id: conversation).runs.first?.status == "uncertain")
        await #expect(throws: LocalACPSessionDatabaseError.sessionNotFound) {
            try await database.reconcileUncertainRemoteRuns(conversationID: conversation,
                remoteWorkspaceID: UUID(), sessionID: "native", snapshots: terminal)
        }
        try await database.reconcileUncertainRemoteRuns(conversationID: conversation,
            remoteWorkspaceID: workspaceID, sessionID: "native", snapshots: hasTerminalSnapshot ? terminal : [])
        let recovered = try await database.conversationContent(id: conversation)
        #expect(recovered.runs.first?.status == (hasTerminalSnapshot ? "completed" : "failed"))
        #expect(try await !database.activeDeviceOwnedConversationIDs().contains(conversation))
        if hasTerminalSnapshot { #expect(recovered.messages.last?.content == "recovered") }
        _ = try await database.beginLocalACPRun(conversationID: conversation, content: "new input")
    }

    @Test func unmarkedLegacyOrForegroundRemoteRunKeepsPriorStartupPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "foreground-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let conversation = try await database.createRemoteACPSession(runtimeKind: .codex,
            remoteWorkspaceID: UUID(), remoteWorkspaceName: "Fixture", title: "Foreground", ownerDeviceID: UUID())
        _ = try await database.beginLocalACPRun(conversationID: conversation, content: "input")
        try await database.recoverInterruptedLocalACPRuns()
        #expect(try await database.conversationContent(id: conversation).runs.first?.status == "failed")
    }

    @Test func legacyRemoteBuiltInWithExactSavedIdentityIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "legacy-built-in-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let conversation = try await database.createRemoteACPSession(runtimeKind: .defaultAgent,
            remoteWorkspaceID: UUID(), remoteWorkspaceName: "Fixture", title: "Built-in", ownerDeviceID: UUID())
        try await database.updateLocalACPSessionID(conversationID: conversation, sessionID: "saved-native")
        _ = try await database.beginLocalACPRun(conversationID: conversation, content: "input")
        try await database.recoverInterruptedLocalACPRuns()
        #expect(try await database.conversationContent(id: conversation).runs.first?.status == "uncertain")
    }
}
