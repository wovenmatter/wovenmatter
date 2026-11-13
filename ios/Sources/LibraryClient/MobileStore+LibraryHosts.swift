import Foundation
import WovenMatterShared

extension MobileStore {
  /// Moves this replica to another host of the same library set: any Mac or
  /// Linux member, when the one it synced with is offline. Every host holds the
  /// same notes, folders and sessions under the same IDs, but revisions and
  /// change cursors are each host's own. So the host's snapshot replaces the
  /// revision baselines, and each pending edit is rebased by content:
  /// - already on the host (sent before the move): acknowledged;
  /// - the host still has the version the edit started from: resent there;
  /// - the host has another version: a conflict that keeps both;
  /// - the host does not have the note yet (its previous host had not
  ///   forwarded it): created there from this phone's copy.
  /// `bodies` are the host's full versions of notes whose snapshot entry
  /// left the content out. Nothing local is dropped.
  public func rebindLibrary(to snapshot: LibrarySnapshot, bodies: [String: LibraryNote]) throws {
    try transaction { next in
      guard next.pairingTransitionWorkspaceID == nil else { throw Failure.wrongWorkspace }
      var remote = Dictionary(snapshot.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      for (id, body) in bodies where body.contentIncluded && remote[id] != nil { remote[id] = body }
      let remoteFolders = Dictionary(snapshot.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      func same(_ lhs: LibraryNote, _ rhs: LibraryNote?) -> Bool {
        guard let rhs, lhs.contentIncluded, rhs.contentIncluded else { return false }
        return lhs.title == rhs.title && lhs.content == rhs.content && lhs.folderID == rhs.folderID
      }
      let deviceID = next.deviceID
      var outbox: [MobileOutboxEntry] = []
      var rebased = Set<String>()
      for entry in next.outbox {
        var mutation = entry.mutation
        let id = mutation.resourceID
        switch mutation.kind {
        case .createNote, .updateNote:
          guard var local = next.notes[id], next.conflicts[id] == nil else { continue }
          rebased.insert(id)
          if let current = remote[id] {
            if same(current, local) {
              next.notes[id] = current; next.bases[id] = current
            } else if current.contentIncluded, mutation.kind == .updateNote ? same(current, next.bases[id]) : false {
              local.revision = current.revision; next.notes[id] = local; next.bases[id] = current
              outbox.append(.init(mutation: Self.mutation(for: local, kind: .updateNote, deviceID: deviceID)))
            } else {
              next.conflicts[id] = .init(base: next.bases[id], local: local, remote: current,
                reason: "This note changed on another device while your edit waited to sync here. Both versions are preserved.")
              next.bases[id] = current
            }
          } else {
            local.revision = 0; next.notes[id] = local; next.bases.removeValue(forKey: id)
            outbox.append(.init(mutation: Self.mutation(for: local, kind: .createNote, deviceID: deviceID)))
          }
        case .deleteNote:
          rebased.insert(id)
          guard let current = remote[id] else { next.pendingNoteDeletions?.removeValue(forKey: id); continue }
          if same(current, next.pendingNoteDeletions?[id]) {
            next.pendingNoteDeletions?[id] = current; next.bases[id] = current
            outbox.append(.init(mutation: .init(deviceID: deviceID, kind: .deleteNote, resourceID: id, expectedRevision: current.revision)))
          } else if let saved = next.pendingNoteDeletions?.removeValue(forKey: id) {
            // Edited elsewhere before the deletion reached it: keep both.
            next.notes[id] = saved; next.deletedNotes.remove(id)
            next.conflicts[id] = .init(base: saved, local: saved, remote: current,
              reason: "This note changed on another device before your deletion reached it. Its contents have been preserved.")
          }
        case .createFolder:
          if remoteFolders[id] == nil { mutation.expectedRevision = nil; outbox.append(.init(mutation: mutation)) }
        case .renameFolder:
          if let folder = remoteFolders[id] { mutation.expectedRevision = folder.revision; outbox.append(.init(mutation: mutation)) }
          else if let local = next.folders[id], let execution = local.execution {
            outbox.append(.init(mutation: .init(deviceID: deviceID, kind: .createFolder, resourceID: id, title: local.name, folderExecution: execution)))
          }
        case .deleteFolder:
          if let folder = remoteFolders[id] {
            mutation.expectedRevision = folder.revision; next.pendingFolderDeletions?[id] = folder
            outbox.append(.init(mutation: mutation))
          } else { next.pendingFolderDeletions?.removeValue(forKey: id) }
        }
      }
      next.outbox = outbox
      // Clean notes take the host's version. A clean note the host lacks came
      // from a host that had not forwarded it yet: the phone's copy creates it.
      next.localRevisionParents = [:]
      next.deletedNotes = Set(next.pendingNoteDeletions?.keys.map { $0 } ?? [])
      for (id, local) in next.notes where !rebased.contains(id) && next.conflicts[id] == nil {
        if let current = remote[id] {
          next.bases.removeValue(forKey: id)
          next.notes[id] = current
          if current.contentIncluded { next.uncachedNoteIDs.remove(id); next.bases[id] = current } else { next.uncachedNoteIDs.insert(id); next.bases[id] = current }
        } else if local.contentIncluded, !next.uncachedNoteIDs.contains(id) {
          var created = local; created.revision = 0
          next.notes[id] = created; next.bases.removeValue(forKey: id)
          next.outbox.append(.init(mutation: Self.mutation(for: created, kind: .createNote, deviceID: deviceID)))
          next.rebindRecreatedNoteIDs = (next.rebindRecreatedNoteIDs ?? []).union([id])
        } else {
          next.notes.removeValue(forKey: id); next.bases.removeValue(forKey: id); next.uncachedNoteIDs.remove(id)
        }
      }
      for (id, current) in remote where next.notes[id] == nil && next.pendingNoteDeletions?[id] == nil {
        Self.remoteNote(current, state: &next)
      }
      for (id, conflict) in next.conflicts {
        if let current = remote[id], conflict.remote?.revision != current.revision { next.conflicts[id]?.remote = current }
        Self.mergePageConflict(id, state: &next)
      }
      let pendingFolders = next.folders.filter { id, _ in next.outbox.contains { $0.mutation.resourceID == id } }
      next.folders = remoteFolders.filter { next.pendingFolderDeletions?[$0.key] == nil }.merging(pendingFolders) { _, local in local }
      // Sessions: the host's list of every session on every device.
      let changed = snapshot.conversations.filter { next.conversations[$0.id] != $0 }.map(\.id)
      next.dirtyTranscriptIDs = (next.dirtyTranscriptIDs ?? []).union(changed)
      let incoming = Set(snapshot.conversations.map(\.id))
      next.centralConversationIDs = incoming; next.centralDeletedConversationIDs = []
      let execution = next.conversations.filter { next.executionConversationIDs?.contains($0.key) == true }
      next.conversations = Dictionary(snapshot.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        .merging(execution) { _, local in local }
      next.cursor = snapshot.cursor
      next.hasLibrarySnapshot = true
      next.workspaceID = snapshot.workspaceID; next.detachedWorkspaceID = nil
    }
  }

  /// Notes whose host version must be fetched before a move: pending edits are
  /// compared by content, and clean notes must not show an older body under the
  /// new host's revision.
  public func notesNeedingBodies(for snapshot: LibrarySnapshot) -> [String] {
    snapshot.notes.filter { !$0.contentIncluded && ($0.kind == nil || $0.kind == .note || state.isDirty($0.id) || state.pendingNoteDeletions?[$0.id] != nil) }.map(\.id)
  }
}
