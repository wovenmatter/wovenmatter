import Foundation

/// A harness-exposed record, separate from the mutable presentation activity.
/// `id` names the native object/event in its source; revisions retain every
/// observed value. Delta records must have distinct IDs or native revisions.
public struct WorkspaceNativeRunRecord: Codable, Equatable, Sendable {
  public var id: String
  public var revision: String?
  public var runID: String?
  public var kind: String
  /// The complete exposed native record, preserving unknown/non-text fields.
  public var payload: String
  public var contentMode: String
  public var text: String?
  public var projectionJSON: String?
  public var completeness: String

  public init(id: String, revision: String? = nil, runID: String? = nil, kind: String, payload: String,
    contentMode: String = "event", text: String? = nil, projectionJSON: String? = nil,
    completeness: String = "observed") {
    self.id = id; self.revision = revision; self.runID = runID; self.kind = kind; self.payload = payload
    self.contentMode = contentMode; self.text = text; self.projectionJSON = projectionJSON
    self.completeness = completeness
  }

  enum CodingKeys: String, CodingKey {
    case id, revision, runID, kind, payload, contentMode, text, projectionJSON, completeness
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    revision = try c.decodeIfPresent(String.self, forKey: .revision)
    runID = try c.decodeIfPresent(String.self, forKey: .runID)
    kind = try c.decode(String.self, forKey: .kind)
    payload = try c.decode(String.self, forKey: .payload)
    contentMode = try c.decodeIfPresent(String.self, forKey: .contentMode) ?? "event"
    text = try c.decodeIfPresent(String.self, forKey: .text)
    projectionJSON = try c.decodeIfPresent(String.self, forKey: .projectionJSON)
    completeness = try c.decodeIfPresent(String.self, forKey: .completeness) ?? "observed"
  }
}

/// The namespace must identify the execution host and native store/connection;
/// native IDs alone (including Durable's numeric IDs) are not globally unique.
/// Conversation, run, agent and harness attribution come from the trusted app
/// connection rather than the supplied native payload.
public struct WorkspaceNativeRunRecordBatch: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var sourceID: String
  public var nativeSessionID: String
  public var records: [WorkspaceNativeRunRecord]

  public init(schemaVersion: Int = 1, sourceID: String, nativeSessionID: String,
    records: [WorkspaceNativeRunRecord]) {
    self.schemaVersion = schemaVersion; self.sourceID = sourceID
    self.nativeSessionID = nativeSessionID; self.records = records
  }
}
