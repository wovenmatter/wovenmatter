import Foundation
import Testing
@testable import WovenMatterClient

@Suite("Blank project roots")
struct WorkspaceProjectTests {
  @Test func scratchDirectoriesStartEmptyAndRetriesKeepFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "scratch/2026-10-14-chat-12345678")
    try LocalACPWorkspaceProvisioner.ensureScratchDirectory(at: directory, in: root)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    try "Keep me".write(to: directory.appending(path: "report.txt"), atomically: true, encoding: .utf8)
    try LocalACPWorkspaceProvisioner.ensureScratchDirectory(at: directory, in: root)
    #expect(try String(contentsOf: directory.appending(path: "report.txt"), encoding: .utf8) == "Keep me")
    #expect(throws: (any Error).self) { try LocalACPWorkspaceProvisioner.createProject(named: "scratch", in: root) }
    let external = root.appending(path: "External")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    let link = root.appending(path: "scratch/linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    #expect(throws: (any Error).self) { try LocalACPWorkspaceProvisioner.ensureScratchDirectory(at: link, in: root) }
    #expect(throws: (any Error).self) { try LocalACPWorkspaceProvisioner.ensureScratchDirectory(at: external, in: root) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
  }

  @Test func legacyProjectReusePreservesFilesAndRejectsLinksAndFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try LocalACPWorkspaceProvisioner.createProject(named: "Existing folder", in: root, reuseExisting: true)
    try "Keep my rules".write(to: directory.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    #expect(try LocalACPWorkspaceProvisioner.createProject(named: "Existing folder", in: root, reuseExisting: true) == directory)
    #expect(try String(contentsOf: directory.appending(path: "AGENTS.md"), encoding: .utf8) == "Keep my rules")
    try FileManager.default.createSymbolicLink(at: root.appending(path: "Link"), withDestinationURL: directory)
    try "Keep my file".write(to: root.appending(path: "File"), atomically: true, encoding: .utf8)
    for name in ["Link", "File", "../escape", "scratch"] {
      #expect(throws: (any Error).self) { try LocalACPWorkspaceProvisioner.createProject(named: name, in: root, reuseExisting: true) }
    }
  }

  @Test func creationIsBlankAndExistingFilesStayUntouched() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "blank-projects-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let resolution = await LocalACPWorkspaceConfigurationStore(homeDirectory: home).resolve()
    let workspace = try #require(resolution.launchConfiguration)
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.rootURL.path).isEmpty)
    let project = try LocalACPWorkspaceProvisioner.createProject(named: "First project", in: workspace.rootURL)
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
    #expect(!workspace.databasesURL.path.hasPrefix(workspace.rootURL.path + "/"))
    let external = home.appending(path: "External")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let instructions = "My project rules\n"
    try instructions.write(to: external.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: external.path)
    _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(at: external)
    #expect(try String(contentsOf: external.appending(path: "AGENTS.md"), encoding: .utf8) == instructions)
    #expect(try FileManager.default.contentsOfDirectory(atPath: external.path) == ["AGENTS.md"])
    #expect((try FileManager.default.attributesOfItem(atPath: external.path)[.posixPermissions] as? NSNumber)?.intValue == 0o750)
    #expect(throws: (any Error).self) { try LocalACPWorkspaceProvisioner.createProject(named: "First project", in: workspace.rootURL) }
    for name in ["../escape", ".hidden", "a/b", "a\\b", "a:b", "bad\0name", ""] {
      #expect(throws: (any Error).self) { try LocalACPWorkspaceProvisioner.createProject(named: name, in: workspace.rootURL) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
  }
}
