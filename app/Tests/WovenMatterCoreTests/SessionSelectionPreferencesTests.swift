import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor
struct SessionSelectionPreferencesTests {
  @Test("new sessions resolve each field in conversation, workspace, harness, native order")
  func fieldwisePrecedence() throws {
    try withPreferences { preferences, _ in
      preferences.saveDefaults(
        SessionSelections(model: "harness-model", thinking: "low", permission: "ask"),
        harness: "codex"
      )
      preferences.saveDefaults(
        SessionSelections(model: "workspace-model", thinking: "high"),
        harness: "codex", workspace: "project-a"
      )
      let snapshot = preferences.captureConversation(
        id: "new", harness: "codex", workspace: "project-a",
        selections: SessionSelections(model: "conversation-model"),
        nativeFallback: SessionSelections(model: "native", permission: "native", tools: ["read"])
      )
      #expect(snapshot.selections == SessionSelections(
        model: "conversation-model", thinking: "high", permission: "ask", tools: ["read"]
      ))
      #expect(snapshot.desiredSelections == SessionSelections(
        model: "conversation-model", thinking: "high", permission: "ask"
      ))
      #expect(snapshot.harness == "codex")
      #expect(snapshot.workspace == "project-a")
    }
  }

  @Test("an empty tools choice overrides inherited and native tool groups")
  func explicitEmptyTools() throws {
    try withPreferences { preferences, _ in
      preferences.saveDefaults(SessionSelections(tools: ["files", "shell"]), harness: "claude")
      preferences.saveDefault(
        .tools, from: SessionSelections(tools: []), harness: "claude", workspace: "project"
      )
      let snapshot = preferences.captureConversation(
        id: "new", harness: "claude", workspace: "project",
        nativeFallback: SessionSelections(tools: ["native"])
      )
      #expect(snapshot.selections.tools == [])
      #expect(snapshot.desiredSelections.tools == [])
      preferences.removeDefault(.tools, harness: "claude", workspace: "project")
      #expect(preferences.defaults(harness: "claude", workspace: "project").tools == ["files", "shell"])
      #expect(preferences.conversation(id: "new")?.selections.tools == [])
    }
  }

  @Test("workspace and harness identifiers are independent opaque namespaces")
  func contextIsolation() throws {
    try withPreferences { preferences, _ in
      preferences.saveDefaults(SessionSelections(model: "a"), harness: "one:two", workspace: "three")
      preferences.saveDefaults(SessionSelections(model: "b"), harness: "one", workspace: "two:three")
      preferences.saveDefaults(SessionSelections(thinking: "medium"), harness: "one")
      #expect(preferences.defaults(harness: "one:two", workspace: "three") == SessionSelections(model: "a"))
      #expect(preferences.defaults(harness: "one", workspace: "two:three") == SessionSelections(model: "b", thinking: "medium"))
      #expect(preferences.defaults(harness: "one", workspace: "three") == SessionSelections(thinking: "medium"))
      #expect(preferences.defaults(harness: "unknown", workspace: "three").isEmpty)
    }
  }

  @Test("captured sessions do not change when defaults or capture arguments change")
  func idempotentCapture() throws {
    try withPreferences { preferences, _ in
      preferences.saveDefaults(SessionSelections(model: "first"), harness: "codex")
      let original = preferences.captureConversation(id: "session", harness: "codex", workspace: "project")
      preferences.saveDefaults(SessionSelections(model: "later", permission: "ask"), harness: "codex")
      let repeated = preferences.captureConversation(
        id: "session", harness: "different", workspace: "elsewhere",
        selections: SessionSelections(model: "explicit-later"),
        nativeFallback: SessionSelections(thinking: "high")
      )
      #expect(repeated == original)
      #expect(preferences.captureConversation(
        id: "another", harness: "codex", workspace: "project"
      ).selections == SessionSelections(model: "later", permission: "ask"))
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

  @Test("pending native creation can supply defaults frozen before its local ID exists")
  func previouslyCapturedDefaults() throws {
    try withPreferences { preferences, _ in
      preferences.saveDefaults(SessionSelections(model: "later", permission: "ask"), harness: "opencode")
      let frozen = preferences.captureConversation(
        id: "pending", harness: "opencode", workspace: "project",
        nativeFallback: SessionSelections(permission: "native-policy"),
        capturedDefaults: SessionSelections(model: "original")
      )
      #expect(frozen.desiredSelections == SessionSelections(model: "original"))
      #expect(frozen.selections.permission == "native-policy")
      #expect(preferences.captureConversation(
        id: "empty", harness: "opencode", workspace: "project", capturedDefaults: SessionSelections()
      ).desiredSelections.isEmpty)
    }
  }

  @Test("editing or removing one default preserves all other overrides")
  func singleDefaultEdits() throws {
    try withPreferences { preferences, _ in
      preferences.saveDefaults(SessionSelections(model: "inherited", permission: "ask"), harness: "codex")
      preferences.saveDefaults(SessionSelections(model: "local", thinking: "high"), harness: "codex", workspace: "project")
      preferences.saveDefault(
        .permission, from: SessionSelections(model: "ignored", permission: "read-only"),
        harness: "codex", workspace: "project"
      )
      #expect(preferences.storedDefaults(harness: "codex", workspace: "project") == SessionSelections(
        model: "local", thinking: "high", permission: "read-only"
      ))
      preferences.removeDefault(.model, harness: "codex", workspace: "project")
      #expect(preferences.defaults(harness: "codex", workspace: "project") == SessionSelections(
        model: "inherited", thinking: "high", permission: "read-only"
      ))
      #expect(preferences.storedDefaults(harness: "codex") == SessionSelections(model: "inherited", permission: "ask"))
    }
  }

  @Test("conversation edits merge explicit values and can clear just one field")
  func explicitConversationEdits() throws {
    try withPreferences { preferences, _ in
      preferences.captureExistingConversation(
        id: "session", harness: "codex", workspace: "project",
        selections: SessionSelections(model: "first", thinking: "high", permission: "ask", tools: ["files"])
      )
      preferences.updateConversation(id: "session", selections: SessionSelections(model: "second", tools: []))
      let changed = preferences.updateConversation(id: "session", field: .thinking, from: SessionSelections())
      #expect(changed?.selections == SessionSelections(model: "second", permission: "ask", tools: []))
      #expect(changed?.desiredSelections == SessionSelections(model: "second", tools: []))
      #expect(changed?.requiresApplication == false)
      #expect(preferences.updateConversation(id: "unknown", selections: SessionSelections(permission: "ask")) == nil)
      #expect(preferences.conversation(id: "unknown") == nil)
    }
  }

  @Test("correcting a pending model clears obsolete thinking but keeps permission and tools")
  func pendingModelCorrection() {
    let pending = SessionSelections(model: "obsolete", thinking: "high", permission: "normal", tools: [])
    #expect(pending.applyingPendingCorrection(SessionSelections(model: "no-thinking-model"))
      == SessionSelections(model: "no-thinking-model", permission: "normal", tools: []))
    #expect(pending.applyingPendingCorrection(SessionSelections(model: "reasoning-model", thinking: "low"))
      == SessionSelections(model: "reasoning-model", thinking: "low", permission: "normal", tools: []))
    #expect(pending.applyingPendingCorrection(SessionSelections(permission: "auto"))
      == SessionSelections(model: "obsolete", thinking: "high", permission: "auto", tools: []))
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

  @Test("confirmed native metadata clears unsupported thinking without promoting observed fallback")
  func confirmedSelections() throws {
    try withPreferences { preferences, _ in
      preferences.captureConversation(
        id: "session", harness: "codex", workspace: "project",
        selections: SessionSelections(model: "reasoning-model", thinking: "high", tools: []),
        nativeFallback: SessionSelections(permission: "native-policy")
      )
      let confirmed = preferences.replaceConfirmedSelections(
        id: "session", selections: SessionSelections(model: "no-effort-model", permission: "native-policy", tools: [])
      )
      #expect(confirmed?.selections == SessionSelections(model: "no-effort-model", permission: "native-policy", tools: []))
      #expect(confirmed?.desiredSelections == SessionSelections(model: "no-effort-model", tools: []))
      #expect(confirmed?.requiresApplication == true)
    }
  }

  @Test("pending application survives relaunch and is acknowledged without rearming on edits")
  func persistentApplicationMarker() throws {
    try withPreferences { preferences, defaults in
      preferences.saveDefaults(SessionSelections(model: "captured"), harness: "codex")
      let snapshot = preferences.captureConversation(id: "session", harness: "codex", workspace: "project")
      #expect(snapshot.requiresApplication)
      let reopened = SessionSelectionPreferences(defaults: defaults)
      #expect(reopened.conversation(id: "session") == snapshot)
      reopened.markApplied(id: "session")
      reopened.updateConversation(id: "session", selections: SessionSelections(thinking: "medium"))
      #expect(preferences.conversation(id: "session")?.requiresApplication == false)
      #expect(preferences.conversation(id: "session")?.selections.model == "captured")
      #expect(preferences.markApplied(id: "missing") == nil)
    }
  }

  @Test("multiple store instances retain one another's writes")
  func freshReadBeforeWrite() throws {
    try withPreferences { preferences, defaults in
      let other = SessionSelectionPreferences(defaults: defaults)
      preferences.saveDefaults(SessionSelections(model: "a"), harness: "a")
      other.saveDefaults(SessionSelections(model: "b"), harness: "b")
      preferences.captureExistingConversation(id: "session", harness: "a", workspace: "project")
      other.saveDefault(.thinking, from: SessionSelections(thinking: "high"), harness: "b")
      #expect(preferences.defaults(harness: "a").model == "a")
      #expect(preferences.defaults(harness: "b") == SessionSelections(model: "b", thinking: "high"))
      #expect(other.conversation(id: "session")?.workspace == "project")
    }
  }

  @Test("snapshots from before the application marker remain captured and already applied")
  func snapshotMarkerMigration() throws {
    try withPreferences { preferences, defaults in
      preferences.captureConversation(id: "session", harness: "codex", workspace: "project")
      let data = try #require(defaults.data(forKey: SessionSelectionPreferences.storageKey))
      var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      var conversations = try #require(document["conversations"] as? [String: [String: Any]])
      conversations["session"]?.removeValue(forKey: "requiresApplication")
      document["conversations"] = conversations
      defaults.set(try JSONSerialization.data(withJSONObject: document), forKey: SessionSelectionPreferences.storageKey)
      let migrated = try #require(preferences.conversation(id: "session"))
      #expect(!migrated.requiresApplication)
      #expect(migrated.harness == "codex")
      #expect(preferences.captureConversation(id: "session", harness: "codex", workspace: "project") == migrated)
    }
  }

  @Test("malformed and unknown-version storage falls back to native settings without a write")
  func corruptStorageIsSafe() throws {
    try withPreferences { preferences, defaults in
      let invalidDocuments = [
        Data("not json".utf8),
        Data(#"{"version":99,"harnessDefaults":{"codex":{"permission":"full-access"}},"workspaceDefaults":{},"conversations":{}}"#.utf8),
        Data(#"{"version":1,"harnessDefaults":{"codex":{"permission":123}},"workspaceDefaults":{},"conversations":{}}"#.utf8),
      ]
      defaults.set("unrelated setting", forKey: "legacy-preference")
      for data in invalidDocuments {
        defaults.set(data, forKey: SessionSelectionPreferences.storageKey)
        #expect(preferences.defaults(harness: "codex", workspace: "project").isEmpty)
        #expect(preferences.conversation(id: "session") == nil)
        #expect(defaults.data(forKey: SessionSelectionPreferences.storageKey) == data)
        let captured = preferences.captureConversation(
          id: "session", harness: "codex", workspace: "project",
          nativeFallback: SessionSelections(model: "native", permission: "read-only")
        )
        #expect(captured.selections == SessionSelections(model: "native", permission: "read-only"))
        #expect(captured.desiredSelections.isEmpty)
      }
      #expect(defaults.string(forKey: "legacy-preference") == "unrelated setting")
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
