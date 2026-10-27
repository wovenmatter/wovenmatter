import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@Suite("HTML resource preparation", .serialized)
struct ConversationHTMLResourceTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }


  @Test func missingAndDisguisedFilesAreReportedInPreviewAndRejectedAtPublication() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "secret.png")
    try Data("private text is not an image".utf8).write(to: file)
    let html = "<img src='\(file.path)'><img src='\(root.path)/missing.jpg'>"
    func input(_ action: String) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: ["action": action, "html": html]), as: UTF8.self)
    }
    let preview = try ConversationHTMLResources.prepareJSON(input("preview"))
    #expect(preview.contains("missingImages"))
    #expect(!preview.contains("private text"))
    #expect(throws: (any Error).self) { try ConversationHTMLResources.prepareJSON(input("render")) }
    #expect(ConversationHTMLResources.imageMIME(Data("<?xml version='1.0'?><!--x--><!DOCTYPE svg PUBLIC 'image' 'https://example.invalid/svg.dtd'><svg xmlns='http://www.w3.org/2000/svg'/>".utf8)) == "image/svg+xml")
    #expect(ConversationHTMLResources.imageMIME(Data("<html><svg/></html>".utf8)) == nil)
  }

  @Test func t3SizeBudgetsSurviveStorageAndRequestsRemainScoped() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "large.png")
    var bytes = Data([137,80,78,71,13,10,26,10]); bytes.append(Data(repeating: 0, count: 10 * 1024 * 1024 - bytes.count))
    try bytes.write(to: file)
    let html = try ConversationHTMLResources.prepare("<img src='\(file.path)'>").html
    #expect(html.utf8.count > 10 * 1024 * 1024)
    let page = try ConversationHTMLPage(html: html, title: "Large image", height: 200)
    let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let caller = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Images", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: caller, content: "Images")
    let reference = try await database.publishConversationHTML(page, callerID: caller, requestID: UUID().uuidString)
    let detail = try #require(try await database.conversationActivityDetails(conversationID: caller, runID: run.runID, activityID: "html-render:" + reference.id))
    #expect(try JSONDecoder().decode(ConversationHTMLPage.self, from: Data(try #require(detail.rawOutputJSON).utf8)) == page)
    #expect(WovenMatterToolRequest(arguments: ["html", "call", "--json", "{}"]).maximumEncodedBytes == 40 * 1024 * 1024)
    #expect(WovenMatterToolRequest(arguments: ["notes", "read", "id"]).maximumEncodedBytes == 4 * 1024 * 1024)
    #expect(throws: (any Error).self) { try ConversationHTMLResources.prepare("<img src='\(file.path)'><img src='\(file.path)'>") }
    bytes.append(0); try bytes.write(to: file)
    #expect(throws: (any Error).self) { try ConversationHTMLResources.prepare("<img src='\(file.path)'>") }
  }
}
