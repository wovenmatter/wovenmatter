import Foundation
import Testing
@testable import CompanionClient

@Suite("Workspace text byte windows")
struct WorkspaceTextFileTests {
  private func file(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wm-read-" + UUID().uuidString)
    try data.write(to: url); return url
  }
  @Test func largeOutputCanBeReadWithoutLoadingOrDroppingItsTail() throws {
    let bytes = Data(repeating: 65, count: WorkspaceTextFile.maximumReadBytes + 100)
    let url = try file(bytes); defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: WorkspaceTextFile.Failure.self) { try WorkspaceTextFile.read(url, offset: -1) }
    #expect(throws: WorkspaceTextFile.Failure.self) { try WorkspaceTextFile.read(url, limit: 0) }
    #expect(throws: WorkspaceTextFile.Failure.self) { try WorkspaceTextFile.read(url, limit: WorkspaceTextFile.maximumReadBytes + 1) }
    let first = try WorkspaceTextFile.read(url)
    #expect(first.byteCount == WorkspaceTextFile.defaultWindowBytes)
    #expect(first.truncated && !first.eof)
    let tail = try WorkspaceTextFile.read(url, offset: bytes.count - 12, limit: 100)
    #expect(tail.content == String(repeating: "A", count: 12))
    #expect(tail.eof && tail.nextOffset == bytes.count)
    let past = try WorkspaceTextFile.read(url, offset: Int.max, limit: 100)
    #expect(past.eof && past.byteCount == 0 && past.nextOffset == bytes.count)
  }

  @Test func smallFilesAndSplitUTF8AreExplicitAndLossless() throws {
    let text = "a🙂b", url = try file(Data(text.utf8)); defer { try? FileManager.default.removeItem(at: url) }
    let whole = try WorkspaceTextFile.read(url)
    #expect(whole.content == text && !whole.truncated && !whole.lossyUTF8)
    let split = try WorkspaceTextFile.read(url, offset: 2, limit: 2)
    #expect(split.lossyUTF8 && split.byteCount == 2 && split.nextOffset == 4)
    #expect(split.bytesBase64.flatMap { Data(base64Encoded: $0) } == Data(text.utf8).subdata(in: 2..<4))
  }
}
