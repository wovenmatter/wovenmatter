import CryptoKit
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Paged native archive chunks")
struct WorkspaceNativeChunkArchiveTests {
  @Test func interruptedChunkCopyReopensDeduplicatesSearchesAndExportsExactNativeBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "workspace.sqlite")
    let db = try await WorkspaceDatabase(url: url)
    let conversation = try await db.createLocalACPSession(runtimeKind: .defaultAgent, title: "Chunks", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Copy native output")
    let content = String(repeating: "🧵π ", count: 80_000) + " violet harbor archive sentinel"
    let native: GatewayJSONValue = .object([
      "id": .string("native:7"), "kind": .string("tool.result"), "content": .string(content),
      "attachment": .object(["url": .string("native://attachment/image"), "future": .bool(true)])])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let original = try encoder.encode(native)
    let checksum = digest(original)
    var chunks: [WorkspaceNativeRunRecord] = []
    var parts: [GatewayJSONValue] = []
    for offset in stride(from: 0, to: original.count, by: 262_144) {
      let bytes = original.subdata(in: offset..<min(offset + 262_144, original.count))
      let sha = digest(bytes)
      let id = "native-record:\(checksum):native-file.chunk:\(sha)"
      let payload: GatewayJSONValue = .object([
        "format": .string("woven-native-file-chunk/v1"), "encoding": .string("base64"),
        "sha256": .string(sha), "dataBase64": .string(bytes.base64EncodedString())])
      chunks.append(.init(id: id, runID: run.runID, kind: "native-file.chunk",
        payload: String(decoding: try encoder.encode(payload), as: UTF8.self),
        text: String(decoding: bytes, as: UTF8.self), completeness: "native-file-chunk"))
      parts.append(.object(["byteOffset": .number(Double(offset)), "byteCount": .number(Double(bytes.count)), "chunkID": .string(id)]))
    }
    let manifests = try parts.enumerated().map { page, part -> WorkspaceNativeRunRecord in
      let payload: GatewayJSONValue = .object([
        "format": .string("woven-native-file-manifest/v2"),
        "originalRecord": .object(["id": .string("native:7"), "kind": .string("tool.result"), "runID": .string(run.runID), "ordinal": .number(0)]),
        "sourceSHA256": .string(checksum), "sourceTotalBytes": .number(Double(original.count)),
        "sha256": .string(checksum), "totalBytes": .number(Double(original.count)),
        "byteFidelity": .string("exact-native-bytes"), "manifestPage": .number(Double(page)),
        "manifestPages": .number(Double(parts.count)), "chunkBytes": .number(262_144), "parts": .array([part])])
      return .init(id: "native-record:\(checksum):manifest:\(page)", runID: run.runID, kind: "native-file.manifest",
        payload: String(decoding: try encoder.encode(payload), as: UTF8.self), completeness: "native-export")
    }
    func batch(_ records: [WorkspaceNativeRunRecord]) -> WorkspaceNativeRunRecordBatch {
      .init(sourceID: "remote:host:store", nativeSessionID: "7", records: records)
    }
    // A disconnect may leave committed chunks without all manifest pages.
    try await db.recordNativeRunRecords(batch(chunks + [manifests[0]]), conversationID: conversation, harness: "defaultAgent")
    let reopened = try await WorkspaceDatabase(url: url)
    try await reopened.recordNativeRunRecords(batch(chunks + manifests), conversationID: conversation, harness: "defaultAgent")
    try await reopened.recordNativeRunRecords(batch(chunks + manifests), conversationID: conversation, harness: "defaultAgent")
    var rows: [GatewayJSONValue] = [], cursor: Int64 = 0
    while true {
      let page = try await reopened.queryHistory(.init(command: "events", conversationID: conversation, harness: "defaultAgent", after: cursor, limit: 2))
      rows += page.objectValue?["rows"]?.arrayValue ?? []
      guard page.objectValue?["hasMore"]?.boolValue == true else { break }
      cursor = Int64(try #require(page.objectValue?["nextCursor"]?.intValue))
    }
    let nativeRows = rows.filter { $0.objectValue?["source_id"]?.stringValue == "remote:host:store" }
    #expect(nativeRows.count == chunks.count + manifests.count)
    let exactQuery = WorkspaceHistoryQuery(command: "events", conversationID: conversation, harness: "defaultAgent",
      sourceID: "remote:host:store", nativeSessionID: "7", nativeRecordID: chunks[0].id)
    let reader = try await reopened.createLocalACPSession(runtimeKind: .pi, title: "Reader", ownerDeviceID: UUID())
    try await reopened.setSessionTools(.init(enabled: []), sessionID: reader)
    await #expect(throws: (any Error).self) { try await reopened.queryAgentHistory(exactQuery, callerID: reader) }
    try await reopened.setSessionTools(.init(enabled: [.history]), sessionID: reader)
    let exact = try await reopened.queryAgentHistory(exactQuery, callerID: reader)
    #expect(exact.objectValue?["rows"]?.arrayValue?.count == 1)
    #expect((try await reopened.queryAgentHistory(.init(command: "search", search: "violet harbor archive sentinel"), callerID: reader)).objectValue?["rows"]?.arrayValue?.isEmpty == false)
    var payloads: [String: GatewayJSONValue] = [:]
    for row in nativeRows {
      let id = try #require(row.objectValue?["id"]?.stringValue)
      var query = WorkspaceHistoryQuery(command: "event", id: id)
      var payload = ""
      while true {
        let window = try await reopened.queryHistory(query)
        let value = try #require(window.objectValue?["rows"]?.arrayValue?.first?.objectValue)
        payload += value["payload"]?.stringValue ?? ""
        guard value["payload_has_more"]?.intValue == 1 else { break }
        query.offset += query.characters
      }
      payloads[try #require(row.objectValue?["native_record_id"]?.stringValue)] = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(payload.utf8))
    }
    #expect(try reconstruct(payloads) == original)
    #expect((try await reopened.queryHistory(.init(command: "search", search: "violet harbor archive sentinel", conversationID: conversation))).objectValue?["rows"]?.arrayValue?.isEmpty == false)
    let exportedURL = directory.appending(path: "archive.json")
    try await reopened.exportConversationArchive(id: conversation, to: exportedURL)
    let exported = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(contentsOf: exportedURL))
    let exportRows = try #require(exported.objectValue?["historyEvents"]?.arrayValue)
    var exportPayloads: [String: GatewayJSONValue] = [:]
    for row in exportRows where row.objectValue?["source_id"]?.stringValue == "remote:host:store" {
      let nativeID = try #require(row.objectValue?["native_record_id"]?.stringValue)
      let payload = try #require(row.objectValue?["payload"]?.stringValue)
      exportPayloads[nativeID] = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(payload.utf8))
    }
    #expect(try reconstruct(exportPayloads) == original)
  }

  private func reconstruct(_ payloads: [String: GatewayJSONValue]) throws -> Data {
    let manifests = payloads.values.filter { $0.objectValue?["format"]?.stringValue == "woven-native-file-manifest/v2" }
      .sorted { ($0.objectValue?["manifestPage"]?.intValue ?? 0) < ($1.objectValue?["manifestPage"]?.intValue ?? 0) }
    #expect(manifests.count == manifests.first?.objectValue?["manifestPages"]?.intValue)
    var result = Data()
    for manifest in manifests {
      for part in try #require(manifest.objectValue?["parts"]?.arrayValue) {
        #expect(part.objectValue?["byteOffset"]?.intValue == result.count)
        let chunkID = try #require(part.objectValue?["chunkID"]?.stringValue)
        let chunk = try #require(payloads[chunkID]?.objectValue)
        let encoded = try #require(chunk["dataBase64"]?.stringValue)
        let bytes = try #require(Data(base64Encoded: encoded))
        #expect(bytes.count == part.objectValue?["byteCount"]?.intValue)
        #expect(digest(bytes) == chunk["sha256"]?.stringValue)
        result.append(bytes)
      }
    }
    #expect(result.count == manifests.first?.objectValue?["totalBytes"]?.intValue)
    #expect(digest(result) == manifests.first?.objectValue?["sha256"]?.stringValue)
    return result
  }

  private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
