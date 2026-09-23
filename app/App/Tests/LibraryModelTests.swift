import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor
struct LibraryModelTests {
    @Test func frontendReadsAuthoritativeCatalogWithoutMaintenance() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "workspace.sqlite")
        let writer = try WorkspaceDatabase(url: url)
        let chat = try writer.createLocalACPSession(runtimeKind: .codex, title: "Library", ownerDeviceID: UUID())
        let run = try writer.beginLocalACPRun(conversationID: chat, content: "https://example.com/item")
        try writer.completeLocalACPRun(runID: run.runID)
        try writer.indexLibraryMessages()
        let reader = try WorkspaceDatabase(url: url, readOnlyProjection: true)
        let model = LibraryModel()
        var commands = 0
        model.synchronize(service: LibraryService(database: reader), locations: [], remoteWorkspace: { _ in
            Issue.record("A frontend must not resolve remote connections.")
            return nil
        }, backendExecutor: { _ in
            commands += 1
            return .init()
        })
        defer { model.stop() }
        await model.synchronizeOnce()
        await model.load(query: .init())
        #expect(model.error == nil)
        #expect(model.items.count == 1)
        #expect(model.revision == (try writer.libraryRevision()))
        #expect(commands == 0)
    }

    @Test func backendLibraryCommandsResolveCatalogIdentities() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let chat = try database.createLocalACPSession(runtimeKind: .codex, title: "Library", ownerDeviceID: UUID())
        let run = try database.beginLocalACPRun(conversationID: chat, content: "https://example.com/item")
        try database.completeLocalACPRun(runID: run.runID)
        try database.indexLibraryMessages()
        let item = try #require(database.libraryPage(query: .init(), count: 1).items.first)
        let backend = BackendLibraryService(service: LibraryService(database: database))
        let result = try await backend.execute(.open(id: item.id))
        #expect(result.url?.absoluteString == "https://example.com/item")
        await #expect(throws: (any Error).self) {
            try await backend.execute(.open(id: "removed"))
        }
    }

    @Test func loadMoreReconcilesNewItemsAndPreservesActionErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let chat = try database.createLocalACPSession(runtimeKind: .codex, title: "Library", ownerDeviceID: UUID())
        func add(_ text: String) throws {
            let run = try database.beginLocalACPRun(conversationID: chat, content: text)
            try database.completeLocalACPRun(runID: run.runID)
            try database.indexLibraryMessages()
        }
        try add((0..<150).map { "https://example.com/\($0)" }.joined(separator: "\n"))
        let model = LibraryModel(service: LibraryService(database: database))
        await model.load(query: .init())
        #expect(model.items.count == 100)
        #expect(model.hasMore)

        try add("https://example.com/new-arrival")
        model.error = "No application could open this item."
        await model.load(query: .init(), more: true)
        #expect(model.items.count == 151)
        #expect(Set(model.items.map(\.id)).count == 151)
        #expect(model.items.contains { $0.source.hasSuffix("new-arrival") })
        #expect(!model.hasMore)
        #expect(model.error == "No application could open this item.")

        try add("https://example.com/another-arrival")
        await model.load(query: .init(), preserveCount: true)
        #expect(model.items.count == 151)
        #expect(model.hasMore)
        var filtered = LibraryQuery()
        filtered.search = "another-arrival"
        await model.load(query: filtered, preserveCount: true)
        #expect(model.items.count == 1)
        #expect(model.items.first?.source.hasSuffix("another-arrival") == true)
        #expect(!model.hasMore)
        #expect(!model.loading)
    }
}
