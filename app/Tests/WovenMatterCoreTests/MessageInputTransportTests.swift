import Foundation
import Testing
import WovenMatterCore

struct MessageInputTransportTests {
  @Test("transport preserves raw text without references and separates file bytes")
  func textAndFiles() {
    let input = AgentMessageInput(text: "  draft \n", attachments: [.file(
      AgentFileAttachmentDraft(
        kind: .file, fileName: "data.txt", mimeType: "text/plain",
        sizeBytes: 1, contentHash: "fixture", localURL: URL(filePath: "/fixture/data.txt")
      )
    )])
    #expect(input.transportText() == "  draft \n")
    #expect(input.transportText(deliveryText: "  override \n") == "  override \n")
  }

  @Test("reference snapshots remain ordered and delivery text replaces only the prompt")
  func referenceContext() {
    let input = AgentMessageInput(text: "original", attachments: [
      .reference(AgentMessageReferenceDraft(
        kind: .note, resourceID: "n", titleSnapshot: "Note title",
        contentSnapshot: "note body", revisionSnapshot: "1"
      )),
      .reference(AgentMessageReferenceDraft(
        kind: .conversation, resourceID: "c", titleSnapshot: "Chat title",
        contentSnapshot: "chat body", revisionSnapshot: "2"
      )),
    ])
    let context = """
      <wovenmatter-reference type="note" id="n" title="Note title">
      note body
      </wovenmatter-reference>

      <wovenmatter-reference type="conversation" id="c" title="Chat title">
      chat body
      </wovenmatter-reference>
      """
    #expect(input.transportText(deliveryText: "  delivered \n") == "delivered\n\n" + context)
    #expect(input.transportText(deliveryText: " \n") == context)
    #expect(input.textWithReferenceContext == "original\n\n" + context)
  }

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
    ])
    let mapped = await input.mappingFiles { file in
      file.staged(at: "/staged/\(file.fileName)")
    }
    #expect(mapped.text == "keep text")
    #expect(input.files.allSatisfy { $0.remotePath == nil })
    #expect(input.attachments == [.file(first), .reference(note), .file(second)])
    #expect(mapped.attachments.map(\.id) == ["file-a", "note-1", "file-b"])
    #expect(mapped.references == [note])
    #expect(mapped.files.map(\.id) == ["file-a", "file-b"])
    #expect(mapped.files.map(\.remotePath) == ["/staged/a.txt", "/staged/b.png"])
    #expect(mapped.files.map(\.contentHash) == ["hash-a", "hash-b"])
    #expect(mapped.files.map(\.fileName) == ["a.txt", "b.png"])
  }

  @Test("staged(at:) keeps id, hash, and name and sets remotePath")
  func stagedAt() {
    let draft = AgentFileAttachmentDraft(
      id: "kept-id", kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
      sizeBytes: 4, contentHash: "kept-hash", localURL: URL(filePath: "/fixture/report.pdf")
    )
    let staged = draft.staged(at: "/home/.woven-matter/.wovenmatter/attachments/h/report.pdf")
    #expect(staged.id == "kept-id")
    #expect(staged.contentHash == "kept-hash")
    #expect(staged.fileName == "report.pdf")
    #expect(staged.kind == .file)
    #expect(staged.mimeType == "application/pdf")
    #expect(staged.sizeBytes == 4)
    #expect(staged.localURL == draft.localURL)
    #expect(staged.remotePath == "/home/.woven-matter/.wovenmatter/attachments/h/report.pdf")
    #expect(draft.remotePath == nil)
  }
}
