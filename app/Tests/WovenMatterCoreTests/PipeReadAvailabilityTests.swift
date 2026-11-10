import Foundation
import Testing
import WovenMatterCore

/// Line protocols over child pipes (the remote MCP relay, the executor broker,
/// the browser helper) must see a short line while the writer stays alive.
/// `FileHandle.read(upToCount:)` waits for its full count on Darwin pipes.
@Suite("Pipe reads deliver available bytes")
struct PipeReadAvailabilityTests {
  @Test func shortLineArrivesWhileChildStaysAlive() throws {
    let child = Process(), output = Pipe()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", #"printf '{"type":"ready"}\n'; exec sleep 30"#]
    child.standardOutput = output
    try child.run()
    defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }

    let received = LockedData()
    let done = DispatchSemaphore(value: 0)
    Thread {
      received.set(try? PortablePOSIX.readAvailable(output.fileHandleForReading))
      done.signal()
    }.start()
    // Terminating the child closes the pipe, so a blocked read cannot hang the suite.
    let delivered = done.wait(timeout: .now() + 5) == .success
    if !delivered { child.terminate(); done.wait() }
    #expect(delivered)
    #expect(child.isRunning)
    #expect(received.value.map { String(decoding: $0, as: UTF8.self) } == "{\"type\":\"ready\"}\n")
  }

  @Test func closedWriterReadsAsEndOfFile() throws {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: Data("a\n".utf8))
    try pipe.fileHandleForWriting.close()
    #expect(try PortablePOSIX.readAvailable(pipe.fileHandleForReading, maximum: 1) == Data("a".utf8))
    #expect(try PortablePOSIX.readAvailable(pipe.fileHandleForReading) == Data("\n".utf8))
    #expect(try PortablePOSIX.readAvailable(pipe.fileHandleForReading).isEmpty)
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  func set(_ value: Data?) { lock.withLock { data = value } }
  var value: Data? { lock.withLock { data } }
}
