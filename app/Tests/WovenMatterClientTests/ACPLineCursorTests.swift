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

  @Test("native archive frames can exceed the ordinary control-frame limit")
  func largeNativeArchiveFrame() async throws {
    let size = ACPLineCursor.maximumLineBytes + 1_024
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try (Data(repeating: 0x61, count: size) + Data([10])).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let cursor = ACPLineCursor(handle: handle, maximumLineBytes: ACPLineCursor.maximumArchiveLineBytes)
    #expect(try await cursor.next()?.count == size)
    #expect(try await cursor.next() == nil)
  }

  @Test("large native frames spool exact bytes and preserve following frames")
  func spooledNativeFrame() async throws {
    let payload = Data(repeating: 0x61, count: ACPLineCursor.spoolThresholdBytes + 65_549) + Data("尾\r".utf8)
    let inputURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try (payload + Data("\nnext\n".utf8)).write(to: inputURL)
    defer { try? FileManager.default.removeItem(at: inputURL) }
    let reader = try FileHandle(forReadingFrom: inputURL)
    defer { try? reader.close() }
    let cursor = ACPLineCursor(handle: reader)
    guard case .spooled(let url, let byteCount)? = try await cursor.nextFrame() else {
      Issue.record("Large native snapshot was buffered inline")
      return
    }
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(byteCount == payload.count)
    #expect(try Data(contentsOf: url) == payload)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    guard case .inline(let next)? = try await cursor.nextFrame() else {
      Issue.record("Small following control frame did not stay inline")
      return
    }
    #expect(next == Data("next".utf8))
    #expect(try await cursor.nextFrame() == nil)
  }

  @Test("spooled frames fail explicitly at their finite resource limit")
  func spooledNativeFrameLimit() async throws {
    let limit = ACPLineCursor.spoolThresholdBytes + 10
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try (Data(repeating: 0x61, count: limit + 1) + Data([10])).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    let spoolDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: spoolDirectory) }
    let cursor = ACPLineCursor(handle: reader, spoolDirectory: spoolDirectory)
    do {
      _ = try await cursor.nextFrame(maximumBytes: limit)
      Issue.record("Oversized native frame was accepted")
    } catch LocalACPClientError.lineTooLarge { }
    #expect(try FileManager.default.contentsOfDirectory(atPath: spoolDirectory.path).isEmpty)
    // Cleanup is immediate even while the failed cursor remains retained.
    do { _ = try await cursor.nextFrame(); Issue.record("Failed framing reader was reused") }
    catch LocalACPClientError.lineTooLarge { }
  }

  @Test("cancelling a partial spooled frame removes its file immediately")
  func spooledNativeFrameCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pipe = Pipe()
    defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
    let cursor = ACPLineCursor(handle: pipe.fileHandleForReading, spoolDirectory: directory)
    let waiting = Task { try await cursor.nextFrame() }
    let output = pipe.fileHandleForWriting
    let writer = Task.detached {
      try output.write(contentsOf: Data(repeating: 0x61, count: ACPLineCursor.spoolThresholdBytes + 65_536))
    }
    try await writer.value
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
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
