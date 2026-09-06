import Foundation
import Testing
@testable import WovenMatterClient

@Suite("ACP pipe reading", .timeLimit(.minutes(1)))
struct ACPLineCursorTests {
  @Test("an idle pipe does not block another session's response")
  func independentPipes() async throws {
    let idle = Pipe()
    let ready = Pipe()
    let release = PipeReadWatchdog(writer: idle.fileHandleForWriting)
    let idleCursor = ACPLineCursor(handle: idle.fileHandleForReading)
    let readyCursor = ACPLineCursor(handle: ready.fileHandleForReading)
    let waiting = Task { try await idleCursor.next() }
    // Give the first read a chance to park before making the other pipe readable.
    try await Task.sleep(for: .milliseconds(100))
    release.arm()
    defer { release.close() }
    try ready.fileHandleForWriting.write(contentsOf: Data("response\n".utf8))
    #expect(try await readyCursor.next() == Data("response".utf8))
    #expect(!release.didExpire, "An unrelated idle pipe blocked a ready response")
    release.close()
    #expect(try await waiting.value == nil)
  }

  @Test("cancelling an idle read completes without waiting for EOF")
  func idleReadCancellation() async throws {
    let pipe = Pipe()
    let release = PipeReadWatchdog(writer: pipe.fileHandleForWriting)
    let cursor = ACPLineCursor(handle: pipe.fileHandleForReading)
    let waiting = Task { try await cursor.next() }
    try await Task.sleep(for: .milliseconds(100))
    release.arm()
    defer { release.close() }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(!release.didExpire, "Cancellation waited for the writer to close")
  }

  @Test("line framing skips empty lines and preserves the last unterminated line")
  func framing() async throws {
    let pipe = Pipe()
    let cursor = ACPLineCursor(handle: pipe.fileHandleForReading)
    try pipe.fileHandleForWriting.write(contentsOf: Data("\nfirst\n\nsecond\nlast".utf8))
    try pipe.fileHandleForWriting.close()
    for expected in ["first", "second", "last"] {
      #expect(try await cursor.next() == Data(expected.utf8))
    }
    #expect(try await cursor.next() == nil)
    #expect(try await cursor.next() == nil)
  }

  @Test("lines spanning read chunks retain every byte")
  func chunkBoundaries() async throws {
    let first = Data(repeating: 0x61, count: 65_549)
    let last = Data("尾\r".utf8)
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try (first + Data("\n\n".utf8) + last).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let cursor = ACPLineCursor(handle: handle)
    #expect(try await cursor.next() == first)
    #expect(try await cursor.next() == last)
    #expect(try await cursor.next() == nil)
  }

  @Test("the line size limit is enforced at the exact boundary", arguments: [false, true])
  func lineSizeLimit(oversized: Bool) async throws {
    let size = ACPLineCursor.maximumLineBytes + (oversized ? 1 : 0)
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try (Data(repeating: 0x61, count: size) + Data([10])).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let cursor = ACPLineCursor(handle: handle)
    if oversized {
      do {
        _ = try await cursor.next()
        Issue.record("Oversized line was accepted")
      } catch LocalACPClientError.lineTooLarge { }
    } else {
      #expect(try await cursor.next()?.count == size)
      #expect(try await cursor.next() == nil)
    }
  }
}

/// A dispatch timer can release a broken blocking read even if Swift's executor stalls.
/// Closing exactly once also prevents the delayed callback from touching a reused fd.
private final class PipeReadWatchdog: @unchecked Sendable {
  private let lock = NSLock()
  private var writer: FileHandle?
  private var expired = false
  init(writer: FileHandle) { self.writer = writer }
  var didExpire: Bool { lock.withLock { expired } }
  func arm() {
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self.close(expired: true) }
  }
  func close(expired: Bool = false) {
    lock.withLock {
      guard let writer else { return }
      self.writer = nil
      self.expired = expired
      try? writer.close()
    }
  }
}
