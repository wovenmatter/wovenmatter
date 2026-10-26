import CryptoKit
import Darwin
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

  @Test("staging validates local bytes and remote confirmation before accepting a quoted path")
  func validatesDraftAndConfirmationBeforeAcceptingQuotedPath() async throws {
    let expected = "/home/.woven-matter/.wovenmatter/attachments/\(Self.hash)/it's fine.pdf"
    let recorder = Recorder(response: "/somewhere/else")
    let stager = RemoteAttachmentStager(runner: recorder.record)
    try await withDraft(named: "it's fine.pdf", bytes: Data("x".utf8)) { draft in
      let malformed = AgentFileAttachmentDraft(kind: draft.kind, fileName: draft.fileName,
        mimeType: draft.mimeType, sizeBytes: draft.sizeBytes, contentHash: "../escape", localURL: draft.localURL)
      await #expect(throws: AgentMessageAttachmentError.self) { try await stager.stage(malformed, in: configuration) }
      #expect(recorder.command == nil)
      try Data("y".utf8).write(to: draft.localURL)
      await #expect(throws: AgentMessageAttachmentError.self) { try await stager.stage(draft, in: configuration) }
      #expect(recorder.command == nil)
      try Data("x".utf8).write(to: draft.localURL)
      await #expect(throws: RemoteWorkspaceClientError.self) { try await stager.stage(draft, in: configuration) }
      recorder.response = expected
      _ = try await stager.stage(draft, in: configuration)
    }
    let command = try #require(recorder.command)
    // Inner quoting closes the path literal; outer quoting re-escapes it for bash -c.
    #expect(command.contains("it'\\''\\'\\'''\\''s fine.pdf"))
  }

  private final class SpawnCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<RemoteWorkspaceProcess.Result, any Error>?
    private var startedPID: pid_t?

    var processID: pid_t? { lock.withLock { startedPID } }

    func install(_ task: Task<RemoteWorkspaceProcess.Result, any Error>) {
      let hasStarted = lock.withLock {
        self.task = task
        return startedPID != nil
      }
      if hasStarted { task.cancel() }
    }

    func processStarted(_ pid: pid_t) {
      let task = lock.withLock {
        startedPID = pid
        return self.task
      }
      task?.cancel()
    }
  }

}
