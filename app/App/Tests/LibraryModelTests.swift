import WorkspaceFixtures
@testable import WovenMatterAppFacade
import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor
struct LibraryModelTests {

    @Test func backendOpensDraftAttachmentsWithoutCatalogingOrFollowingTheirSourceURL() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await DashboardStore(supportDirectory: root)
        let source = root.appending(path: "Screenshot.png")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        let attachment = try await store.stageMessageAttachment(fileURL: source, mimeType: "image/png")
        guard case let .file(draft) = attachment else { Issue.record("Expected a staged file"); return }
        try FileManager.default.removeItem(at: source)
        let command = BackendLibraryCommand.openAttachment(
            contentHash: draft.contentHash, fileName: draft.fileName, mimeType: draft.mimeType)
        let decoded = try JSONDecoder().decode(BackendLibraryCommand.self, from: JSONEncoder().encode(command))
        let backend = BackendLibraryService(service: store.library)
        let opened = try await #require(backend.execute(decoded).url)
        let prepared = try await LibraryModel(service: store.library).attachmentURL(
            contentHash: draft.contentHash, fileName: draft.fileName, mimeType: draft.mimeType)
        #expect(prepared == opened)
        #expect(opened.lastPathComponent == "Screenshot.png")
        #expect(try Data(contentsOf: opened) == bytes)
        #expect(try await store.database.libraryPage(query: .init(), count: 1).items.isEmpty)
        await #expect(throws: (any Error).self) {
            try await backend.execute(.openAttachment(
                contentHash: "../workspace.sqlite", fileName: "Screenshot.png", mimeType: "image/png"))
        }
    }

    @Test func loadMoreReconcilesNewItemsAndPreservesActionErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let chat = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Library", ownerDeviceID: UUID())
        func add(_ text: String) async throws {
            let run = try await database.beginLocalACPRun(conversationID: chat, content: text)
            try await database.completeLocalACPRun(runID: run.runID)
            try await database.indexLibraryMessages()
        }
        try await add((0..<150).map { "https://example.com/\($0)" }.joined(separator: "\n"))
        let model = LibraryModel(service: LibraryService(database: database))
        await model.load(query: .init())
        #expect(model.items.count == 100)
        #expect(model.hasMore)

        try await add("https://example.com/new-arrival")
        model.error = "No application could open this item."
        await model.load(query: .init(), more: true)
        #expect(model.items.count == 151)
        #expect(Set(model.items.map(\.id)).count == 151)
        #expect(model.items.contains { $0.source.hasSuffix("new-arrival") })
        #expect(!model.hasMore)
        #expect(model.error == "No application could open this item.")

        try await add("https://example.com/another-arrival")
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
