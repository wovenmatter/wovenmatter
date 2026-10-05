import Foundation
import Testing
@testable import WovenMatterCore

struct WorkspaceAssetTabsTests {
  @Test func independentCapacityAndStableSelection() throws {
    var tabs = WorkspaceAssetTabs()
    for id in 0..<4 { try tabs.open(.note("n\(id)")) }
    let browsers = (0..<8).map { _ in UUID() }
    for id in browsers { try tabs.open(.browser(id)) }
    #expect(tabs.tabs.count == 12)
    #expect(throws: WorkspaceAssetTabs.Capacity.self) { try tabs.open(.note("extra")) }
    #expect(throws: WorkspaceAssetTabs.Capacity.self) { try tabs.open(.browser(UUID())) }
    #expect(tabs.selected == .browser(browsers.last!))
    try tabs.open(.note("n0")) // Selecting an already open item works at capacity.
    #expect(tabs.tabs.count == 12)
    #expect(tabs.selected == .note("n0"))
    tabs.close(.note("n0"))
    #expect(tabs.selected == .note("n1"))
    try tabs.open(.note("replacement"))
    #expect(tabs.tabs.count == 12)
  }

  @Test func hidingDoesNotDiscardPagesAndLastCloseDismisses() throws {
    var tabs = WorkspaceAssetTabs()
    let browser = WorkspaceAssetTabs.Tab.browser(UUID())
    try tabs.open(browser)
    tabs.hide()
    #expect(!tabs.isPresented)
    #expect(tabs.tabs == [browser])
    tabs.select(browser)
    #expect(tabs.isPresented)
    tabs.close(browser)
    #expect(tabs.tabs.isEmpty && tabs.selected == nil && !tabs.isPresented)
  }

  @Test func addressBarHandlesSearchAndHostsWithoutLaunchingOtherApps() {
    #expect(BrowserAddress.destination(for: "example.com/path")?.absoluteString == "https://example.com/path")
    #expect(BrowserAddress.destination(for: "localhost:8080/test")?.absoluteString == "http://localhost:8080/test")
    #expect(BrowserAddress.destination(for: "https://example.com/a?q=b")?.scheme == "https")
    #expect(BrowserAddress.destination(for: "two words")?.host == "www.google.com")
    for input in ["javascript:alert(1)", "file:///etc/passwd", "mailto:a@example.com", "chrome://settings", ""] {
      #expect(BrowserAddress.destination(for: input) == nil)
    }
  }

  @Test func snapshotIsBoundedMetadataAndSurvivesIPCAndAttachmentStaging() async throws {
    let context = WorkspaceVisibleContext(
      notes: (0..<10).map { .init(id: "n\($0)", title: String(repeating: "a", count: 500), revision: "r1", active: $0 == 0) },
      pages: (0..<12).compactMap { .init(title: "Page \($0)", url: "https://user:password@example.com/page#secret", active: false) })
    #expect(context.notes.count == 4 && context.pages.count == 8)
    #expect(context.notes[0].title.count == 160)
    #expect(context.pages[0].url == "https://example.com/page")
    #expect(WorkspaceVisibleContext.Page(title: "Local", url: "file:///private/document", active: true) == nil)
    let input = AgentMessageInput(text: "hello", visibleWorkspace: context)
    let transported = try JSONDecoder().decode(AgentMessageInput.self, from: JSONEncoder().encode(input))
    let staged = await transported.mappingFiles { $0 }
    #expect(staged.visibleWorkspace == context)
    #expect(staged.text == "hello") // Workspace metadata is not user-visible message text.
    let prompt = staged.transportText(deliveryText: "discovery\nhello")
    #expect(prompt.contains("discovery\nhello"))
    #expect(prompt.contains("\"id\":\"n0\""))
    #expect(!prompt.contains("password"))
    #expect(prompt.components(separatedBy: "Workspace snapshot at send time").count == 2)
    let oldInput = try JSONDecoder().decode(AgentMessageInput.self,
      from: Data(#"{"text":"old","attachments":[]}"#.utf8))
    #expect(oldInput.visibleWorkspace == nil)
    #expect(oldInput.transportText() == "old")
  }
}
