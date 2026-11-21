import Foundation
import WovenLibrary
import WovenProtocol

/// Notes, pages, sheets and apps. Any server writes any artifact in its own
/// library; sync carries the write to every other machine.
func registerArtifacts(_ router: inout Router, library: Library, sessions: SessionManager) {
  let tasks = PageTasks(library: library, sessions: sessions)

  router.on(ListArtifacts.self) { request, _ in
    try await library.artifacts(includeTrashed: request.includeTrashed)
  }
  router.on(ReadArtifact.self) { request, _ in
    try await library.artifact(request.artifactID)
  }
  router.on(CreateArtifact.self) { request, _ in
    if let body = request.body { try validate(body, kind: request.kind) }
    return try await library.createArtifact(kind: request.kind, title: request.title, folderID: request.folderID,
                                            body: request.body)
  }
  router.on(WriteArtifact.self) { request, _ in
    if let body = request.body {
      try validate(body, kind: try await library.artifact(request.artifactID).artifact.kind)
    }
    let (document, replaced) = try await library.writeArtifact(request.artifactID, basedOn: request.basedOn,
                                                               title: request.title, body: request.body)
    return ArtifactWritten(document: document, replacedUnseen: replaced)
  }
  router.on(UpdateArtifact.self) { request, _ in
    let folder: String?? = request.removeFromFolder == true ? .some(nil) : request.folderID.map { .some($0) }
    return try await library.updateArtifact(request.artifactID, title: request.title, folderID: folder,
                                            pinned: request.pinned, trashed: request.trashed)
  }
  router.on(DeleteArtifact.self) { request, _ in
    try await library.deleteArtifact(request.artifactID)
    return Done()
  }
  router.on(ListArtifactVersions.self) { request, _ in
    try await library.artifactVersions(request.artifactID)
  }
  router.on(ReadArtifactVersion.self) { request, _ in
    try await library.artifactVersion(request.versionID)
  }
  router.on(RestoreArtifactVersion.self) { request, _ in
    try await library.restoreArtifactVersion(request.artifactID, versionID: request.versionID)
  }
  router.on(EditAppState.self) { request, _ in
    do {
      return try await library.editAppState(request.artifactID, edits: request.edits)
    } catch let error as ArtifactStateError {
      if case .conflict = error { throw ProtocolError(.conflict, error.localizedDescription) }
      throw ProtocolError(.badRequest, error.localizedDescription)
    } catch let error as NoteDocumentSafetyError {
      throw ProtocolError(.badRequest, error.localizedDescription)
    }
  }
  router.on(DispatchPageTask.self) { request, _ in
    try await tasks.dispatch(artifactID: request.artifactID, taskID: request.taskID)
    return Done()
  }
}

/// A document is saved only when it is one this release can read whole and
/// fits the limits, so no writer can leave an artifact nobody can open.
private func validate(_ body: String, kind: NoteArtifactKind) throws {
  do {
    let document = try NoteDocument.editableDocument(from: body)
    guard document.kind == kind else { throw ProtocolError(.badRequest, "The document is not a \(kind.displayName).") }
    if kind == .canvas, body.utf8.count > DocumentLimits.maximumBoardBytes { throw NoteDocumentSafetyError.tooLarge }
  } catch let error as NoteDocumentSafetyError {
    throw ProtocolError(.badRequest, error.localizedDescription)
  }
}

/// Starts and stops the sessions page tasks are assigned to, one dispatch at
/// a time, so sending twice never starts two sessions for one assignee.
private actor PageTasks {
  private let library: Library
  private let sessions: SessionManager

  init(library: Library, sessions: SessionManager) {
    self.library = library
    self.sessions = sessions
  }

  func dispatch(artifactID: String, taskID: String) async throws {
    let page = try await library.artifact(artifactID)
    let document = NoteDocument.decode(page.body)
    guard let task = document.boardItems?[taskID]?.task else { throw ProtocolError(.notFound, "No task \(taskID) on this page.") }
    let title = document.blocks.first { $0.id == taskID }?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let machines = Dictionary(try await library.machines().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    for assignee in task.assignees {
      var updated = assignee
      switch assignee.state {
      case .sending:
        guard assignee.kind == .agent else {
          updated.state = .failed
          updated.message = "Bots cannot take page tasks yet."
          break
        }
        guard assignee.machineID == library.machineID else {
          updated.state = .failed
          updated.message = "Send this task from \(machines[assignee.machineID ?? ""] ?? "the machine the agent runs on")."
          break
        }
        do {
          guard let runtime = assignee.runtimeKind else { throw ProtocolError(.badRequest, "No runtime \(assignee.runtime ?? "").") }
          var folderID = assignee.folderID
          if let id = folderID, try await library.folder(id)?.machineID != library.machineID { folderID = nil }
          let session = try await sessions.create(runtime: runtime, title: title.isEmpty ? "Page task" : title,
                                                  folderID: folderID)
          try await sessions.host(for: session.id).send(
            Self.message(title: title, details: task.details, page: page.artifact.title), attachments: [])
          updated.state = .sent
          updated.conversationID = session.id
          updated.message = nil
        } catch {
          updated.state = .failed
          updated.message = ProtocolError(error).message
        }
      case .stopping:
        if let sessionID = assignee.conversationID, assignee.machineID == library.machineID {
          await sessions.close(sessionID)
        }
        updated.state = .stopped
      case .assigned, .sent, .stopped, .failed:
        continue
      }
      let result = updated
      try await library.changeArtifact(artifactID) { document in
        guard var item = document.boardItems?[taskID], var task = item.task,
              let index = task.assignees.firstIndex(where: { $0.id == result.id }) else { return }
        task.assignees[index] = result
        if result.state == .sent, let sessionID = result.conversationID, !item.sessions.contains(sessionID),
           item.sessions.count < BoardItem.maximumSessions {
          item.sessions.append(sessionID)
        }
        item.task = task
        document.boardItems?[taskID] = item
      }
    }
  }

  /// The first message an assignee's session gets.
  private static func message(title: String, details: String, page: String) -> String {
    var text = title.isEmpty ? "A task" : title
    if !details.isEmpty { text += "\n\n" + details }
    text += "\n\nThis task is on the page “\(page.isEmpty ? "Untitled Page" : page)”."
    return text
  }
}
