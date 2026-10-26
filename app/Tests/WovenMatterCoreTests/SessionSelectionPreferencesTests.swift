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

  @Test("partial pending repairs survive another field failure and relaunch")
  func pendingRepairsSurviveRelaunch() throws {
    try withPreferences { preferences, defaults in
      let original = preferences.captureConversation(id: "session", harness: "opencode", workspace: "project",
        selections: SessionSelections(model: "obsolete", thinking: "high", permission: "invalid-mode", tools: []))
      let firstRepair = original.desiredSelections.applyingPendingCorrection(SessionSelections(model: "available"))
      preferences.updateConversation(id: "session", selections: firstRepair)
      preferences.updateConversation(id: "session", field: .thinking, from: firstRepair)
      // Native application still fails on invalid-mode; no markApplied occurs.
      preferences.saveDefaults(SessionSelections(model: "new-default", thinking: "high"), harness: "opencode")
      let reopened = SessionSelectionPreferences(defaults: defaults)
      let pending = try #require(reopened.conversation(id: "session"))
      #expect(pending.requiresApplication)
      #expect(pending.desiredSelections == SessionSelections(model: "available", permission: "invalid-mode", tools: []))
      let secondRepair = pending.desiredSelections.applyingPendingCorrection(SessionSelections(permission: "normal"))
      reopened.updateConversation(id: "session", selections: secondRepair)
      #expect(preferences.conversation(id: "session")?.desiredSelections
        == SessionSelections(model: "available", permission: "normal", tools: []))
      #expect(preferences.conversation(id: "session")?.requiresApplication == true)
      reopened.replaceConfirmedSelections(id: "session", selections: secondRepair)
      reopened.markApplied(id: "session")
      #expect(preferences.conversation(id: "session")?.requiresApplication == false)
      #expect(preferences.conversation(id: "session")?.selections.thinking == nil)
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
