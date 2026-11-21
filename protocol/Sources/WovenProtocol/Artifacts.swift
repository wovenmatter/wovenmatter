import Foundation

// Notes, pages, sheets and apps: documents in the library that any machine
// edits through its own server. The newest write wins and the write that lost
// is kept in the artifact's version history.

/// A note, page, sheet or app as lists show it, without its document.
public struct Artifact: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var kind: NoteArtifactKind
  public var title: String
  public var folderID: String?
  public var pinned: Bool
  /// In the Trash. It is kept until it is deleted for good.
  public var trashed: Bool
  public var createdAt: Date
  /// When it was last written, on any machine.
  public var updatedAt: Date
  /// This write. A later write names it as what it was based on.
  public var stamp: String
  /// One line under the title: the start of a note's text, a sheet's size, a
  /// page's component count.
  public var preview: String

  public init(id: String, kind: NoteArtifactKind, title: String, folderID: String?, pinned: Bool, trashed: Bool,
              createdAt: Date, updatedAt: Date, stamp: String, preview: String) {
    self.id = id
    self.kind = kind
    self.title = title
    self.folderID = folderID
    self.pinned = pinned
    self.trashed = trashed
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.stamp = stamp
    self.preview = preview
  }
}

/// An artifact with its document.
public struct ArtifactDocument: Codable, Sendable, Hashable {
  public var artifact: Artifact
  /// The document, as `NoteDocument` JSON.
  public var body: String

  public init(artifact: Artifact, body: String) {
    self.artifact = artifact
    self.body = body
  }
}

/// A write's outcome.
public struct ArtifactWritten: Codable, Sendable, Hashable {
  public var document: ArtifactDocument
  /// The artifact had changed since the version the write was based on (an
  /// agent's edit, or a write from another machine). The write still became
  /// current; the version it replaced unseen is in the version history. The
  /// editor shows the document as it is now.
  public var replacedUnseen: Bool

  public init(document: ArtifactDocument, replacedUnseen: Bool) {
    self.document = document
    self.replacedUnseen = replacedUnseen
  }
}

/// One saved version of an artifact.
public struct ArtifactVersion: Codable, Sendable, Hashable, Identifiable {
  public enum Reason: String, Codable, Sendable, Hashable {
    /// It lost to a write made without seeing it.
    case conflict
    /// Saved while editing, at most every few minutes.
    case checkpoint
    /// The document as it was before a version was restored over it.
    case restore
  }

  public var id: String
  public var artifactID: String
  public var kind: NoteArtifactKind
  public var title: String
  public var savedAt: Date
  public var reason: Reason
  /// The machine whose write this version is.
  public var machineID: String

  public init(id: String, artifactID: String, kind: NoteArtifactKind, title: String, savedAt: Date, reason: Reason,
              machineID: String) {
    self.id = id
    self.artifactID = artifactID
    self.kind = kind
    self.title = title
    self.savedAt = savedAt
    self.reason = reason
    self.machineID = machineID
  }
}

public struct ArtifactVersionDocument: Codable, Sendable, Hashable {
  public var version: ArtifactVersion
  /// The document, as `NoteDocument` JSON.
  public var body: String

  public init(version: ArtifactVersion, body: String) {
    self.version = version
    self.body = body
  }
}

extension ProtocolError.Code {
  /// What the request depended on changed; read it again and retry.
  public static let conflict = ProtocolError.Code(rawValue: "conflict")
}

// MARK: Requests

/// Artifacts in the library, newest first.
public struct ListArtifacts: Request {
  public static let method = "artifacts.list"
  public typealias Reply = [Artifact]
  public var includeTrashed: Bool
  public init(includeTrashed: Bool = false) { self.includeTrashed = includeTrashed }
}

public struct ReadArtifact: Request {
  public static let method = "artifacts.read"
  public typealias Reply = ArtifactDocument
  public var artifactID: String
  public init(artifactID: String) { self.artifactID = artifactID }
}

/// Creates an artifact. With `body` nil it starts as an empty document of its kind.
public struct CreateArtifact: Request {
  public static let method = "artifacts.create"
  public typealias Reply = ArtifactDocument
  public var kind: NoteArtifactKind
  public var title: String
  public var folderID: String?
  public var body: String?
  public init(kind: NoteArtifactKind, title: String = "", folderID: String? = nil, body: String? = nil) {
    self.kind = kind
    self.title = title
    self.folderID = folderID
    self.body = body
  }
}

/// Writes a new title, document or both. `basedOn` is the stamp of the version
/// the writer had; when the artifact has changed since, the write still wins
/// and the version it replaced is kept in the history.
public struct WriteArtifact: Request {
  public static let method = "artifacts.write"
  public typealias Reply = ArtifactWritten
  public var artifactID: String
  public var basedOn: String
  public var title: String?
  public var body: String?
  public init(artifactID: String, basedOn: String, title: String? = nil, body: String? = nil) {
    self.artifactID = artifactID
    self.basedOn = basedOn
    self.title = title
    self.body = body
  }
}

/// Renames, moves, pins, trashes or restores an artifact. Fields left nil stay.
public struct UpdateArtifact: Request {
  public static let method = "artifacts.update"
  public typealias Reply = Artifact
  public var artifactID: String
  public var title: String?
  public var folderID: String?
  /// Takes it out of its folder; wins over `folderID`.
  public var removeFromFolder: Bool?
  public var pinned: Bool?
  public var trashed: Bool?
  public init(artifactID: String, title: String? = nil, folderID: String? = nil, removeFromFolder: Bool? = nil,
              pinned: Bool? = nil, trashed: Bool? = nil) {
    self.artifactID = artifactID
    self.title = title
    self.folderID = folderID
    self.removeFromFolder = removeFromFolder
    self.pinned = pinned
    self.trashed = trashed
  }
}

/// Deletes an artifact and its history for good, in every library.
public struct DeleteArtifact: Request {
  public static let method = "artifacts.delete"
  public typealias Reply = Done
  public var artifactID: String
  public init(artifactID: String) { self.artifactID = artifactID }
}

/// An artifact's saved versions, newest first.
public struct ListArtifactVersions: Request {
  public static let method = "artifacts.versions"
  public typealias Reply = [ArtifactVersion]
  public var artifactID: String
  public init(artifactID: String) { self.artifactID = artifactID }
}

public struct ReadArtifactVersion: Request {
  public static let method = "artifacts.version"
  public typealias Reply = ArtifactVersionDocument
  public var versionID: String
  public init(versionID: String) { self.versionID = versionID }
}

/// Makes a saved version current. The document it replaces is saved as a version first.
public struct RestoreArtifactVersion: Request {
  public static let method = "artifacts.restore"
  public typealias Reply = ArtifactDocument
  public var artifactID: String
  public var versionID: String
  public init(artifactID: String, versionID: String) {
    self.artifactID = artifactID
    self.versionID = versionID
  }
}

/// Applies edits to an app's saved state, key by key, all or none. A key whose
/// version is not the one the edit expects fails with `conflict`.
public struct EditAppState: Request {
  public static let method = "artifacts.appState"
  public typealias Reply = ArtifactStateWriteResult
  public var artifactID: String
  public var edits: [ArtifactStateEdit]
  public init(artifactID: String, edits: [ArtifactStateEdit]) {
    self.artifactID = artifactID
    self.edits = edits
  }
}

/// Carries out what a page task's assignees now say: starts a session on this
/// machine for each one being sent, and stops each one being stopped. The page
/// records the session that runs each assignee.
public struct DispatchPageTask: Request {
  public static let method = "pages.dispatch"
  public typealias Reply = Done
  public var artifactID: String
  public var taskID: String
  public init(artifactID: String, taskID: String) {
    self.artifactID = artifactID
    self.taskID = taskID
  }
}
