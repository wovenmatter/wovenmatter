import Foundation
import Testing
import WovenMatterCore

@testable import WovenMatterClient

@Suite("Library transports")
struct LibraryTransportTests {
  @Test("remote links are decoded, quoted, and confined by the generated container reader")
  func remotePaths() async throws {
    #expect(
      try RemoteLibraryFiles.path(source: "sandbox:/mnt/data/my%20report.pdf", root: "/home/.woven-matter")
        == "/mnt/data/my report.pdf")
    #expect(
      try RemoteLibraryFiles.path(source: "report.pdf", root: "/home/.woven-matter") == "/home/.woven-matter/report.pdf"
    )
    #expect(throws: (any Error).self) {
      try RemoteLibraryFiles.path(source: "file://another-host/report.pdf", root: "/home/.woven-matter")
    }
    let reader = RemoteLibraryFiles(runner: { destination, command, input in
      #expect(destination == "user@host.invalid")
      #expect(command.contains("report'\\''s.pdf"))
      #expect(input == nil)
      return Data("file".utf8)
    })
    let config = RemoteWorkspaceConfiguration(
      name: "Remote", workspaceID: "fixture", hostName: "host.invalid", userName: "user")
    #expect(
      try await reader.read(source: "report's.pdf", root: "/home/.woven-matter", configuration: config)
        == Data("file".utf8))
    var invalid = config
    invalid.workspaceID = "escape;touch /tmp/no"
    await #expect(throws: (any Error).self) {
      try await reader.read(source: "a.pdf", root: "/home/.woven-matter", configuration: invalid)
    }
  }

  @Test("remote read script rejects traversal, symlinks and special files without returning bytes")
  func remoteConfinement() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "library-remote-reader-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appending(path: "secret")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
    for source in ["/etc/passwd", link.path, root.path] {
      let process = Process()
      let output = Pipe()
      let errors = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["node", "-e", RemoteLibraryFiles.readScript, "--", source, root.path, "10"]
      process.standardOutput = output
      process.standardError = errors
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(process.terminationStatus != 0)
      #expect(data.isEmpty)
    }
  }

  @Test("ACP documents point at the actual local host path")
  func nativeFileAttachments() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "library-acp-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "report.pdf")
    try Data([1, 2, 3]).write(to: url)
    let acp = try LocalACPClient.promptBlocks(
      .init(
        text: "Read",
        attachments: [
          .file(
            .init(
              kind: .file, fileName: "report.pdf", mimeType: "application/pdf", sizeBytes: 3, contentHash: "hash",
              localURL: url))
        ]))
    #expect(acp.arrayValue?.first?["text"]?.stringValue?.contains(url.path) == true)
  }
}
