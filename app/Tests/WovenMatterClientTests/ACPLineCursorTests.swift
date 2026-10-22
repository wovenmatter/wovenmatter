import Foundation
import Testing
@testable import WovenMatterClient

@Suite("ACP pipe reading", .timeLimit(.minutes(1)))
struct ACPLineCursorTests {

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

}
