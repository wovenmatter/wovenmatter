@testable import WovenMatterAppFacade
import Foundation
import UniformTypeIdentifiers
import Testing
import WovenMatterCore

@MainActor
struct DocumentPreviewTests {
    @Test func dragTransfersActualFileOnlyWhenRequested() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Sample.csv")
        let bytes = Data("Name,Amount\nAlpha,10".utf8)
        try bytes.write(to: file)
        var resolutions = 0
        let provider = DocumentAttachmentDrag.provider(filename: file.lastPathComponent, type: .commaSeparatedText,
            resolve: { resolutions += 1; return file }, onError: { Issue.record("Unexpected drag error: \($0)") })
        #expect(resolutions == 0)
        let delivered: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.commaSeparatedText.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CocoaError(.fileNoSuchFile) }
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch { continuation.resume(throwing: error) }
            }
        }
        #expect(resolutions == 1)
        #expect(delivered == bytes)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func reopeningDocumentReusesTabAndReplacesDownloadedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "Report.csv")
        let second = root.appending(path: "Updated.csv")
        try Data("Name,Amount\nAlpha,10".utf8).write(to: first)
        try Data("Name,Amount\nAlpha,20".utf8).write(to: second)
        let session = WorkspaceAssetSession()
        session.openNote("note")
        try session.openDocument(first, identity: "library:item")
        try session.openDocument(first, identity: "another-entry-for-the-same-copy")
        #expect(session.tabs.documentIDs == ["library:item"])
        session.tabs.hide()
        try session.openDocument(second, identity: "library:item")
        #expect(session.tabs.tabs == [.note("note"), .document("library:item")])
        #expect(session.tabs.selected == .document("library:item"))
        #expect(session.tabs.isPresented)
        #expect(session.documents["library:item"] == second)
        #expect(session.title(for: .document("library:item"), notes: []) == "Updated.csv")
        session.close(.document("library:item"))
        #expect(session.documents.isEmpty)
        #expect(session.tabs.selected == .note("note"))
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func invalidFilesDoNotCreateTabsOrReplaceValidPreviews() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Report.txt")
        try Data("Report".utf8).write(to: file)
        let session = WorkspaceAssetSession()
        try session.openDocument(file, identity: "item")
        for invalid in [URL(string: "https://example.com/Report.pdf")!, root, root.appending(path: "missing.pdf")] {
            #expect(throws: (any Error).self) { try session.openDocument(invalid, identity: "item") }
            #expect(session.documents["item"] == file)
            #expect(session.tabs.tabs == [.document("item")])
        }
    }
}
