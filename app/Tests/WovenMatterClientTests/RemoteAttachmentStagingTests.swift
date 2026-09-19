import CryptoKit
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RemoteAttachmentStagingTests {
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    var response: String
    private(set) var destination: String?
    private(set) var command: String?
    private(set) var input: Data?
    init(response: String) { self.response = response }
    func record(_ destination: String, _ command: String, _ input: Data?) -> Data {
      lock.lock(); defer { lock.unlock() }
      self.destination = destination
      self.command = command
      self.input = input
      return Data(response.utf8)
    }
  }

  private static let hash = SHA256.hash(data: Data("x".utf8)).map { String(format: "%02x", $0) }.joined()
  private let configuration = RemoteWorkspaceConfiguration(
    name: "Work", workspaceID: "work-1", hostName: "linux-box", userName: "woven"
  )

  private func withDraft<T>(
    named name: String, bytes: Data, hash: String = hash,
    _ body: (AgentFileAttachmentDraft) async throws -> T
  ) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(AgentFileAttachmentDraft(
      kind: .file, fileName: name, mimeType: "application/pdf",
      sizeBytes: Int64(bytes.count), contentHash: hash, localURL: url
    ))
  }

  @Test("the file travels on stdin to docker exec and the confirmed path is returned")
  func stagesOverSSH() async throws {
    let expected = "/home/.woven-matter/.wovenmatter/attachments/\(Self.hash)/Q3 report.pdf"
    let recorder = Recorder(response: expected)
    let stager = RemoteAttachmentStager(runner: recorder.record)

    let path = try await withDraft(named: "Q3 report.pdf", bytes: Data("x".utf8)) { draft in
      #expect(try RemoteAttachmentStager.containerPath(for: draft) == expected)
      return try await stager.stage(draft, in: configuration)
    }

    #expect(path == expected)
    #expect(recorder.destination == "woven@linux-box")
    #expect(recorder.input == Data("x".utf8))
    let command = try #require(recorder.command)
    #expect(command.hasPrefix("'docker' 'exec' '--interactive' 'wovenmatter-work-1' 'bash' '-c' "))
    #expect(command.contains("n=1"))
    #expect(command.contains("if matches \"$p\"; then cat >/dev/null"))
    #expect(command.contains("cat >\"$t\""))
    #expect(command.contains("mv -f \"$t\" \"$p\""))
  }

  @Test("a quote in the file name survives both layers of shell quoting")
  func quotesNestedShellArguments() async throws {
    let expected = "/home/.woven-matter/.wovenmatter/attachments/\(Self.hash)/it's fine.pdf"
    let recorder = Recorder(response: expected)
    let stager = RemoteAttachmentStager(runner: recorder.record)
    _ = try await withDraft(named: "it's fine.pdf", bytes: Data("x".utf8)) { try await stager.stage($0, in: configuration) }
    let command = try #require(recorder.command)
    // Inner quoting closes the path literal; outer quoting re-escapes it for bash -c.
    #expect(command.contains("it'\\''\\'\\'''\\''s fine.pdf"))
  }

  @Test("a trailing newline in the confirmation is tolerated")
  func trimsConfirmation() async throws {
    let expected = "/home/.woven-matter/.wovenmatter/attachments/\(Self.hash)/notes.pdf"
    let stager = RemoteAttachmentStager(runner: Recorder(response: expected + "\r\n").record)
    let path = try await withDraft(named: "notes.pdf", bytes: Data("x".utf8)) { try await stager.stage($0, in: configuration) }
    #expect(path == expected)
  }

  @Test("an unexpected reply is an error, not a path")
  func rejectsUnconfirmedPath() async throws {
    let stager = RemoteAttachmentStager(runner: Recorder(response: "/somewhere/else").record)
    await #expect(throws: RemoteWorkspaceClientError.self) {
      try await withDraft(named: "notes.pdf", bytes: Data("x".utf8)) { try await stager.stage($0, in: configuration) }
    }
  }

  @Test("a content hash that is not 64 hex characters never reaches the shell")
  func rejectsMalformedHash() async throws {
    let recorder = Recorder(response: "")
    let stager = RemoteAttachmentStager(runner: recorder.record)
    await #expect(throws: AgentMessageAttachmentError.self) {
      try await withDraft(named: "notes.pdf", bytes: Data("x".utf8), hash: "../escape") {
        try await stager.stage($0, in: configuration)
      }
    }
    #expect(recorder.command == nil)
  }

  @Test("an unreadable local blob is reported as such")
  func reportsUnreadableBlob() async throws {
    let stager = RemoteAttachmentStager(runner: Recorder(response: "").record)
    let draft = AgentFileAttachmentDraft(
      kind: .file, fileName: "gone.pdf", mimeType: "application/pdf", sizeBytes: 1,
      contentHash: Self.hash, localURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )
    await #expect(throws: AgentMessageAttachmentError.unreadableFile("gone.pdf")) {
      try await stager.stage(draft, in: configuration)
    }
  }

  @Test("attachment subprocess deadline terminates a stuck transfer")
  func transferDeadline() throws {
    let start = ProcessInfo.processInfo.systemUptime
    #expect(throws: RemoteWorkspaceClientError.self) {
      try RemoteWorkspaceProcess.run(executable: "/bin/sleep", arguments: ["30"], timeLimit: 0.05)
    }
    #expect(ProcessInfo.processInfo.systemUptime - start < 5)
  }

  @Test("cancelling an attachment subprocess terminates it promptly")
  func transferCancellation() async throws {
    let task = Task.detached {
      try RemoteWorkspaceProcess.run(executable: "/bin/sleep", arguments: ["30"], timeLimit: 60)
    }
    task.cancel()
    let start = ProcessInfo.processInfo.systemUptime
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ProcessInfo.processInfo.systemUptime - start < 5)
  }

  @Test("changed local bytes are rejected before SSH")
  func rejectsChangedBlob() async throws {
    let recorder = Recorder(response: "")
    let stager = RemoteAttachmentStager(runner: recorder.record)
    await #expect(throws: AgentMessageAttachmentError.self) {
      try await withDraft(named: "notes.pdf", bytes: Data("y".utf8)) {
        try await stager.stage($0, in: configuration)
      }
    }
    #expect(recorder.command == nil)
  }

  @Test("staging repairs corruption, cleans partials, and supports maximum-length names",
        arguments: ["it's $(not-a-command).pdf", String(repeating: "a", count: 251) + ".pdf"])
  func executesAtomicStaging(name: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: name)
    let stdin = root.appending(path: "stdin")
    // macOS uses shasum; the container supplies coreutils sha256sum.
    let shim = "sha256sum() { /usr/bin/shasum -a 256; }; "
    func run(_ bytes: String, expectedBytes: Int = 1) throws -> Int32 {
      try Data(bytes.utf8).write(to: stdin)
      let input = try FileHandle(forReadingFrom: stdin)
      defer { try? input.close() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = ["-c", shim + RemoteAttachmentStager.stagingScript(
        path: path.path, byteCount: expectedBytes, hash: Self.hash)]
      process.standardInput = input
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run(); process.waitUntilExit()
      return process.terminationStatus
    }
    #expect(try run("x") == 0)
    #expect(try Data(contentsOf: path) == Data("x".utf8))
    try Data("y".utf8).write(to: path)
    #expect(try run("x") == 0)
    #expect(try Data(contentsOf: path) == Data("x".utf8))
    try Data("y".utf8).write(to: path)
    #expect(try run("") != 0)
    #expect(try Data(contentsOf: path) == Data("y".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".part.") })
  }

  @Test("file names cannot escape the attachment directory or hide their extension")
  func sanitizesFileNames() {
    func name(_ raw: String) -> String {
      RemoteAttachmentStager.fileName(for: AgentFileAttachmentDraft(
        kind: .file, fileName: raw, mimeType: "application/octet-stream",
        sizeBytes: 1, contentHash: Self.hash, localURL: URL(fileURLWithPath: "/tmp/x")
      ))
    }
    #expect(name("../../etc/passwd") == ".._.._etc_passwd")
    #expect(name("a/b\\c.txt") == "a_b_c.txt")
    #expect(name("bad\nname.md") == "bad_name.md")
    #expect(name("it's fine.pdf") == "it's fine.pdf")
    #expect(name("..") == "attachment")
    #expect(name("   ") == "attachment")
  }
}
