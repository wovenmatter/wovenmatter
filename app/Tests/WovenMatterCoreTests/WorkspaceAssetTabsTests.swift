import Foundation
import Testing
@testable import WovenMatterCore

struct WorkspaceAssetTabsTests {


  @Test func snapshotIsBoundedMetadataAndSurvivesIPCAndAttachmentStaging() async throws {
    let context = WorkspaceVisibleContext(
      notes: (0..<10).map { .init(id: "n\($0)", title: String(repeating: "a", count: 500), revision: "r1", active: $0 == 0) },
      pages: (0..<12).compactMap { .init(title: "Page \($0)", url: "https://user:password@example.com/page#secret", active: false) })
    #expect(context.notes.count == 4 && context.pages.count == 8)
    #expect(context.notes[0].title.count == 160)
    #expect(context.pages[0].url == "https://example.com/page")
    #expect(WorkspaceVisibleContext.Page(title: "Local", url: "file:///private/document", active: true) == nil)
    let mcpContext = WovenMCPConnection(endpointURL: "http://127.0.0.1:43725/mcp", bearerToken: "fixture", captureID: "captured-input")
    let input = AgentMessageInput(text: "hello", visibleWorkspace: context, mcpContext: mcpContext)
    let transported = try JSONDecoder().decode(AgentMessageInput.self, from: JSONEncoder().encode(input))
    let staged = await transported.mappingFiles { $0 }
    #expect(staged.visibleWorkspace == context)
    #expect(staged.mcpContext == mcpContext)
    #expect(staged.text == "hello") // Workspace metadata is not user-visible message text.
    let prompt = staged.transportText(deliveryText: "discovery\nhello")
    #expect(prompt.contains("discovery\nhello"))
    #expect(prompt.contains("\"id\":\"n0\""))
    #expect(!prompt.contains("password"))
    #expect(!prompt.contains("captured-input")) // CLI transport metadata stays out of the prompt.
    #expect(prompt.components(separatedBy: "Workspace snapshot at send time").count == 2)
    let oldInput = try JSONDecoder().decode(AgentMessageInput.self,
      from: Data(#"{"text":"old","attachments":[]}"#.utf8))
    #expect(oldInput.visibleWorkspace == nil)
    #expect(oldInput.mcpContext == nil)
    #expect(oldInput.transportText() == "old")
  }

}
