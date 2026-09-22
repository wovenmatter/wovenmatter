import Foundation
import WovenMatterCore

/// Main-actor serialization covers read/modify/write operations across instances.
/// Reads check UserDefaults so a second store instance cannot overwrite stale state.
@MainActor
public final class SessionSelectionPreferences {
  public static let storageKey = "wovenmatter.session-selections.v1"

  private let userDefaults: UserDefaults
  private var cachedData: Data?
  private var cachedDocument: Document?

  public init(defaults: UserDefaults = .standard) {
    userDefaults = defaults
  }

  public func defaults(harness: String, workspace: String? = nil) -> SessionSelections {
    defaults(in: read(), harness: harness, workspace: workspace)
  }

  /// Returns only this scope's overrides, before inheritance, for editing defaults.
  public func storedDefaults(harness: String, workspace: String? = nil) -> SessionSelections {
    storedDefaults(in: read(), harness: harness, workspace: workspace)
  }

  /// Replaces one complete scope. Use saveDefault to edit just one control.
  public func saveDefaults(
    _ selections: SessionSelections,
    harness: String,
    workspace: String? = nil
  ) {
    var document = read()
    setDefaults(selections, in: &document, harness: harness, workspace: workspace)
    write(document)
  }

  public func saveDefault(
    _ field: SessionSelectionField,
    from selections: SessionSelections,
    harness: String,
    workspace: String? = nil
  ) {
    var document = read()
    let updated = storedDefaults(in: document, harness: harness, workspace: workspace)
      .replacing(field, from: selections)
    setDefaults(updated, in: &document, harness: harness, workspace: workspace)
    write(document)
  }

  public func removeDefault(
    _ field: SessionSelectionField,
    harness: String,
    workspace: String? = nil
  ) {
    saveDefault(field, from: SessionSelections(), harness: harness, workspace: workspace)
  }

  public func conversation(id: String) -> SessionSelectionSnapshot? {
    read().conversations[id]
  }

  /// Captures a new conversation once. Existing snapshots win even when all of
  /// their fields are nil. Native fallback should be used only for new sessions;
  /// adopt existing sessions with captureExistingConversation instead.
  /// Supply capturedDefaults when a pending native creation already froze defaults
  /// before a local conversation ID was available. Empty still means frozen.
  @discardableResult
  public func captureConversation(
    id: String,
    harness: String,
    workspace: String,
    selections: SessionSelections = SessionSelections(),
    nativeFallback: SessionSelections = SessionSelections(),
    capturedDefaults: SessionSelections? = nil
  ) -> SessionSelectionSnapshot {
    var document = read()
    if let existing = document.conversations[id] { return existing }
    let desired = selections.overlaying(
      capturedDefaults ?? defaults(in: document, harness: harness, workspace: workspace)
    )
    let snapshot = SessionSelectionSnapshot(
      harness: harness,
      workspace: workspace,
      selections: desired.overlaying(nativeFallback),
      desiredSelections: desired,
      requiresApplication: true
    )
    document.conversations[id] = snapshot
    write(document)
    return snapshot
  }

  /// Migrates native session metadata without retroactively applying defaults.
  /// Persisting an empty snapshot also protects sessions whose native values are unknown.
  @discardableResult
  public func captureExistingConversation(
    id: String,
    harness: String,
    workspace: String,
    selections: SessionSelections = SessionSelections()
  ) -> SessionSelectionSnapshot {
    var document = read()
    if let existing = document.conversations[id] { return existing }
    let snapshot = SessionSelectionSnapshot(
      harness: harness, workspace: workspace, selections: selections
    )
    document.conversations[id] = snapshot
    write(document)
    return snapshot
  }

  /// Records explicit non-nil choices. Empty tools explicitly replaces the prior tools.
  /// Unknown conversation IDs are left untouched; capture the context first.
  @discardableResult
  public func updateConversation(id: String, selections: SessionSelections) -> SessionSelectionSnapshot? {
    var document = read()
    guard var snapshot = document.conversations[id] else { return nil }
    snapshot.selections = selections.overlaying(snapshot.selections)
    snapshot.desiredSelections = selections.overlaying(snapshot.desiredSelections)
    document.conversations[id] = snapshot
    write(document)
    return snapshot
  }

  /// Acknowledges successful native application without changing captured choices.
  @discardableResult
  public func markApplied(id: String) -> SessionSelectionSnapshot? {
    var document = read()
    guard var snapshot = document.conversations[id] else { return nil }
    snapshot.requiresApplication = false
    document.conversations[id] = snapshot
    write(document)
    return snapshot
  }

  /// Records one explicit choice or clears that field with nil. A cleared field
  /// remains native/unknown; it does not inherit freshly edited defaults.
  @discardableResult
  public func updateConversation(
    id: String,
    field: SessionSelectionField,
    from selections: SessionSelections
  ) -> SessionSelectionSnapshot? {
    var document = read()
    guard var snapshot = document.conversations[id] else { return nil }
    snapshot.selections = snapshot.selections.replacing(field, from: selections)
    snapshot.desiredSelections = snapshot.desiredSelections.replacing(field, from: selections)
    document.conversations[id] = snapshot
    write(document)
    return snapshot
  }

  /// Replaces confirmed native metadata, including nil (for example when a model
  /// has no thinking control). Does not turn observed fallback values into overrides.
  @discardableResult
  public func replaceConfirmedSelections(
    id: String,
    selections: SessionSelections
  ) -> SessionSelectionSnapshot? {
    var document = read()
    guard var snapshot = document.conversations[id] else { return nil }
    guard snapshot.selections != selections else { return snapshot }
    let desired = snapshot.desiredSelections
    snapshot.selections = selections
    snapshot.desiredSelections = SessionSelections(
      model: desired.model == nil ? nil : selections.model,
      thinking: desired.thinking == nil ? nil : selections.thinking,
      permission: desired.permission == nil ? nil : selections.permission,
      tools: desired.tools == nil ? nil : selections.tools
    )
    document.conversations[id] = snapshot
    write(document)
    return snapshot
  }

  private struct Document: Codable {
    var version = 1
    var harnessDefaults: [String: SessionSelections] = [:]
    var workspaceDefaults: [String: [String: SessionSelections]] = [:]
    var conversations: [String: SessionSelectionSnapshot] = [:]
  }

  private func read() -> Document {
    let data = userDefaults.data(forKey: Self.storageKey)
    if data == cachedData, let cachedDocument { return cachedDocument }
    let decoded = data.flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
    let document: Document
    if let decoded, decoded.version == 1 {
      document = decoded
    } else {
      document = Document()
    }
    cachedData = data
    cachedDocument = document
    return document
  }

  private func write(_ document: Document) {
    guard let data = try? JSONEncoder().encode(document) else { return }
    userDefaults.set(data, forKey: Self.storageKey)
    cachedData = data
    cachedDocument = document
  }

  private func storedDefaults(
    in document: Document,
    harness: String,
    workspace: String?
  ) -> SessionSelections {
    if let workspace {
      return document.workspaceDefaults[workspace]?[harness] ?? SessionSelections()
    }
    return document.harnessDefaults[harness] ?? SessionSelections()
  }

  private func defaults(
    in document: Document,
    harness: String,
    workspace: String?
  ) -> SessionSelections {
    let harnessDefaults = (document.harnessDefaults[harness] ?? SessionSelections())
      .overlaying(Self.productDefaults(harness: harness))
    guard let workspace else { return harnessDefaults }
    return (document.workspaceDefaults[workspace]?[harness] ?? SessionSelections())
      .overlaying(harnessDefaults)
  }

  /// The app's starting policy for new conversations, below explicit user
  /// defaults. Never written as an override or applied to imported sessions.
  private static func productDefaults(harness: String) -> SessionSelections {
    let permission: String?
    switch AgentRuntimeKind(rawValue: harness) {
    case .codex: permission = "agent-full-access"
    case .claudeCode, .grokBuild: permission = "bypassPermissions"
    case .openclaw, .hermes, .opencode: permission = "full"
    // Cursor's existing internal value means Full access, not smart review.
    case .cursor: permission = "auto"
    case .pi, .defaultAgent, nil: permission = nil
    }
    return SessionSelections(permission: permission)
  }

  private func setDefaults(
    _ selections: SessionSelections,
    in document: inout Document,
    harness: String,
    workspace: String?
  ) {
    if let workspace {
      var scoped = document.workspaceDefaults[workspace] ?? [:]
      scoped[harness] = selections.isEmpty ? nil : selections
      document.workspaceDefaults[workspace] = scoped.isEmpty ? nil : scoped
    } else {
      document.harnessDefaults[harness] = selections.isEmpty ? nil : selections
    }
  }
}
