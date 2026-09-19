import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

@MainActor
struct WorkspaceAgentToolsServiceTests {
    @Test func folderSearchIgnoresItsOwnRequestJournalAndRetainsExplicitAuditAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let local = try database.createFolder(name: "Caller folder")
        let elsewhere = try database.createFolder(name: "Other folder")
        let caller = try database.createLocalACPSession(runtimeKind: .codex, title: "Caller", ownerDeviceID: UUID())
        let target = try database.createLocalACPSession(runtimeKind: .pi, title: "Relevant work", ownerDeviceID: UUID())
        _ = try database.moveConversation(id: caller, toFolderID: local)
        _ = try database.moveConversation(id: target, toFolderID: elsewhere)
        try database.recordHistory(.init(id: "actual-result", conversationID: target, harness: "pi",
            kind: "wire.in", payload: "rare-search-phrase in the other folder"))
        let service = try WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { service.stop() }
        let endpoint = try service.endpoint(for: caller)
        func request(_ arguments: [String]) async throws -> WovenMatterToolResponse {
            let data = try JSONEncoder().encode(WovenMatterToolRequest(arguments: arguments))
            let response = try await Task.detached { try WovenMatterCommandLine.forward(data, to: endpoint) }.value
            return try JSONDecoder().decode(WovenMatterToolResponse.self, from: response)
        }
        // Repeat through the actual bound socket handler: both this request and
        // earlier request journals must not manufacture a caller-folder hit.
        for _ in 0..<2 {
            let response = try await request(["history", "search", "rare-search-phrase"])
            #expect(response.success)
            #expect(response.result?.objectValue?["scope"]?.stringValue == "workspace")
            let rows = response.result?.objectValue?["rows"]?.arrayValue ?? []
            #expect(rows.count == 1)
            #expect(rows.first?.objectValue?["id"]?.stringValue == "actual-result")
        }
        let audit = try await request(["history", "events", "--conversation", caller, "--kind", "cli.request"])
        #expect(audit.success)
        #expect((audit.result?.objectValue?["rows"]?.arrayValue?.count ?? 0) >= 2)
        let explicitAudit = try await request(["history", "search", "rare-search-phrase", "--kind", "cli.request"])
        #expect(explicitAudit.result?.objectValue?["scope"]?.stringValue == "folder")
        #expect(explicitAudit.result?.objectValue?["rows"]?.arrayValue?.isEmpty == false)
        try database.recordHistory(.init(id: "local-result", conversationID: caller, harness: "codex",
            kind: "wire.in", payload: "rare-search-phrase now exists locally"))
        let localResponse = try await request(["history", "search", "rare-search-phrase"])
        #expect(localResponse.result?.objectValue?["scope"]?.stringValue == "folder")
        #expect(localResponse.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["id"]?.stringValue == "local-result")
    }
}
