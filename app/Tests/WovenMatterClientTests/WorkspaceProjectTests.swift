import Foundation
import Testing
@testable import WovenMatterClient

@Suite("Blank project roots")
struct WorkspaceProjectTests {
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
