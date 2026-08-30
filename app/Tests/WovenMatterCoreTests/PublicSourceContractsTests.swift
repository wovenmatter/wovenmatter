import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Public source contracts", .serialized)
struct PublicSourceContractsTests {
  @Test("usage gateway supports only the approved account providers")
  func usageGatewayProviders() {
    #expect(ProviderKind.supportedAccounts == [
      .codex,
      .claude,
      .grok,
      .cursor,
      .openCodeGo,
      .openRouter,
    ])
  }

  @Test("usage account checks stay passive until providers are enabled")
  func passiveUsageAccounts() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accounts = await ProviderLimitCollector.collect(
      homeDirectory: FileManager.default.temporaryDirectory,
      openRouterAPIKey: nil,
      enabledProviders: [],
      now: now
    )

    #expect(accounts.map(\.provider) == ProviderKind.supportedAccounts)
    #expect(accounts.allSatisfy { $0.source == "Not enabled" })
    #expect(accounts.allSatisfy {
      $0.detail.contains("before Woven Matter checks")
    })
  }

  @Test("enabling one usage account does not probe the others")
  func scopedUsageAccountEnablement() async throws {
    let directory = try TemporaryDirectory(prefix: "wovenmatter-usage-consent")
    defer { directory.remove() }
    let accounts = await ProviderLimitCollector.collect(
      homeDirectory: directory.url,
      openRouterAPIKey: nil,
      enabledProviders: [.openCodeGo],
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(accounts.first { $0.provider == .openCodeGo }?.source != "Not enabled")
    #expect(accounts.filter { $0.provider != .openCodeGo }.allSatisfy {
      $0.source == "Not enabled"
    })
  }

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
    #expect(document.harnesses.filter { $0.adapterPackage != nil }.allSatisfy {
      guard let version = $0.minimumAdapterVersion else { return false }
      let parts = version.split(separator: ".", omittingEmptySubsequences: false)
      return parts.count == 3
        && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    })
    #expect(document.harnesses.filter {
      $0.install.kind == "npm-global"
    }.allSatisfy {
      guard let package = $0.install.package,
            let separator = package.lastIndex(of: "@"),
            separator != package.startIndex else { return false }
      let version = package[package.index(after: separator)...]
      let parts = version.split(separator: ".", omittingEmptySubsequences: false)
      return parts.count == 3
        && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
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
