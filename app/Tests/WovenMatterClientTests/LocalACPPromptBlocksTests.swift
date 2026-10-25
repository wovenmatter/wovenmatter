import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct LocalACPPromptBlocksTests {
  @Test(arguments: [false, true])
  func PDFResourceLinkUsesItsAvailablePath(staged: Bool) throws {
    let localURL = try writeTempFile(Data("%PDF-fixture".utf8), name: "report.pdf")
    defer { try? FileManager.default.removeItem(at: localURL) }
    let remotePath = "/home/.woven-matter/.wovenmatter/attachments/h/report.pdf"
    let path = staged ? remotePath : localURL.path
    let input = AgentMessageInput(text: "Read the report", attachments: [.file(
      AgentFileAttachmentDraft(
        kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
        sizeBytes: 12, contentHash: "h", localURL: localURL, remotePath: staged ? remotePath : nil
      )
    )])
    let blocks = try LocalACPClient.promptBlocks(input, text: nil).arrayValue ?? []
    #expect(blocks.count == 2)
    #expect(blocks[0]["type"]?.stringValue == "text")
    let text = try #require(blocks[0]["text"]?.stringValue)
    #expect(text.contains("Read the report"))
    #expect(text.contains("Attached files available to this session:"))
    #expect(text.contains(path))
    if staged { #expect(!text.contains(localURL.path)) }
    #expect(blocks[1]["type"]?.stringValue == "resource_link")
    #expect(blocks[1]["uri"]?.stringValue == URL(fileURLWithPath: path).absoluteString)
    #expect(blocks[1]["name"]?.stringValue == "report.pdf")
    #expect(blocks[1]["mimeType"]?.stringValue == "application/pdf")
  }

  private func writeTempFile(_ bytes: Data, name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + name)
    try bytes.write(to: url)
    return url
  }
}
