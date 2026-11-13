import Foundation

/// The `woven_pages_*` tools as every host runs them: the Mac app, the headless
/// library host and an iPhone or iPad. Hosts differ only in storage, receipts
/// and who the caller is; parsing, edit rules, attribution and replies are here.
public enum PageTool {
  /// Maps `woven_pages_*` writes to one revision-checked note mutation. No field
  /// here can carry attribution; the host stamps the caller it authorized.
  public static func request(_ command: WovenMatterToolCommand, requestID: String) throws -> NoteEditingRequest {
    guard command.group == .notes, command.isPageCommand else {
      throw WorkspaceToolError.invalid("Choose a Page operation.")
    }
    let pageID = try command.required("note-id")
    let operations: [NoteEditOperation]
    var revision: String?
    switch command.action {
    case "page-update":
      revision = try command.required("revision")
      var changes: [NoteEditOperation] = [.page(.init(action: .requirePage))]
      if let title = command.options["title"] {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 1_024 else {
          throw WorkspaceToolError.invalid("A Page title must contain text and be at most 1,024 bytes.")
        }
        changes.append(.setTitle(title))
      }
      if let purpose = command.options["purpose"] {
        try requirePurpose(purpose)
        changes.append(.page(.init(action: .setPurpose, purpose: purpose)))
      }
      guard changes.count > 1 else { throw WorkspaceToolError.invalid("Supply a title or purpose to change.") }
      operations = changes
    case "page-add-component":
      let kind: PageComponentKind? = try choice(command, "kind")
      let block: NoteBlock? = command.options["json"] == nil ? nil : try decode(NoteBlock.self, command: command, label: "block")
      operations = [.page(.init(action: .add, id: requestID, kind: kind, block: block, patch: try patch(command),
                                assetID: command.options["asset-id"], position: position(command)))]
    case "page-update-component":
      let patch = try patch(command)
      let block: NoteBlock? = command.options["json"] == nil ? nil : try decode(NoteBlock.self, command: command, label: "block")
      guard patch != BoardItemPatch() || block != nil else { throw WorkspaceToolError.invalid("Supply at least one field to change.") }
      operations = [.page(.init(action: .update, id: try command.required("id"),
                                expectedRevision: try command.required("component-revision"), block: block, patch: patch))]
    case "page-move-component":
      operations = [.page(.init(action: .move, id: try command.required("id"),
                                expectedRevision: command.options["component-revision"],
                                expectedSubtreeRevision: command.options["subtree-revision"], position: position(command)))]
    case "page-remove-component":
      let removal: PageEdit.Removal? = try choice(command, "removal")
      operations = [.page(.init(action: .remove, id: try command.required("id"),
                                expectedRevision: command.options["component-revision"],
                                expectedSubtreeRevision: command.options["subtree-revision"], removal: removal))]
    case "page-link-session", "page-unlink-session":
      let sessionID = try command.required("session")
      guard let uuid = UUID(uuidString: sessionID) else { throw WorkspaceToolError.invalid("sessionID must be a conversation UUID.") }
      operations = [.page(.init(action: command.action == "page-link-session" ? .linkSession : .unlinkSession,
                                id: try command.required("id"), sessionID: uuid.uuidString.lowercased()))]
    default:
      throw WorkspaceToolError.invalid("Unsupported Page operation: \(command.action).")
    }
    return .init(command: .apply, noteID: pageID, expectedRevision: revision, operations: operations)
  }

  public static func requirePurpose(_ purpose: String) throws {
    guard purpose.utf8.count <= NoteDocument.maximumBoardPurposeBytes else {
      throw WorkspaceToolError.invalid("A Page purpose must be at most \(NoteDocument.maximumBoardPurposeBytes) bytes.")
    }
  }

  /// The document of a new, empty Page.
  public static func newPageContent(purpose: String?) throws -> String {
    let purpose = purpose ?? ""
    try requirePurpose(purpose)
    return try NoteDocument(kind: .canvas, boardPurpose: purpose.isEmpty ? nil : purpose, pageNodes: [:]).encoded()
  }

  /// The outcome of one agent write, before the host stores it.
  public struct Edit: Equatable, Sendable {
    public var title: String
    public var document: NoteDocument
    /// False when the write changed nothing, so the host keeps the stored revision.
    public var changed: Bool
    /// Task updates and saved inputs are frequent and small. Hosts coalesce
    /// their retained versions unless this is set.
    public var forceCheckpoint: Bool
  }

  /// Applies an agent's note or Page operations to a stored document. The revision
  /// check, receipt and storage stay with the host. `missingAsset` receives the
  /// asset IDs this write newly links and returns one that is not available.
  public static func apply(_ operations: [NoteEditOperation], title: String, content: String, pageID: String,
                           actor: BoardActor, at timestamp: String,
                           missingAsset: (Set<String>) throws -> String?) throws -> Edit {
    let current = try NoteDocument.editableDocument(from: content)
    guard !operations.isEmpty else { return Edit(title: title, document: current, changed: false, forceCheckpoint: false) }
    try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: current)
    let forceCheckpoint = !operations.allSatisfy {
      switch $0 {
      case .page(let edit): edit.action != .setPurpose && edit.action != .remove
      case .artifactState: true
      default: false
      }
    }
    if current.kind == .html, operations.contains(where: { if case .setTitle = $0 { true } else { false } }) {
      throw NoteEditError.artifactKindMismatch
    }
    var document = current
    let updatedTitle = try document.apply(operations) ?? title
    // Repeating an idempotent edit must not make other writers' revisions stale, and a
    // first read-only pass over an older Board must not migrate it.
    let unchanged = updatedTitle == title && (document == current.normalized()
      || (document.kind == .canvas && document == current.materializedPage().normalized()))
    if document.kind == .canvas || document.kind == .html, unchanged {
      return Edit(title: title, document: document, changed: false, forceCheckpoint: forceCheckpoint)
    }
    if document.kind == .canvas {
      // A first write migrates an older Board. Compare it to its own migrated form, so the
      // migration itself is attributed to nobody and only this edit is stamped.
      let old = document.pageNodes == nil ? current : current.materializedPage()
      try requireNewAssets(old: old, new: document, pageID: pageID, missingAsset: missingAsset)
      document.stampBoardChanges(from: old, actor: actor, at: timestamp)
      if try document.encoded().utf8.count > NoteDocument.maximumBoardBytes { throw RemoteNoteEditError.operationTooLarge }
    }
    return Edit(title: updatedTitle, document: document, changed: true, forceCheckpoint: forceCheckpoint)
  }

  /// A newly linked original must exist now. A link that already existed is kept
  /// even if its original is gone, and reads report it as unavailable.
  static func requireNewAssets(old: NoteDocument, new: NoteDocument, pageID: String,
                               missingAsset: (Set<String>) throws -> String?) throws {
    // Compare per component: a new one must not inherit another's retained missing link.
    let added = Set((new.canvas ?? [:]).compactMap { id, placement -> String? in
      placement.assetID == old.canvas?[id]?.assetID ? nil : placement.assetID
    })
    guard !added.isEmpty else { return }
    guard !added.contains(pageID) else { throw WorkspaceToolError.invalid("A Page cannot link to itself.") }
    if let missing = try missingAsset(added) {
      throw WorkspaceToolError.notFound("The linked asset \(missing) is not available. Create it first, then link its ID.")
    }
  }

  /// A replay acknowledges the original revision; it never returns old contents.
  public static func acknowledgement(pageID: String, title: String?, revision: String?, replayed: Bool,
                                     componentID: String?, document: NoteDocument?,
                                     assets: [String: BoardAssetSummary]) throws -> GatewayJSONValue {
    var object: [String: GatewayJSONValue] = [
      "pageID": .string(pageID),
      "revision": revision.map(GatewayJSONValue.string) ?? .null,
      "replayed": .bool(replayed),
    ]
    if let title { object["title"] = .string(title) }
    if let componentID { object["componentID"] = .string(componentID) }
    if let componentID, let document, document.blocks.contains(where: { $0.id == componentID }) {
      object["componentRevision"] = .string(document.boardItemRevision(for: componentID))
      object["component"] = try document.pageComponentValue(id: componentID, assets: assets)
    }
    return .object(object)
  }

  /// The asset a component links, for looking up its summary.
  public static func linkedAssetIDs(_ document: NoteDocument?, componentID: String?) -> [String] {
    guard let componentID else { return [] }
    return document?.canvas?[componentID]?.assetID.map { [$0] } ?? []
  }

  /// The failed write changed nothing, so this reports current state an agent can
  /// use directly. It says the same in text for clients that drop structure.
  public static func conflict(pageID: String, componentID: String?, stored: NoteDocument?, revision: String?,
                              assets: [String: BoardAssetSummary]) -> WovenMatterToolResponse {
    var object: [String: GatewayJSONValue] = ["pageID": .string(pageID)]
    var message = componentID.map { "Page component \($0) changed since it was read." } ?? "The Page changed since it was read."
    if let stored {
      // Reads project an unmigrated Page, so tokens here match what the write compared.
      let document = stored.materializedPage()
      let revision = revision ?? ""
      object["currentRevision"] = .string(revision)
      message += " Current document revision: \(revision)."
      if let componentID {
        object["componentID"] = .string(componentID)
        if document.blocks.contains(where: { $0.id == componentID }) {
          let current = document.boardItemRevision(for: componentID)
          object["currentComponentRevision"] = .string(current)
          object["currentSubtreeRevision"] = .string(document.pageSubtreeRevision(for: componentID))
          object["component"] = try? document.pageComponentValue(id: componentID, assets: assets)
          message += " Current component revision: \(current)."
        } else {
          object["componentRemoved"] = .bool(true)
          message += " The component no longer exists."
        }
      }
    }
    message += " Apply your intended change to the current data and retry with a new requestID."
    return .init(success: false, result: .object(object), error: message, code: "revision_conflict")
  }

  /// The component a write failed on, when the failure is a revision conflict.
  /// `.some(nil)` is a document-level conflict.
  public static func conflictComponent(_ error: Error) -> String?? {
    switch error {
    case NoteEditError.boardItemConflict(let id, _): return .some(id)
    case NoteEditError.pageSubtreeConflict(let id, _): return .some(id)
    default: return nil
    }
  }

  private static func position(_ command: WovenMatterToolCommand) -> PagePosition {
    PagePosition(parentID: command.options["parent-id"], afterID: command.options["after-id"], atStart: command.options["at-start"] != nil)
  }

  private static func choice<T: RawRepresentable>(_ command: WovenMatterToolCommand, _ key: String) throws -> T? where T.RawValue == String {
    guard let raw = command.options[key] else { return nil }
    guard let value = T(rawValue: raw) else { throw WorkspaceToolError.invalid("Unsupported \(key): \(raw).") }
    return value
  }

  private static func patch(_ command: WovenMatterToolCommand) throws -> BoardItemPatch {
    func bounded(_ key: String, _ label: String, _ limit: Int) throws -> String? {
      guard let value = command.options[key] else { return nil }
      guard value.utf8.count <= limit else { throw WorkspaceToolError.invalid("\(label) must be at most \(limit) bytes.") }
      return value
    }
    let role: BoardItemRole? = try choice(command, "role")
    let status: BoardTaskStatus? = try choice(command, "status")
    let review: BoardReviewState? = try choice(command, "review")
    return BoardItemPatch(title: try bounded("title", "A title", 1_024), text: try bounded("text", "Component text", 256 * 1_024),
                          role: role, status: status,
                          assignee: try bounded("assignee", "An assignee", 1_024),
                          outcome: try bounded("outcome", "An outcome", BoardTask.maximumOutcomeBytes),
                          clearTask: command.options["clear-task"] != nil ? true : nil,
                          review: review,
                          clearReview: command.options["clear-review"] != nil ? true : nil,
                          lastChange: try bounded("last-change", "lastChange", BoardItem.maximumLastChangeBytes))
  }

  private static func decode<T: Decodable>(_ type: T.Type, command: WovenMatterToolCommand, label: String) throws -> T {
    do { return try JSONDecoder().decode(type, from: Data(command.required("json").utf8)) }
    catch { throw WorkspaceToolError.invalid("Invalid \(label): \(error.localizedDescription)") }
  }
}
