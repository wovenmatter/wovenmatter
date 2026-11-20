import Foundation
import Testing
import WovenProtocol

/// Every example the bots runtime writes from `bots/src/protocol.ts` decodes
/// with its `BotsWire` type and encodes back to the same JSON, so a field the
/// Swift copy misses or lacks fails here.
@Test
func everyBotsWireFixtureDecodesWithItsSwiftType() throws {
  let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("bots/test/fixtures/wire.json")
  let entries = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: fixtures))
  #expect(!entries.isEmpty)
  for (name, value) in entries.sorted(by: { $0.key < $1.key }) {
    guard let type = shape(name) else {
      Issue.record("No BotsWire type for the fixture \(name)")
      continue
    }
    do {
      let decoded = try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
      let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
      #expect(normalized(encoded) == normalized(value), "\(name) does not encode back to its fixture")
    } catch {
      Issue.record("\(name): \(error)")
    }
  }
}

/// The Swift type of a fixture: named as the type, or `message.<type>` (and
/// `message.event.<kind>`) for a push.
private func shape(_ name: String) -> (any Codable.Type)? {
  if name.hasPrefix("message.") { return BotsWire.Message.self }
  let types: [String: any Codable.Type] = [
    "BotSummary": BotsWire.BotSummary.self,
    "DeletedBotSummary": BotsWire.DeletedBotSummary.self,
    "ThreadSummary": BotsWire.ThreadSummary.self,
    "ConversationSnapshot": BotsWire.ConversationSnapshot.self,
    "DisplayEntry": BotsWire.DisplayEntry.self,
    "StreamEvent": BotsWire.StreamEvent.self,
    "ForumState": BotsWire.ForumState.self,
    "ForumRoomSnapshot": BotsWire.ForumRoomSnapshot.self,
    "ForumPost": BotsWire.ForumPost.self,
    "ForumThreadSummary": BotsWire.ForumThreadSummary.self,
    "ForumScheduleSummary": BotsWire.ForumScheduleSummary.self,
    "ProfilesList": BotsWire.ProfilesList.self,
    "ProfileSummary": BotsWire.ProfileSummary.self,
    "OnboardingStatus": BotsWire.OnboardingStatus.self,
    "EnvironmentSummary": BotsWire.EnvironmentSummary.self,
    "ModelCatalog": BotsWire.ModelCatalog.self,
    "MemoryList": BotsWire.MemoryList.self,
    "GroupsList": BotsWire.GroupsList.self,
    "UserName": BotsWire.UserName.self,
  ]
  return types[name]
}

/// Numbers compared by value: `3` and `3.0` are the same number.
private func normalized(_ value: JSONValue) -> JSONValue {
  switch value {
  case .integer(let number): .double(Double(number))
  case .array(let values): .array(values.map(normalized))
  case .object(let fields): .object(fields.mapValues(normalized))
  default: value
  }
}
