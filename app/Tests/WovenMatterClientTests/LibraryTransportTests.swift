import Foundation
import Testing
import WovenMatterCore

@testable import WovenMatterClient

@Suite("Library transports")
struct LibraryTransportTests {

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

}
