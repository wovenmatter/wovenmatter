import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor
struct SessionSelectionPreferencesTests {

  @Test("workspace sharing isolates local and remote defaults and survives reopening")
  func workspaceSharing() throws {
    try withPreferences { preferences, defaults in
      let local = "local:/fixture", remote = "remote:fixture"
      #expect(preferences.usesSharedDefaults(harness: "codex", workspace: remote))
      preferences.saveDefaults(SessionSelections(model: "shared-one", tools: ["browser"]), harness: "codex")
      preferences.setUsesSharedDefaults(false, harness: "codex", workspace: remote)
      preferences.saveDefaults(SessionSelections(model: "shared-two", thinking: "high", permission: "read-only", tools: []), harness: "codex")
      let reopened = SessionSelectionPreferences(defaults: defaults)
      #expect(!reopened.usesSharedDefaults(harness: "codex", workspace: remote))
      #expect(reopened.defaults(harness: "codex", workspace: local).model == "shared-two")
      let independent = reopened.defaults(harness: "codex", workspace: remote)
      #expect(independent.model == "shared-one" && independent.thinking == nil)
      #expect(independent.tools == ["browser"])
      #expect(reopened.usesProductPermissionDefault(harness: "codex", workspace: remote))
      let chat = reopened.captureConversation(id: "independent", harness: "codex", workspace: remote)
      #expect(chat.usesProductPermissionDefault)
      reopened.setUsesSharedDefaults(true, harness: "codex", workspace: remote)
      #expect(reopened.usesSharedDefaults(harness: "codex", workspace: remote))
      #expect(reopened.defaults(harness: "codex", workspace: remote).model == "shared-two")
      #expect(reopened.conversation(id: "independent") == chat)
      reopened.setUsesSharedDefaults(false, harness: "grok-build", workspace: remote)
      reopened.saveDefaults(SessionSelections(model: "later"), harness: "grok-build")
      #expect(reopened.defaults(harness: "grok-build", workspace: remote).model == nil)
    }
  }

  @Test("creation retains accepted native settings after defaults fail, including after reopening")
  func completedCreationSurvivesRelaunch() throws {
    try withPreferences { preferences, defaults in
      preferences.captureConversation(id: "session", harness: "opencode", workspace: "project",
        selections: SessionSelections(model: "obsolete", thinking: "high", permission: "invalid-mode", tools: []))
      let actual = SessionSelections(model: "native-model", permission: "ask", tools: [])
      preferences.replaceConfirmedSelections(id: "session", selections: actual)
      preferences.markApplied(id: "session")
      preferences.saveDefaults(SessionSelections(model: "new-default", thinking: "high"), harness: "opencode")
      let reopened = SessionSelectionPreferences(defaults: defaults)
      let completed = try #require(reopened.conversation(id: "session"))
      #expect(!completed.requiresApplication)
      #expect(completed.selections == actual)
      #expect(completed.desiredSelections == actual)
    }
  }

  private func withPreferences(
    _ body: (SessionSelectionPreferences, UserDefaults) throws -> Void
  ) throws {
    let suiteName = "SessionSelectionPreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(SessionSelectionPreferences(defaults: defaults), defaults)
  }
}
