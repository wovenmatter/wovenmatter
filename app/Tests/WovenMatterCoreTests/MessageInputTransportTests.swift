import Foundation
import Testing
import WovenMatterCore

struct MessageInputTransportTests {

  @Test("mappingFiles replaces only file drafts and preserves order and references")
  func mappingFiles() async {
    let first = AgentFileAttachmentDraft(
      id: "file-a", kind: .file, fileName: "a.txt", mimeType: "text/plain",
      sizeBytes: 1, contentHash: "hash-a", localURL: URL(filePath: "/fixture/a.txt")
    )
    let note = AgentMessageReferenceDraft(
      id: "note-1", kind: .note, resourceID: "n", titleSnapshot: "Note title",
      contentSnapshot: "note body", revisionSnapshot: "1"
    )
    let second = AgentFileAttachmentDraft(
      id: "file-b", kind: .image, fileName: "b.png", mimeType: "image/png",
      sizeBytes: 2, contentHash: "hash-b", localURL: URL(filePath: "/fixture/b.png")
    )
    let input = AgentMessageInput(text: "keep text", attachments: [
      .file(first), .reference(note), .file(second),
    ], historyDeliveryID: "history-delivery")
    let mapped = await input.mappingFiles { file in
      file.staged(at: "/staged/\(file.fileName)")
    }
    #expect(mapped.text == "keep text")
    #expect(mapped.historyDeliveryID == "history-delivery")
    #expect(input.files.allSatisfy { $0.remotePath == nil })
    #expect(input.attachments == [.file(first), .reference(note), .file(second)])
    #expect(mapped.attachments.map(\.id) == ["file-a", "note-1", "file-b"])
    #expect(mapped.references == [note])
    #expect(mapped.files.map(\.id) == ["file-a", "file-b"])
    #expect(mapped.files.map(\.remotePath) == ["/staged/a.txt", "/staged/b.png"])
    #expect(mapped.files.map(\.contentHash) == ["hash-a", "hash-b"])
    #expect(mapped.files.map(\.fileName) == ["a.txt", "b.png"])
  }

}
