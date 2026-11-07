import Foundation

/// One saved value of an HTML Artifact, stored in the Artifact's own document so
/// library history, recovery and replication apply without separate storage.
public struct ArtifactStateEntry: Codable, Equatable, Sendable {
  /// `nil` is a tombstone and is omitted from JSON. `.null` is a saved JSON null.
  public var value: GatewayJSONValue?
  /// At least 1, and it only ever increases for a key while its entry is retained.
  public var version: Int
  /// Stamped by the writing host; no edit can supply it.
  public var updatedAt: String

  public init(value: GatewayJSONValue?, version: Int, updatedAt: String) {
    self.value = value; self.version = version; self.updatedAt = updatedAt
  }

  public var isTombstone: Bool { value == nil }

  private enum CodingKeys: String, CodingKey { case value, version, updatedAt }

  // Synthesized optional coding cannot tell a saved null from a tombstone.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    value = values.contains(.value) ? try values.decode(GatewayJSONValue.self, forKey: .value) : nil
    version = try values.decode(Int.self, forKey: .version)
    updatedAt = try values.decode(String.self, forKey: .updatedAt)
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    if let value { try values.encode(value, forKey: .value) }
    try values.encode(version, forKey: .version)
    try values.encode(updatedAt, forKey: .updatedAt)
  }
}

/// One key's compare-and-swap. It names no document and carries no timestamp: the
/// view binds the Artifact, and the host stamps the write.
public struct ArtifactStateEdit: Codable, Equatable, Sendable {
  public enum Action: String, Codable, Sendable { case set, remove }
  public var action: Action
  public var key: String
  /// Required for `set`. A JSON null decodes to `.null`, not to a missing value.
  public var value: GatewayJSONValue?
  /// The version that was read. `nil` requires that the key has no entry at all.
  public var expectedVersion: Int?

  public init(action: Action, key: String, value: GatewayJSONValue? = nil, expectedVersion: Int? = nil) {
    self.action = action; self.key = key; self.value = value; self.expectedVersion = expectedVersion
  }

  private enum CodingKeys: String, CodingKey { case action, key, value, expectedVersion }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    action = try values.decode(Action.self, forKey: .action)
    key = try values.decode(String.self, forKey: .key)
    value = values.contains(.value) ? try values.decode(GatewayJSONValue.self, forKey: .value) : nil
    expectedVersion = try values.decodeIfPresent(Int.self, forKey: .expectedVersion)
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(action, forKey: .action)
    try values.encode(key, forKey: .key)
    if let value { try values.encode(value, forKey: .value) }
    try values.encodeIfPresent(expectedVersion, forKey: .expectedVersion)
  }
}

/// The derived view a renderer boots from. It is never stored.
public struct ArtifactStateSnapshot: Codable, Equatable, Sendable {
  public static let empty = ArtifactStateSnapshot()
  /// Live values only. A saved `.null` is present.
  public var values: [String: GatewayJSONValue]
  /// Every retained entry, including tombstones, so a removed key can be re-created.
  public var versions: [String: Int]

  public init(values: [String: GatewayJSONValue] = [:], versions: [String: Int] = [:]) {
    self.values = values; self.versions = versions
  }
}

public struct ArtifactStateWriteResult: Codable, Equatable, Sendable {
  public var noteID: String
  public var key: String
  /// 0 when the key stays absent.
  public var version: Int
  /// False means nothing was written and the note revision did not move.
  public var changed: Bool
  public var revision: String
  public var snapshot: ArtifactStateSnapshot

  public init(noteID: String, key: String, version: Int, changed: Bool, revision: String, snapshot: ArtifactStateSnapshot) {
    self.noteID = noteID; self.key = key; self.version = version
    self.changed = changed; self.revision = revision; self.snapshot = snapshot
  }
}

public enum ArtifactStateLimits {
  public static let maximumKeys = 256
  public static let maximumTombstones = 256
  public static let maximumValueBytes = 64 * 1_024
  public static let maximumTotalBytes = 256 * 1_024
  /// Scripts may use 256 characters after the prefix, which can take more bytes.
  public static let maximumKeyBytes = 1_024
  public static let maximumDepth = 32
  public static let maximumNodes = 20_000
  public static let maximumObjectKeyBytes = 4_096
  /// Custom app state and automatic form state. Nothing else can be read back by a page.
  public static let keyPrefixes = ["app:", "form:"]
}

public enum ArtifactStateError: LocalizedError, Equatable, Sendable {
  /// `current` is the latest entry, or nil when the key has none.
  case conflict(key: String, current: ArtifactStateEntry?)
  case invalidKey(String)
  case invalidEdit(String)
  case invalidValue(String)
  case valueTooLarge(String)
  case tooManyKeys
  case stateTooLarge
  case notArtifact

  public var errorDescription: String? {
    switch self {
    case .conflict(let key, let current):
      "Artifact state key \(key) changed since it was read. Its current version is \(current?.version ?? 0). Read it again and apply your change to the current value."
    case .invalidKey(let key):
      "Artifact state key \(key.prefix(80)) is invalid. A key starts with app: or form:, has at most \(ArtifactStateLimits.maximumKeyBytes) bytes and contains no control characters."
    case .invalidEdit(let message): message
    case .invalidValue(let message): message
    case .valueTooLarge(let key):
      "The value of Artifact state key \(key.prefix(80)) exceeds \(ArtifactStateLimits.maximumValueBytes) bytes."
    case .tooManyKeys: "This Artifact already saves \(ArtifactStateLimits.maximumKeys) keys. Remove one before adding another."
    case .stateTooLarge: "This Artifact's saved state exceeds \(ArtifactStateLimits.maximumTotalBytes) bytes."
    case .notArtifact: "Only an Artifact can save state."
    }
  }

  /// Stable machine-readable code for tool and bridge responses.
  public var code: String {
    switch self {
    case .conflict: "conflict"
    case .invalidKey: "invalid_key"
    case .invalidEdit: "invalid_edit"
    case .invalidValue: "invalid_value"
    case .valueTooLarge: "value_too_large"
    case .tooManyKeys: "too_many_keys"
    case .stateTooLarge: "state_too_large"
    case .notArtifact: "not_artifact"
    }
  }
}

public extension NoteDocument {
  /// The bootstrap a renderer receives. Tombstones keep a version but no value.
  var artifactStateSnapshot: ArtifactStateSnapshot {
    var snapshot = ArtifactStateSnapshot()
    for (key, entry) in artifactState ?? [:] {
      snapshot.versions[key] = entry.version
      if let value = entry.value { snapshot.values[key] = value }
    }
    return snapshot
  }

  /// Applies the edits atomically against this document's state: either every edit
  /// succeeds or the document is unchanged. Returns whether anything changed.
  @discardableResult
  mutating func applyArtifactStateEdits(_ edits: [ArtifactStateEdit], at timestamp: String) throws -> Bool {
    guard kind == .html else { throw ArtifactStateError.notArtifact }
    guard timestamp.utf8.count <= 64 else { throw ArtifactStateError.invalidEdit("The Artifact state timestamp is invalid.") }
    var state = artifactState ?? [:]
    var changed = false
    for edit in edits {
      try Self.validateArtifactKey(edit.key)
      let current = state[edit.key]
      if let expected = edit.expectedVersion, expected < 1 {
        throw ArtifactStateError.invalidEdit("expectedVersion must be at least 1, or omitted for a new key.")
      }
      switch edit.action {
      case .set:
        guard let value = edit.value else { throw ArtifactStateError.invalidEdit("Setting Artifact state requires a value.") }
        try Self.validateArtifactValue(value, key: edit.key)
        // The outcome already holds, as after a retry whose acknowledgement was lost.
        if current?.value == value { continue }
        try Self.requireArtifactVersion(edit, current: current)
        state[edit.key] = ArtifactStateEntry(value: value, version: (current?.version ?? 0) + 1, updatedAt: timestamp)
      case .remove:
        guard edit.value == nil else { throw ArtifactStateError.invalidEdit("Removing Artifact state does not take a value.") }
        guard let current, !current.isTombstone else { continue }
        try Self.requireArtifactVersion(edit, current: current)
        state[edit.key] = ArtifactStateEntry(value: nil, version: current.version + 1, updatedAt: timestamp)
      }
      changed = true
    }
    guard changed else { return false }
    guard state.values.filter({ !$0.isTombstone }).count <= ArtifactStateLimits.maximumKeys else { throw ArtifactStateError.tooManyKeys }
    try Self.evictArtifactTombstones(&state)
    artifactState = state
    return true
  }

  /// Rejects an oversized or malformed stored state before it can be edited further.
  func validateArtifactState() throws {
    guard let artifactState else { return }
    guard kind == .html else { throw NoteDocumentSafetyError.unsupportedFormat }
    var live = 0, tombstones = 0
    for (key, entry) in artifactState {
      do { try Self.validateArtifactKey(key) } catch { throw NoteDocumentSafetyError.unsupportedFormat }
      guard entry.version >= 1, entry.updatedAt.utf8.count <= 64 else { throw NoteDocumentSafetyError.unsupportedFormat }
      if let value = entry.value {
        live += 1
        do { try Self.validateArtifactValue(value, key: key) } catch { throw NoteDocumentSafetyError.unsupportedFormat }
      } else { tombstones += 1 }
    }
    guard live <= ArtifactStateLimits.maximumKeys, tombstones <= ArtifactStateLimits.maximumTombstones,
          Self.artifactStateBytes(artifactState) <= ArtifactStateLimits.maximumTotalBytes else {
      throw NoteDocumentSafetyError.tooLarge
    }
  }

  /// A later writer of the same document's code or structure must not touch state.
  func replacingArtifactState(with state: [String: ArtifactStateEntry]?) -> NoteDocument {
    var copy = self; copy.artifactState = state; return copy
  }

  /// Reconciles state carried by a whole-document draft with the row it lands on. A draft
  /// that did not touch a key takes the current entry, so a stale code draft cannot rewind
  /// saved input. A key both sides changed differently throws `conflict` for recovery to keep.
  static func mergeArtifactState(base: [String: ArtifactStateEntry]?, draft: [String: ArtifactStateEntry]?,
                                 current: [String: ArtifactStateEntry]?, at timestamp: String) throws -> [String: ArtifactStateEntry]? {
    let baseState = base ?? [:], draftState = draft ?? [:]
    var merged = current ?? [:]
    var changed = false
    for key in Set(baseState.keys).union(draftState.keys).sorted() {
      let wanted = draftState[key]?.value
      guard wanted != baseState[key]?.value, wanted != merged[key]?.value else { continue }
      guard merged[key]?.value == baseState[key]?.value else {
        throw ArtifactStateError.conflict(key: key, current: merged[key])
      }
      let version = max(merged[key]?.version ?? 0, draftState[key]?.version ?? 0) + 1
      merged[key] = ArtifactStateEntry(value: wanted, version: version, updatedAt: timestamp)
      changed = true
    }
    return changed ? merged : current
  }

  private static func validateArtifactKey(_ key: String) throws {
    guard key.utf8.count <= ArtifactStateLimits.maximumKeyBytes,
          ArtifactStateLimits.keyPrefixes.contains(where: { key.hasPrefix($0) && key.utf8.count > $0.utf8.count }),
          !key.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
      throw ArtifactStateError.invalidKey(key)
    }
  }

  private static func requireArtifactVersion(_ edit: ArtifactStateEdit, current: ArtifactStateEntry?) throws {
    guard edit.expectedVersion == current?.version else {
      throw ArtifactStateError.conflict(key: edit.key, current: current)
    }
  }

  private static func validateArtifactValue(_ value: GatewayJSONValue, key: String) throws {
    var nodes = 0
    func visit(_ value: GatewayJSONValue, depth: Int) throws {
      nodes += 1
      guard depth <= ArtifactStateLimits.maximumDepth else { throw ArtifactStateError.invalidValue("Artifact state may nest at most \(ArtifactStateLimits.maximumDepth) levels.") }
      guard nodes <= ArtifactStateLimits.maximumNodes else { throw ArtifactStateError.invalidValue("An Artifact state value may contain at most \(ArtifactStateLimits.maximumNodes) values.") }
      switch value {
      case .object(let fields):
        for (name, child) in fields {
          guard name.utf8.count <= ArtifactStateLimits.maximumObjectKeyBytes else {
            throw ArtifactStateError.invalidValue("An Artifact state object key exceeds \(ArtifactStateLimits.maximumObjectKeyBytes) bytes.")
          }
          try visit(child, depth: depth + 1)
        }
      case .array(let children):
        for child in children { try visit(child, depth: depth + 1) }
      case .number(let number):
        guard number.isFinite else { throw ArtifactStateError.invalidValue("Artifact state numbers must be finite.") }
      case .string, .bool, .null:
        break
      }
    }
    try visit(value, depth: 0)
    guard let bytes = try? JSONEncoder().encode(value) else { throw ArtifactStateError.invalidValue("This Artifact state value is not valid JSON.") }
    guard bytes.count <= ArtifactStateLimits.maximumValueBytes else { throw ArtifactStateError.valueTooLarge(key) }
  }

  private static func artifactStateBytes(_ state: [String: ArtifactStateEntry]) -> Int {
    (try? JSONEncoder().encode(state).count) ?? .max
  }

  /// A tombstone only protects a stale writer from a recreated key, so it gives way
  /// before live data does. Evicting one still fails such a writer: it expected a
  /// version and the key now has none.
  private static func evictArtifactTombstones(_ state: inout [String: ArtifactStateEntry]) throws {
    var tombstones = state.filter(\.value.isTombstone)
      .sorted { ($0.value.updatedAt, $0.key) < ($1.value.updatedAt, $1.key) }.map(\.key)[...]
    while tombstones.count > ArtifactStateLimits.maximumTombstones, let oldest = tombstones.popFirst() {
      state.removeValue(forKey: oldest)
    }
    while artifactStateBytes(state) > ArtifactStateLimits.maximumTotalBytes {
      guard let oldest = tombstones.popFirst() else { throw ArtifactStateError.stateTooLarge }
      state.removeValue(forKey: oldest)
    }
  }
}
