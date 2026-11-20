import Foundation

public enum NoteEditError: Error, Equatable, LocalizedError {
  case blockNotFound(String)
  case tableNotFound(String)
  case tableCoordinateOutOfRange
  case artifactKindMismatch
  case boardItemConflict(id: String, currentRevision: String)
  case boardItemExists(String)
  case boardLinkedAssetText(String)
  case boardItemNotText(String)
  case boardSessionLimit(String)
  case pageAssigneeMissing(String)
  case pageAssigneeChanged(String)
  case boardConflictingPatch(String)
  case boardCardIDChanged(String)
  case pageTargetMissing(String)
  case pageMoveIntoOwnSubtree(String)
  case pageDepthExceeded(String)
  case pageSectionNotEmpty(String)
  case pagePositionInvalid(String)
  case pageSubtreeConflict(id: String, currentRevision: String)

  public var errorDescription: String? {
    switch self {
    case .pageTargetMissing(let id): "Page section \(id) does not exist. Read the Page and choose a current section."
    case .pageMoveIntoOwnSubtree(let id): "Page section \(id) cannot move inside itself."
    case .pageDepthExceeded(let id): "Component \(id) would nest more than \(NoteDocument.maximumPageDepth) sections deep."
    case .pageSectionNotEmpty(let id): "Page section \(id) still has contents. Use woven_pages_remove_component and choose promoteChildren, or removeSubtree with its subtreeRevision."
    case .pagePositionInvalid(let id): "\(id) is not a valid place here. An afterID must be a direct child of the chosen parent."
    case .pageSubtreeConflict(let id, _): "Page section \(id) or its contents changed since they were read. Read them again before removing them."
    case .boardItemConflict(let id, let current):
      current.isEmpty ? "Page component \(id) was removed since it was read."
        : "Page component \(id) changed since it was read. Read it again and apply your intended change to the current item."
    case .boardItemExists(let id): "A Page component already exists with ID \(id)."
    case .boardLinkedAssetText(let id): "Page component \(id) shows a linked original. Edit the original artifact, not the component."
    case .boardItemNotText(let id): "Page component \(id) is a table. Use the table tools to change it."
    case .boardSessionLimit(let id): "Page component \(id) already links \(BoardItem.maximumSessions) sessions."
    case .pageAssigneeMissing(let id): "Page task \(id) has no such assignee. Read the Page for its current assignees."
    case .pageAssigneeChanged(let id): "An assignee of Page task \(id) changed meanwhile. Read the Page for its current assignees."
    case .boardConflictingPatch(let message): message
    case .boardCardIDChanged(let id): "A Page component keeps its ID. Replace the content of \(id) without changing its ID."
    case .blockNotFound(let id): "Note block not found: \(id)"
    case .tableNotFound(let id): "Note table not found: \(id)"
    case .tableCoordinateOutOfRange: "The table row or column is out of range."
    case .artifactKindMismatch: "This operation does not match the artifact type."
    }
  }
}
