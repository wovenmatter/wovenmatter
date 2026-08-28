import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Public source contracts", .serialized)
struct PublicSourceContractsTests {
  @Test("the bundled catalog is complete and executable")
  func harnessCatalog() throws {
    let document = try HarnessCatalog.loadBundled()

    #expect(document.schemaVersion == 4)
    #expect(document.harnesses.map(\.id) == [
      .codex, .claudeCode, .grokBuild, .hermes,
      .cursor, .opencode, .pi, .openclaw,
    ])
    #expect(document.harnesses.allSatisfy { harness in
      !harness.capabilities.isEmpty
        && harness.install.source.scheme == "https"
        && !harness.authentication.statusCommands.isEmpty
        && !harness.authentication.methods.isEmpty
        && (harness.adapterPackage != nil || harness.transportCheckCommand != nil)
    })
  }

  @Test("local records and remote session identity survive reopen")
  func databasePersistence() throws {
    let directory = try TemporaryDirectory(prefix: "wovenmatter-database")
    defer { directory.remove() }
    let databaseURL = directory.url.appending(path: "workspace.sqlite")
    let workspaceID = UUID()
    let ownerDeviceID = UUID()
    let folderID: String
    let noteID: String
    let conversationID: String

    do {
      let database = try WorkspaceDatabase(url: databaseURL)
      folderID = try database.createFolder(name: "Research")
      noteID = try database.createNote(
        folderID: folderID,
        title: "Durable note",
        content: "Remember this"
      )
      conversationID = try database.createRemoteACPSession(
        runtimeKind: .codex,
        remoteWorkspaceID: workspaceID,
        remoteWorkspaceName: "Remote",
        title: "Remote notes",
        ownerDeviceID: ownerDeviceID
      )
    }

    let reopened = try WorkspaceDatabase(url: databaseURL)
    let overview = try reopened.workspaceOverview()
    #expect(overview.folders.map(\.id) == [folderID])
    #expect(overview.notes.map(\.id) == [noteID])
    #expect(try reopened.localACPSession(
      conversationID: conversationID
    ).remoteWorkspaceID == workspaceID)
  }
}

private struct TemporaryDirectory {
  let url: URL

  init(prefix: String) throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: url) }
}
