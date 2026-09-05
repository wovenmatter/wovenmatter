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
}
