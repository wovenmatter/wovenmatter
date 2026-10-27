import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite("Linked activity details")
struct CompanionActivityDetailsTests {
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
    let bytes = try CompanionActivityDetails.reconstruct(recordID: "1000", activityID: "trace") {
      ("wovenmatter.activity.v2", records[$0]!)
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
      #expect(throws: CompanionActivityDetails.invalid) {
        try CompanionActivityDetails.reconstruct(recordID: "head", activityID: "trace") { _ in ("wovenmatter.activity.v2", bytes) }
      }
    }
    let cycle = try record("suffix", previous: "head")
    #expect(throws: CompanionActivityDetails.invalid) {
      try CompanionActivityDetails.reconstruct(recordID: "head", activityID: "trace") { _ in ("wovenmatter.activity.v2", cycle) }
    }
    let head = try record("suffix", previous: "base"), wrong = try record("secret", id: "other")
    #expect(throws: CompanionActivityDetails.invalid) {
      try CompanionActivityDetails.reconstruct(recordID: "head", activityID: "trace") { ("wovenmatter.activity.v2", $0 == "head" ? head : wrong) }
    }
  }

  @Test func legacyFullRecordsRemainByteExactAndCanAnchorNewSuffixes() throws {
    let legacy = Data("{\"id\":\"trace\", \"kind\":\"thought\", \"content\":\"Full café\", \"contentIsDelta\":false}".utf8)
    #expect(try CompanionActivityDetails.reconstruct(recordID: "old", activityID: "trace") { _ in ("wovenmatter.activity.v1", legacy) } == legacy)
    let head = try record(" 🧵", previous: "old", version: 2)
    let bytes = try CompanionActivityDetails.reconstruct(recordID: "head", activityID: "trace") {
      $0 == "head" ? ("wovenmatter.activity.v2", head) : ("wovenmatter.activity.v1", legacy)
    }
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["content"] as? String == "Full café 🧵")
    #expect(object["detailVersion"] as? Int == 2)
  }
}
