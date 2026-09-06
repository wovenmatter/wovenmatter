import Foundation
import Testing
@testable import WovenMatterClient

@Suite("Runtime discovery and workspace reconciliation")
struct RuntimeDiscoveryAndWorkspaceTests {
  @Test("a refresh snapshots discovery once while later refreshes observe PATH changes")
  func scopedDiscovery() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let preferred = root.appending(path: "preferred")
    let fallback = root.appending(path: "fallback")
    for directory in [preferred, fallback] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for command in ["pi", "opencode"] {
        let executable = directory.appending(path: command)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
      }
    }
    let discovery = SearchDirectoryDiscovery([preferred.path, fallback.path])
    let live = LocalACPRuntimeResolver(executableSearchDirectoriesProvider: { discovery.discover() })
    let snapshot = live.snapshottingExecutableSearchDirectories()
    #expect(discovery.count == 1)
    for _ in 0..<4 {
      let pi = snapshot.resolve(runtimeKind: .pi)
      #expect(pi.launchConfiguration?.executableURL == preferred.appending(path: "pi"))
      #expect(pi.launchConfiguration?.environment["PATH"] == "\(preferred.path):\(fallback.path)")
      #expect(snapshot.resolve(runtimeKind: .opencode).launchConfiguration?.executableURL
        == preferred.appending(path: "opencode"))
    }
    #expect(discovery.count == 1)

    discovery.replace(with: [fallback.path, preferred.path])
    #expect(snapshot.resolve(runtimeKind: .pi).launchConfiguration?.executableURL
      == preferred.appending(path: "pi"))
    let refreshed = live.snapshottingExecutableSearchDirectories()
    #expect(discovery.count == 2)
    #expect(refreshed.resolve(runtimeKind: .pi).launchConfiguration?.executableURL
      == fallback.appending(path: "pi"))
    #expect(live.resolve(runtimeKind: .pi).launchConfiguration?.executableURL
      == fallback.appending(path: "pi"))
    #expect(discovery.count > 2)

    // Snapshot paths, not executable existence: installs remain visible.
    try FileManager.default.removeItem(at: preferred.appending(path: "pi"))
    #expect(snapshot.resolve(runtimeKind: .pi).launchConfiguration?.executableURL
      == fallback.appending(path: "pi"))
  }

  @Test("repository and database links preserve existing files and exact errors", arguments: [false, true])
  func directoryReconciliation(databases: Bool) throws {
    let fixture = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let root = fixture.appending(path: "workspace")
    let first = fixture.appending(path: "first")
    let second = fixture.appending(path: "second")
    for directory in [first, second] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("preserve".utf8).write(to: directory.appending(path: "existing"))
    }
    func configure(_ external: URL?) throws {
      _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(
        at: root,
        repositoriesURL: databases ? nil : external,
        databasesURL: databases ? external : nil
      )
    }
    let link = root.appending(path: databases ? "Databases" : "REPOS")
    try configure(nil)
    let marker = link.appending(path: "keep")
    try Data("keep".utf8).write(to: marker)
    let nonempty: LocalACPWorkspaceError = databases ? .defaultDatabasesNotEmpty : .defaultRepositoriesNotEmpty
    #expect(throws: nonempty) { try configure(first) }
    #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    try FileManager.default.removeItem(at: marker)
    let missing: LocalACPWorkspaceError = databases ? .databasesDirectoryUnavailable : .repositoriesDirectoryUnavailable
    #expect(throws: missing) { try configure(fixture.appending(path: "missing")) }
    let ancestor: LocalACPWorkspaceError = databases ? .databasesDirectoryContainsWorkspace : .repositoriesDirectoryContainsWorkspace
    #expect(throws: ancestor) { try configure(fixture) }
    try configure(first)
    #expect(link.resolvingSymlinksInPath() == first.resolvingSymlinksInPath())
    try configure(first)
    try configure(second)
    #expect(link.resolvingSymlinksInPath() == second.resolvingSymlinksInPath())
    #expect(try Data(contentsOf: first.appending(path: "existing")) == Data("preserve".utf8))
    try FileManager.default.removeItem(at: second)
    // The shared initializer rejects a dangling directory before reconciliation.
    #expect(throws: LocalACPWorkspaceError.self) { try configure(first) }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == second.path)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try configure(first)
    try configure(nil)
    #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true)
    #expect(try Data(contentsOf: first.appending(path: "existing")) == Data("preserve".utf8))
  }
}

private final class SearchDirectoryDiscovery: @unchecked Sendable {
  private let lock = NSLock()
  private var directories: [String]
  private var calls = 0

  init(_ directories: [String]) { self.directories = directories }
  var count: Int { lock.withLock { calls } }
  func replace(with directories: [String]) { lock.withLock { self.directories = directories } }
  func discover() -> [String] {
    lock.withLock {
      calls += 1
      return directories
    }
  }
}
