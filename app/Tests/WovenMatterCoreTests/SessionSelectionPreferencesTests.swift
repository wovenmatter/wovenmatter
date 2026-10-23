import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor
struct SessionSelectionPreferencesTests {

  @Test("frozen permission origin survives settings edits during native creation")
  func frozenPermissionOrigin() throws {
    try withPreferences { preferences, defaults in
      let captured = preferences.defaults(harness: "codex", workspace: "project")
      let product = preferences.usesProductPermissionDefault(harness: "codex", workspace: "project")
      preferences.saveDefault(.permission, from: SessionSelections(permission: "read-only"), harness: "codex")
      let fresh = preferences.captureConversation(id: "product", harness: "codex", workspace: "project",
        capturedDefaults: captured, usesProductPermissionDefault: product)
      #expect(fresh.usesProductPermissionDefault)
      #expect(fresh.desiredSelections.permission == "agent-full-access")
      #expect(preferences.reconcileProductPermissionDefault(id: "product", options: ["agent"],
        nativePermission: "agent")?.desiredSelections.permission == nil)

      preferences.saveDefault(.permission, from: SessionSelections(permission: "agent-full-access"), harness: "codex")
      let explicit = preferences.defaults(harness: "codex", workspace: "project")
      let explicitProduct = preferences.usesProductPermissionDefault(harness: "codex", workspace: "project")
      preferences.removeDefault(.permission, harness: "codex")
      let frozen = preferences.captureConversation(id: "explicit", harness: "codex", workspace: "project",
        capturedDefaults: explicit, usesProductPermissionDefault: explicitProduct)
      #expect(!frozen.usesProductPermissionDefault)
      #expect(preferences.reconcileProductPermissionDefault(id: "explicit", options: [], nativePermission: nil) == frozen)
      #expect(SessionSelectionPreferences(defaults: defaults).conversation(id: "explicit") == frozen)
    }
  }

  @Test("user permission choices override Full access and reset restores inheritance")
  func fullAccessDefaultCanBeOverridden() throws {
    try withPreferences { preferences, defaults in
      preferences.saveDefaults(SessionSelections(model: "chosen-model", permission: "read-only"), harness: "codex")
      preferences.saveDefault(.permission, from: SessionSelections(permission: "agent"), harness: "codex", workspace: "project")
      #expect(preferences.defaults(harness: "codex", workspace: "other").permission == "read-only")
      #expect(preferences.captureConversation(id: "workspace", harness: "codex", workspace: "project").desiredSelections.permission == "agent")
      #expect(preferences.captureConversation(id: "explicit", harness: "codex", workspace: "project",
        selections: SessionSelections(permission: "read-only")).desiredSelections.permission == "read-only")
      preferences.removeDefault(.permission, harness: "codex", workspace: "project")
      #expect(preferences.defaults(harness: "codex", workspace: "project").permission == "read-only")
      preferences.removeDefault(.permission, harness: "codex")
      #expect(preferences.defaults(harness: "codex", workspace: "project")
        == SessionSelections(model: "chosen-model", permission: "agent-full-access"))
      let reopened = SessionSelectionPreferences(defaults: defaults)
      #expect(reopened.conversation(id: "workspace")?.desiredSelections.permission == "agent")
      #expect(reopened.conversation(id: "explicit")?.desiredSelections.permission == "read-only")
      reopened.updateConversation(id: "workspace", selections: SessionSelections(permission: "read-only"))
      #expect(preferences.conversation(id: "workspace")?.desiredSelections.permission == "read-only")
    }
  }

  @Test("existing native sessions are adopted without applying newly configured defaults")
  func existingConversationMigration() throws {
    try withPreferences { preferences, defaults in
      preferences.saveDefaults(
        SessionSelections(model: "future", thinking: "high", permission: "ask", tools: ["files"]),
        harness: "codex"
      )
      let native = SessionSelections(model: "existing-model", permission: "native-policy")
      let known = preferences.captureExistingConversation(
        id: "known", harness: "codex", workspace: "project", selections: native
      )
      #expect(known.selections == native)
      #expect(known.desiredSelections.isEmpty)
      #expect(!known.requiresApplication)
      let unknown = preferences.captureExistingConversation(id: "unknown", harness: "codex", workspace: "project")
      #expect(unknown.selections.isEmpty)
      let reopened = SessionSelectionPreferences(defaults: defaults)
      #expect(reopened.captureConversation(
        id: "unknown", harness: "codex", workspace: "project",
        nativeFallback: native
      ) == unknown)
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
