import CryptoKit
import WorkspaceFixtures
@testable import WovenMatterAppFacade
import Foundation
import Testing
import WovenMatterCore
import WovenMatterLibraryStore

@MainActor
struct LibraryModelTests {

    @Test func backendOpensDraftAttachmentsWithoutCatalogingOrFollowingTheirSourceURL() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await LibraryStore(supportDirectory: root)
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

    /// A chip in a session another machine runs: the background server reads
    /// the file from that machine once, keeps it after it matches its digest,
    /// and opens it as it opens a local chat's attachment.
    @Test func backendOpensAttachmentsOfRemoteSessionsFromTheMachineThatRunsThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await LibraryStore(supportDirectory: root)
        let bytes = Data("fixture image bytes".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        final class Reads: @unchecked Sendable {
            let lock = NSLock(); var values: [(String, LibraryAttachmentReference)] = []; var body: Data
            init(_ body: Data) { self.body = body }
            var count: Int { lock.withLock { values.count } }
        }
        let reads = Reads(bytes)
        let backend = BackendLibraryService(service: store.library) { conversationID, reference in
            reads.lock.withLock { reads.values.append((conversationID, reference)); return reads.body }
        }
        let command = BackendLibraryCommand.openAttachment(contentHash: hash, fileName: "photo.png", mimeType: "image/png",
                                                           remoteConversationID: "remote-chat")
        let decoded = try JSONDecoder().decode(BackendLibraryCommand.self, from: JSONEncoder().encode(command))
        let opened = try #require(try await backend.execute(decoded).url)
        #expect(opened.lastPathComponent == "photo.png")
        #expect(try Data(contentsOf: opened) == bytes)
        #expect(reads.lock.withLock { reads.values.map { $0.0 } } == ["remote-chat"])
        #expect(reads.lock.withLock { reads.values.first?.1.id } == hash)
        // Opened again: from this Mac, with no read.
        #expect(try await backend.execute(decoded).url == opened)
        #expect(reads.count == 1)
        // Damaged bytes are refused and nothing is kept.
        reads.lock.withLock { reads.body = Data("damaged".utf8) }
        let other = String(repeating: "d", count: 64)
        await #expect(throws: (any Error).self) {
            try await backend.execute(.openAttachment(contentHash: other, fileName: "x.txt", mimeType: "text/plain", remoteConversationID: "remote-chat"))
        }
        // A local chat's missing file is never read from elsewhere.
        await #expect(throws: (any Error).self) {
            try await backend.execute(.openAttachment(contentHash: other, fileName: "x.txt", mimeType: "text/plain"))
        }
        #expect(reads.count == 2)
    }

    @Test func loadMoreReconcilesNewItemsAndPreservesActionErrors() async throws {
        let persistence = try PersistenceFixture(); defer { persistence.remove() }
        let database = try await persistence.openDatabase()
        let chat = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Library", ownerDeviceID: UUID())
        func add(_ text: String) async throws {
            let run = try await database.beginLocalACPRun(conversationID: chat, input: .init(text: text))
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
