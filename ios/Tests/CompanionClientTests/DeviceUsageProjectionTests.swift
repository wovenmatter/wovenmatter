import XCTest
import CryptoKit
import WovenMatterCompanion
@testable import CompanionClient

final class DeviceUsageProjectionTests: XCTestCase {
  private func record(_ id: String, workspace: String = "phone", sequence: Int64 = 1, input: Int = 10,
                      parts: Int = 1, provider: String = "openai-codex") throws -> [CompanionJournalEntry] {
    let data = try JSONSerialization.data(withJSONObject: ["id": 7, "conversationId": 2, "kind": "pi.agent", "model": [
      ["role": "assistant", "model": "test-model", "provider": provider, "timestamp": 10_000,
       "usage": ["input": input, "output": 3, "cacheRead": 4, "cacheWrite": 5, "totalTokens": input + 12, "cost": ["total": 123]]]
    ]])
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (0..<parts).map { index in
      let start = data.count * index / parts, end = data.count * (index + 1) / parts
      return .init(eventID: "\(workspace)-\(id)-\(index)", workspaceID: workspace, originSequence: sequence + Int64(index), conversationID: "chat",
        kind: .nativeRecord, nativeRecord: .init(recordID: id, format: "pi-durable.entry.v1", partIndex: index,
          partCount: parts, byteCount: Int64(data.count), sha256: digest, data: data.subdata(in: start..<end)))
    }
  }
  private func state(_ entries: [CompanionJournalEntry]) -> WorkspaceJournalState {
    var state = WorkspaceJournalState(); state.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.eventID, $0) }); return state
  }
  func testChunkedDeviceUsageUsesLatestNativeIdentityWithoutCountingOtherWorkspaces() throws {
    let old = try record("old", input: 1)
    let current = try record("new", sequence: 10, input: 20, parts: 3)
    let central = try record("synced", workspace: "central", sequence: 30, input: 999)
    let values = try DeviceUsageProjection.samples(in: state(old + current + central), workspaceID: "phone", from: .init(timeIntervalSince1970: 0), to: .init(timeIntervalSince1970: 20))
    XCTAssertEqual(values.count, 1)
    XCTAssertEqual(values[0].inputTokens, 20)
    XCTAssertEqual(values[0].totalTokens, 32)
    XCTAssertEqual(values[0].requests, 1)
    XCTAssertNil(values[0].costUSD, "Subscription price estimates must not be presented as billed spend")
    XCTAssertTrue(try DeviceUsageProjection.samples(in: state(current), workspaceID: "phone", from: .init(timeIntervalSince1970: 11), to: .init(timeIntervalSince1970: 20)).isEmpty)
  }
  func testIncompleteArchiveWaitsAndCorruptCompleteArchiveFails() throws {
    let parts = try record("chunked", parts: 3)
    let range = DateInterval(start: .init(timeIntervalSince1970: 0), end: .init(timeIntervalSince1970: 20))
    XCTAssertTrue(try DeviceUsageProjection.samples(in: state(Array(parts.dropLast())), workspaceID: "phone", from: range.start, to: range.end).isEmpty)
    var corrupted = parts; corrupted[0].nativeRecord?.data[0] ^= 1
    XCTAssertThrowsError(try DeviceUsageProjection.samples(in: state(corrupted), workspaceID: "phone", from: range.start, to: range.end))
  }
  func testNegativeTokenCountsCannotBecomeUsageTotals() throws {
    XCTAssertThrowsError(try DeviceUsageProjection.samples(in: state(record("invalid", input: -1)), workspaceID: "phone",
      from: .init(timeIntervalSince1970: 0), to: .init(timeIntervalSince1970: 20)))
  }
}
