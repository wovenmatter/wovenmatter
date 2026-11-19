import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Linked activity details")
struct LibraryActivityDetailsTests {
  private func record(_ content: String, previous: String? = nil, id: String = "trace",
    version: Int = 1) throws -> Data {
    var value: [String: Any] = ["activity": ["id": id, "kind": "thought", "title": "Thinking",
      "content": content, "contentIsDelta": previous != nil, "detailVersion": version]]
    if let previous { value["previousDetailsRecordID"] = previous }
    return try JSONSerialization.data(withJSONObject: value)
  }

  @Test func longLiveChainPreservesUnicodeAndLatestMetadata() throws {
    var records: [String: Data] = ["0": try record("Base 🧵")]
    for index in 1...1_000 {
      records[String(index)] = try record(" e\u{301}🧵", previous: String(index - 1), version: index + 1)
    }
    let bytes = try LibraryActivityDetails.reconstruct(recordID: "1000", activityID: "trace") {
      (NativeRecordFormat.chainedActivity.name, records[$0]!)
    }
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["content"] as? String == "Base 🧵" + String(repeating: " e\u{301}🧵", count: 1_000))
    #expect(object["contentIsDelta"] as? Bool == false)
    #expect(object["detailVersion"] as? Int == 1_001)
  }

  @Test func rejectsCyclesMalformedEnvelopesAndMismatchedPredecessorIdentity() throws {
    let malformed: [[String: Any]] = [
      ["activity": ["id": "trace", "contentIsDelta": true, "content": "suffix"]],
      ["activity": ["id": "trace", "contentIsDelta": false, "content": "base"], "previousDetailsRecordID": "other"],
      ["activity": ["id": "trace", "contentIsDelta": false], "previousDetailsRecordID": NSNull()],
    ]
    for value in malformed {
      let bytes = try JSONSerialization.data(withJSONObject: value)
      #expect(throws: LibraryActivityDetails.invalid) {
        try LibraryActivityDetails.reconstruct(recordID: "head", activityID: "trace") { _ in (NativeRecordFormat.chainedActivity.name, bytes) }
      }
    }
    let cycle = try record("suffix", previous: "head")
    #expect(throws: LibraryActivityDetails.invalid) {
      try LibraryActivityDetails.reconstruct(recordID: "head", activityID: "trace") { _ in (NativeRecordFormat.chainedActivity.name, cycle) }
    }
    let head = try record("suffix", previous: "base"), wrong = try record("secret", id: "other")
    #expect(throws: LibraryActivityDetails.invalid) {
      try LibraryActivityDetails.reconstruct(recordID: "head", activityID: "trace") { (NativeRecordFormat.chainedActivity.name, $0 == "head" ? head : wrong) }
    }
  }

  /// Rows already stored carry the earlier tags; new rows carry the current ones.
  @Test(arguments: [
    ["wovenmatter.activity", "wovenmatter.activity.chained"],
    ["wovenmatter.activity.v1", "wovenmatter.activity.v2"],
    ["wovenmatter.activity.v1", "wovenmatter.activity.chained"],
  ])
  func completeRecordsRemainByteExactAndCanAnchorChainedSuffixes(tags: [String]) throws {
    let complete = Data("{\"id\":\"trace\", \"kind\":\"thought\", \"content\":\"Full café\", \"contentIsDelta\":false}".utf8)
    #expect(try LibraryActivityDetails.reconstruct(recordID: "old", activityID: "trace") { _ in (tags[0], complete) } == complete)
    let head = try record(" 🧵", previous: "old", version: 2)
    let bytes = try LibraryActivityDetails.reconstruct(recordID: "head", activityID: "trace") {
      $0 == "head" ? (tags[1], head) : (tags[0], complete)
    }
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["content"] as? String == "Full café 🧵")
    #expect(object["detailVersion"] as? Int == 2)
  }

  @Test func aTagThisBuildDoesNotKnowIsRefused() throws {
    let bytes = try record("Base")
    #expect(throws: LibraryActivityDetails.invalid) {
      try LibraryActivityDetails.reconstruct(recordID: "head", activityID: "trace") { _ in ("wovenmatter.activity.other", bytes) }
    }
  }

  @Test func recordFormatsWriteOneNameAndReadTheTagsAlreadyStored() {
    let stored: [(NativeRecordFormat, String, [String])] = [
      (.activity, "wovenmatter.activity", ["wovenmatter.activity.v1"]),
      (.chainedActivity, "wovenmatter.activity.chained", ["wovenmatter.activity.v2"]),
      (.piDurableEntry, "pi-durable.entry", ["pi-durable.entry.v1"]),
      (.nativeUpdate, "woven-native-update", ["woven-native-update-v1"]),
      (.fileManifest, "woven-native-file-manifest", ["woven-native-file-manifest/v1", "woven-native-file-manifest/v2"]),
      (.fileChunk, "woven-native-file-chunk", ["woven-native-file-chunk/v1"]),
      (.recordReference, "woven-native-record-reference", ["woven-native-record-reference/v1"]),
      (.textFragment, "woven-native-text-fragment", ["woven-native-text-fragment/v1"]),
    ]
    for (format, name, earlier) in stored {
      #expect(format.name == name)
      #expect(format.names == [name] + earlier)
      for tag in [name] + earlier {
        // Every tag names exactly one format.
        #expect(stored.filter { $0.0.matches(tag) }.count == 1, "\(tag)")
      }
    }
    #expect(!NativeRecordFormat.activity.matches("wovenmatter.activity.chained"))
  }
}
