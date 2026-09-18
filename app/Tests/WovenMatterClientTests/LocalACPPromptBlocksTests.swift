import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct LocalACPPromptBlocksTests {
  @Test func stagedPDFEmitsResourceLinkAndWorkspacePaths() throws {
    let localURL = try writeTempFile(Data("%PDF-fixture".utf8), name: "report.pdf")
    defer { try? FileManager.default.removeItem(at: localURL) }
    let remotePath = "/home/.woven-matter/.wovenmatter/attachments/h/report.pdf"
    let input = AgentMessageInput(text: "Read the report", attachments: [.file(
      AgentFileAttachmentDraft(
        kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
        sizeBytes: 12, contentHash: "h", localURL: localURL, remotePath: remotePath
      )
    )])
    let blocks = try LocalACPClient.promptBlocks(input, text: nil).arrayValue ?? []
    #expect(blocks.count == 2)
    #expect(blocks[0]["type"]?.stringValue == "text")
    let text = try #require(blocks[0]["text"]?.stringValue)
    #expect(text.contains("Read the report"))
    #expect(text.contains("Attached files in this workspace:"))
    #expect(text.contains(remotePath))
    #expect(blocks[1]["type"]?.stringValue == "resource_link")
    #expect(blocks[1]["uri"]?.stringValue == "file:///home/.woven-matter/.wovenmatter/attachments/h/report.pdf")
    #expect(blocks[1]["name"]?.stringValue == "report.pdf")
    #expect(blocks[1]["mimeType"]?.stringValue == "application/pdf")
  }

  @Test func unstagedPDFUsesLocalURIAndOmitsWorkspacePaths() throws {
    let localURL = try writeTempFile(Data("%PDF-fixture".utf8), name: "report.pdf")
    defer { try? FileManager.default.removeItem(at: localURL) }
    let input = AgentMessageInput(text: "Read the report", attachments: [.file(
      AgentFileAttachmentDraft(
        kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
        sizeBytes: 12, contentHash: "h", localURL: localURL
      )
    )])
    let blocks = try LocalACPClient.promptBlocks(input, text: nil).arrayValue ?? []
    #expect(blocks.count == 2)
    let text = try #require(blocks[0]["text"]?.stringValue)
    #expect(text == "Read the report")
    #expect(!text.contains("Attached files in this workspace:"))
    #expect(blocks[1]["type"]?.stringValue == "resource_link")
    #expect(blocks[1]["uri"]?.stringValue == localURL.absoluteString)
    #expect(blocks[1]["name"]?.stringValue == "report.pdf")
  }

  @Test func stagedImageStillEmbedsLocalBase64() throws {
    let png = Data([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])
    let localURL = try writeTempFile(png, name: "dot.png")
    defer { try? FileManager.default.removeItem(at: localURL) }
    let input = AgentMessageInput(text: "Look", attachments: [.file(
      AgentFileAttachmentDraft(
        kind: .image, fileName: "dot.png", mimeType: "image/png",
        sizeBytes: Int64(png.count), contentHash: "h", localURL: localURL,
        remotePath: "/home/.woven-matter/.wovenmatter/attachments/h/dot.png"
      )
    )])
    let blocks = try LocalACPClient.promptBlocks(input, text: nil).arrayValue ?? []
    let image = try #require(blocks.first { $0["type"]?.stringValue == "image" })
    #expect(image["mimeType"]?.stringValue == "image/png")
    #expect(image["data"]?.stringValue == png.base64EncodedString())
    // Inlined content needs no path hint.
    #expect(blocks[0]["text"]?.stringValue == "Look")
  }

  @Test func stagedTextIsInlinedUnderItsWorkspaceURI() throws {
    let localURL = try writeTempFile(Data("hello".utf8), name: "notes.txt")
    defer { try? FileManager.default.removeItem(at: localURL) }
    let remotePath = "/home/.woven-matter/.wovenmatter/attachments/h/notes.txt"
    let input = AgentMessageInput(text: "Read", attachments: [.file(
      AgentFileAttachmentDraft(
        kind: .file, fileName: "notes.txt", mimeType: "text/plain",
        sizeBytes: 5, contentHash: "h", localURL: localURL, remotePath: remotePath
      )
    )])
    let blocks = try LocalACPClient.promptBlocks(input, text: nil).arrayValue ?? []
    #expect(blocks[0]["text"]?.stringValue == "Read")
    let resource = try #require(blocks[1]["resource"])
    #expect(blocks[1]["type"]?.stringValue == "resource")
    #expect(resource["uri"]?.stringValue == "file://" + remotePath)
    #expect(resource["text"]?.stringValue == "hello")
  }

  private func writeTempFile(_ bytes: Data, name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + name)
    try bytes.write(to: url)
    return url
  }
}
