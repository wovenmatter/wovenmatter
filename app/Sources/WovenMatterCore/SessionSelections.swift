import Foundation

public enum SessionSelectionField: String, Codable, CaseIterable, Sendable {
  case model
  case thinking
  case permission
  case tools
}

/// Harness-native identifiers. A nil default inherits; an empty tools array
/// deliberately selects no tool groups.
public struct SessionSelections: Codable, Equatable, Sendable {
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var tools: [String]?

  public init(
    model: String? = nil,
    thinking: String? = nil,
    permission: String? = nil,
    tools: [String]? = nil
  ) {
    self.model = model
    self.thinking = thinking
    self.permission = permission
    self.tools = tools
  }

  public var isEmpty: Bool {
    model == nil && thinking == nil && permission == nil && tools == nil
  }

  /// Keeps each non-nil selection, using the fallback only for missing fields.
  public func overlaying(_ fallback: Self) -> Self {
    Self(
      model: model ?? fallback.model,
      thinking: thinking ?? fallback.thinking,
      permission: permission ?? fallback.permission,
      tools: tools ?? fallback.tools
    )
  }

  /// Repairs an unfinished initial bundle without losing its other defaults.
  /// A newly chosen model uses native thinking unless the correction explicitly
  /// chooses a level; an obsolete level must not make that model impossible to use.
  public func applyingPendingCorrection(_ correction: Self) -> Self {
    var result = correction.overlaying(self)
    if correction.model != nil, correction.thinking == nil {
      result.thinking = nil
    }
    return result
  }

  /// Replaces one field, including nil, without changing the other fields.
  public func replacing(_ field: SessionSelectionField, from selections: Self) -> Self {
    var result = self
    switch field {
    case .model: result.model = selections.model
    case .thinking: result.thinking = selections.thinking
    case .permission: result.permission = selections.permission
    case .tools: result.tools = selections.tools
    }
    return result
  }
}

/// The existence of a snapshot means defaults have already been considered.
/// Nil fields in a captured session must never consult subsequently edited defaults.
public struct SessionSelectionSnapshot: Codable, Equatable, Sendable {
  public var harness: String
  public var workspace: String
  public var selections: SessionSelections
  /// Explicit choices and defaults captured for application to a new session.
  /// Native fallback metadata is excluded: observing it is not an override request.
  public var desiredSelections: SessionSelections
  /// A new conversation retains pending application across process restarts.
  public var requiresApplication: Bool

  public init(
    harness: String,
    workspace: String,
    selections: SessionSelections,
    desiredSelections: SessionSelections = SessionSelections(),
    requiresApplication: Bool = false
  ) {
    self.harness = harness
    self.workspace = workspace
    self.selections = selections
    self.desiredSelections = desiredSelections
    self.requiresApplication = requiresApplication
  }

  private enum CodingKeys: String, CodingKey {
    case harness, workspace, selections, desiredSelections, requiresApplication
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    harness = try container.decode(String.self, forKey: .harness)
    workspace = try container.decode(String.self, forKey: .workspace)
    selections = try container.decode(SessionSelections.self, forKey: .selections)
    desiredSelections = try container.decode(SessionSelections.self, forKey: .desiredSelections)
    // Older snapshots already represented captured sessions, not pending work.
    requiresApplication = try container.decodeIfPresent(Bool.self, forKey: .requiresApplication) ?? false
  }
}
