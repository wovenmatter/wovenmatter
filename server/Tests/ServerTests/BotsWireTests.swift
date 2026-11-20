import Foundation
import Testing
import WovenProtocol

/// Every example the bots runtime writes from `bots/src/protocol.ts` decodes
/// with the `BotsWire` type the UI reads it with and encodes back to the same
/// JSON, so a field the Swift copy misses or lacks fails here. A fixture with
/// no entry below fails too, so a new shape is never left unchecked.
@Test
func everyBotsWireFixtureDecodesWithItsSwiftType() throws {
  let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("bots/test/fixtures/wire.json")
  let entries = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: fixtures))
  #expect(!entries.isEmpty)
  for (name, value) in entries.sorted(by: { $0.key < $1.key }) {
    if name.hasPrefix("host.") || unread.contains(name) { continue }
    do {
      let data = try JSONEncoder().encode(value)
      if let type = partial[name] {
        _ = try JSONDecoder().decode(type, from: data)
        continue
      }
      guard let type = shape(name) else {
        Issue.record("No BotsWire type for the fixture \(name)")
        continue
      }
      let decoded = try JSONDecoder().decode(type, from: data)
      let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
      #expect(normalized(encoded) == normalized(value), "\(name) does not encode back to its fixture")
    } catch {
      Issue.record("\(name): \(error)")
    }
  }
}

/// Shapes and replies the UI never reads: acknowledgements, and what only the
/// server or other clients use.
private let unread: Set<String> = [
  "AccountsSummary", "reply.settings.accounts", "reply.account.notes", "reply.account.setNotes",
  "reply.bots.delete", "reply.bots.rename", "reply.bots.restore", "reply.bots.rebuild", "reply.bots.stop",
  "reply.bots.setGroup", "reply.bots.setManager", "reply.bots.setTeam", "reply.bots.replaceManager",
  "reply.bots.setOrchestrator", "reply.bots.setProfile",
  "reply.groups.rename", "reply.groups.delete", "reply.groups.reorder",
  "reply.thread.setPinned", "reply.forum.thread.setPinned", "reply.thread.setTitle", "reply.forum.thread.setTitle", "reply.onboarding.setMainModel",
  "reply.conversation.abort", "reply.conversation.close", "reply.forum.close",
  "reply.message.send", "reply.message.send.duplicate", "reply.forum.post.duplicate", "reply.runtime.update",
]

/// Read only in part (see `BotsWire.RuntimeStatus`): decoded, not compared.
private let partial: [String: any Decodable.Type] = [
  "RuntimeStatus": BotsWire.RuntimeStatus.self,
  "reply.runtime.status": BotsWire.RuntimeStatus.self,
]

/// The Swift type the UI decodes a fixture with: a named shape, a push
/// (`message.<type>`, `message.event.<kind>`), or a reply (`reply.<request>`).
private func shape(_ name: String) -> (any Codable.Type)? {
  if name.hasPrefix("message.") { return BotsWire.Message.self }
  let types: [String: any Codable.Type] = [
    "BotSummary": BotsWire.BotSummary.self,
    "DeletedBotSummary": BotsWire.DeletedBotSummary.self,
    "ThreadSummary": BotsWire.ThreadSummary.self,
    "ConversationSnapshot": BotsWire.ConversationSnapshot.self,
    "DisplayEntry": BotsWire.DisplayEntry.self,
    "ForumState": BotsWire.ForumState.self,
    "ForumRoomSnapshot": BotsWire.ForumRoomSnapshot.self,
    "ForumPost": BotsWire.ForumPost.self,
    "ForumThreadSummary": BotsWire.ForumThreadSummary.self,
    "ForumScheduleSummary": BotsWire.ForumScheduleSummary.self,
    "ProfilesList": BotsWire.ProfilesList.self,
    "OnboardingStatus": BotsWire.OnboardingStatus.self,
    "EnvironmentSummary": BotsWire.EnvironmentSummary.self,
    "ModelCatalog": BotsWire.ModelCatalog.self,
    "SidebarGroup": BotsWire.Group.self,
    "reply.bots.list": BotsWire.BotsList.self,
    "reply.bots.listDeleted": BotsWire.DeletedBotsList.self,
    "reply.bots.create": BotsWire.BotResult.self,
    "reply.bots.purge": BotsWire.PurgeResult.self,
    "reply.bots.environment": BotsWire.EnvironmentResult.self,
    "reply.groups.list": BotsWire.GroupsList.self,
    "reply.groups.create": BotsWire.GroupResult.self,
    "reply.threads.list": BotsWire.ThreadsList.self,
    "reply.thread.fork": BotsWire.ThreadResult.self,
    "reply.conversation.open": BotsWire.ConversationSnapshot.self,
    "reply.memory.list": BotsWire.MemoryList.self,
    "reply.memory.add": BotsWire.MemoryList.self,
    "reply.memory.update": BotsWire.MemoryList.self,
    "reply.memory.delete": BotsWire.MemoryList.self,
    "reply.profiles.list": BotsWire.ProfilesList.self,
    "reply.profiles.save": BotsWire.ProfilesList.self,
    "reply.profiles.delete": BotsWire.ProfilesList.self,
    "reply.profiles.setDefault": BotsWire.ProfilesList.self,
    "reply.models.catalog": BotsWire.ModelCatalog.self,
    "reply.models.setRoles": BotsWire.RolesResult.self,
    "reply.onboarding.status": BotsWire.OnboardingStatus.self,
    "reply.user.get": BotsWire.UserName.self,
    "reply.user.setName": BotsWire.UserName.self,
    "reply.forum.get": BotsWire.ForumState.self,
    "reply.forum.setPaused": BotsWire.ForumState.self,
    "reply.forum.setBotActive": BotsWire.ForumState.self,
    "reply.forum.open": BotsWire.ForumRoomSnapshot.self,
    "reply.forum.posts": BotsWire.ForumPostsPage.self,
    "reply.forum.post": BotsWire.ForumPostResult.self,
    "reply.forum.thread.create": BotsWire.ForumThreadResult.self,
    "reply.forum.schedules.list": BotsWire.ForumSchedulesList.self,
    "reply.forum.schedules.save": BotsWire.ForumSchedulesList.self,
    "reply.forum.schedules.delete": BotsWire.ForumSchedulesList.self,
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
