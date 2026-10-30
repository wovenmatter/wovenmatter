import CryptoKit
import Foundation
import SQLite3
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Central library transfer", .serialized)
struct LibraryTransferTests {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "library-transfer-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
  }
  private func database(_ root: URL, _ name: String) async throws -> WorkspaceDatabase {
    do {
    let directory = root.appending(path: name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    _ = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: name, ownerDeviceID: UUID())
    return database
    } catch { throw WorkspaceDatabaseError.execute("Creating \(name) fixture: \(error)") }
  }
  private func create(_ database: WorkspaceDatabase, id: String = UUID().uuidString.lowercased(), text: String) async throws -> CompanionNote {
    let content = try NoteDocument(blocks: [.richText(.init(text: text))]).encoded()
    let result = try await database.applyCompanionMutation(.init(deviceID: UUID().uuidString.lowercased(), kind: .createNote,
      resourceID: id, title: text, content: content))
    #expect(result.status == .accepted)
    return try await #require(database.companionNote(id: id))
  }
  @Test func snapshotIncludesCommittedWALAndFencePreservesPendingWriting() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await database(root, "source"), id = UUID().uuidString.lowercased()
    let note = try await create(source, text: "Before transfer")
    try await source.fenceLibraryTransfer(id)
    await #expect(throws: CompanionAPIError.self) { _ = try await create(source, text: "Must remain pending") }
    let snapshot = root.appending(path: "backup.sqlite")
    try await source.backupLibrary(to: snapshot)
    let backup = try await WorkspaceDatabase(url: snapshot, readOnlyProjection: true)
    #expect(try await backup.companionNote(id: note.id)?.content == note.content)
    try await source.releaseLibraryTransfer(id)
    _ = try await create(source, text: "After cancellation")
    #expect(try await backup.companionSnapshot().notes.count == 1)
  }
  @Test func mergeKeepsBothLibrariesAndBothConflictingVersionsWithoutDuplicatingRetry() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await database(root, "source"), destination = try await database(root, "destination")
    let sharedID = UUID().uuidString.lowercased()
    let incoming = try await create(source, id: sharedID, text: "Source writing")
    let existing = try await create(destination, id: sharedID, text: "Destination writing")
    let sourceOnly = try await create(source, text: "Same title")
    let destinationOnly = try await create(destination, text: "Same title")
    let sourceFile = root.appending(path: "source.sqlite"), mergedFile = root.appending(path: "merged.sqlite")
    try await source.backupLibrary(to: sourceFile); try await destination.backupLibrary(to: mergedFile)
    let id = UUID().uuidString.lowercased()
    let sourceLibraryID = try await source.companionWorkspaceID(), destinationLibraryID = try await destination.companionWorkspaceID()
    let result = try LibraryTransferSQLite.merge(source: sourceFile, into: mergedFile, transferID: id,
      sourceLibraryID: sourceLibraryID, destinationLibraryID: destinationLibraryID)
    #expect(result.recoveredItems >= 1)
    let merged = try await WorkspaceDatabase(url: mergedFile, readOnlyProjection: true)
    let notes = try await merged.companionSnapshot().notes
    #expect(notes.contains { $0.id == existing.id && $0.content == existing.content })
    #expect(notes.contains { $0.id != existing.id && $0.content == incoming.content })
    #expect(notes.contains { $0.id == sourceOnly.id })
    #expect(notes.contains { $0.id == destinationOnly.id })
    let again = try LibraryTransferSQLite.merge(source: sourceFile, into: mergedFile, transferID: id,
      sourceLibraryID: sourceLibraryID, destinationLibraryID: destinationLibraryID)
    #expect(again == result)
    #expect(try await merged.companionSnapshot().notes.count == notes.count)
    #expect(try await destination.companionNote(id: sharedID)?.content == existing.content)
    #expect(try await source.companionNote(id: sharedID)?.content == incoming.content)
  }
  @Test func deletionsOnEitherSideNeverResurrectSharedIdentitiesAndKeepLiveWriting() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await database(root, "source"), destination = try await database(root, "destination")
    let sourceDeleted = UUID().uuidString.lowercased(), targetDeleted = UUID().uuidString.lowercased()
    let one = try await create(source, id: sourceDeleted, text: "Deleted at source")
    _ = try await create(destination, id: sourceDeleted, text: "Destination live")
    _ = try await create(source, id: targetDeleted, text: "Source live")
    let two = try await create(destination, id: targetDeleted, text: "Deleted at destination")
    _ = try await source.applyCompanionMutation(.init(deviceID: UUID().uuidString.lowercased(), kind: .deleteNote, resourceID: one.id, expectedRevision: one.revision))
    _ = try await destination.applyCompanionMutation(.init(deviceID: UUID().uuidString.lowercased(), kind: .deleteNote, resourceID: two.id, expectedRevision: two.revision))
    let folder = try await source.createFixtureFolder(name: "Deleted folder")
    let mirrored = try await destination.applyCompanionMutation(.init(deviceID: UUID().uuidString.lowercased(), kind: .createFolder,
      resourceID: folder, title: "Live folder", folderExecution: .init(workspaceID: "local", rootPath: "/tmp/library-transfer-fixture")))
    #expect(mirrored.status == .accepted)
    try await source.deleteFolder(id: folder)
    let a = root.appending(path: "a.sqlite"), b = root.appending(path: "b.sqlite")
    try await source.backupLibrary(to: a); try await destination.backupLibrary(to: b)
    let sourceID = try await source.companionWorkspaceID(), destinationID = try await destination.companionWorkspaceID()
    _ = try LibraryTransferSQLite.merge(source: a, into: b, transferID: UUID().uuidString.lowercased(),
      sourceLibraryID: sourceID, destinationLibraryID: destinationID)
    let merged = try await WorkspaceDatabase(url: b, readOnlyProjection: true)
    #expect(try await merged.companionNote(id: sourceDeleted) == nil)
    #expect(try await merged.companionNote(id: targetDeleted) == nil)
    let snapshot = try await merged.companionSnapshot()
    #expect(snapshot.notes.contains { $0.title.contains("Destination live") })
    #expect(snapshot.notes.contains { $0.title.contains("Source live") })
    #expect(!snapshot.folders.contains { $0.id == folder })
    #expect(snapshot.folders.contains { $0.id != folder && $0.name.contains("Live folder") })
  }
  @Test func interruptedUploadResumesExactBytesAndRejectsTraversalTamperingAndSymlinks() throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("SQLite bytes for a transport fixture".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let manifest = CompanionLibraryTransferManifest(transferID: UUID().uuidString.lowercased(), libraryID: UUID().uuidString.lowercased(),
      files: [.init(path: "workspace.sqlite", byteCount: Int64(bytes.count), sha256: hash)])
    let first = Data(bytes.prefix(10)), rest = Data(bytes.dropFirst(10))
    #expect(try LibraryTransferArchive.write(.init(path: "workspace.sqlite", offset: 0, data: first), manifest: manifest, in: root) == 10)
    #expect(try LibraryTransferArchive.write(.init(path: "workspace.sqlite", offset: 0, data: first), manifest: manifest, in: root) == 10)
    #expect(throws: CompanionAPIError.self) { try LibraryTransferArchive.write(.init(path: "workspace.sqlite", offset: 0, data: Data("different!".utf8)), manifest: manifest, in: root) }
    #expect(try LibraryTransferArchive.write(.init(path: "workspace.sqlite", offset: 10, data: rest), manifest: manifest, in: root) == Int64(bytes.count))
    #expect(try Data(contentsOf: root.appending(path: "workspace.sqlite")) == bytes)
    for path in ["../workspace.sqlite", "/workspace.sqlite", "library-files/../secret", "library-files//blob", "credentials.json"] {
      #expect(!LibraryTransferArchive.validPath(path))
    }
    try FileManager.default.createSymbolicLink(at: root.appending(path: "library-files"), withDestinationURL: root.deletingLastPathComponent())
    #expect(throws: CompanionAPIError.self) { try LibraryTransferArchive.secureFile("library-files/escape", in: root, createParents: true) }
  }
  @Test func receiverRequiresLocalApprovalKeepsBackupAndCommitsIdempotentlyAfterRestart() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await database(root, "source"), destination = try await database(root, "destination")
    let sourceNote = try await create(source, text: "Source"), destinationNote = try await create(destination, text: "Destination")
    let sourceIdentity = try await source.companionLibraryIdentity(), targetIdentity = try await destination.companionLibraryIdentity()
    let id = UUID().uuidString.lowercased(), secret = String(repeating: "synthetic-transfer-secret", count: 2)
    let request = CompanionLibraryTransferRequest(id: id, source: .init(deviceID: sourceIdentity.hostDeviceID, deviceName: "Source Mac", metadata: .init(kind: .mac)),
      sourceEndpoint: URL(string: "https://source.tail.ts.net/wovenmatter")!, sourceLibraryID: sourceIdentity.libraryID,
      destinationDeviceID: targetIdentity.hostDeviceID, secretDigest: SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined())
    let receiverRoot = root.appending(path: "receiver"), receiver = try LibraryTransferReceiver(directory: receiverRoot)
    #expect(try await receiver.request(request, destinationDeviceID: targetIdentity.hostDeviceID).phase == .awaitingApproval)
    let export = root.appending(path: "export")
    do { try await LibraryTransferArchive.backup(database: source, to: export) }
    catch { throw WorkspaceDatabaseError.execute("Source archive: \(error)") }
    try LibraryTransferArchive.persist([CompanionPairedDevice](), to: export.appending(path: "devices.json"))
    try LibraryTransferArchive.persist([CompanionExecutionManagementGrant](), to: export.appending(path: "authority.json"))
    try LibraryTransferArchive.persist([CompanionLibraryRelocation](), to: export.appending(path: "lineage.json"))
    let files: [CompanionLibraryTransferFile]
    do { files = try LibraryTransferArchive.files(in: export) }
    catch { throw WorkspaceDatabaseError.execute("Source inventory: \(error)") }
    let manifest = CompanionLibraryTransferManifest(transferID: id, libraryID: sourceIdentity.libraryID, files: files)
    #expect(manifest.files.contains { $0.path == "workspace.sqlite" }, "Archive paths: \(manifest.files.map(\.path))")
    await #expect(throws: CompanionAPIError.self) { _ = try await receiver.setManifest(manifest, id: id, secret: secret) }
    do { try await receiver.approve(id, database: destination, endpoint: URL(string: "https://mini.tail.ts.net/wovenmatter")!) }
    catch { throw WorkspaceDatabaseError.execute("Receiver approval: \(error)") }
    do { _ = try await receiver.setManifest(manifest, id: id, secret: secret) }
    catch { throw WorkspaceDatabaseError.execute("Receiver manifest \(manifest.files.map(\.path)): \(error)") }
    for file in manifest.files {
      let data = try Data(contentsOf: export.appending(path: file.path))
      var offset = 0
      while offset < data.count {
        let end = min(data.count, offset + LibraryTransferArchive.chunkBytes)
        do { _ = try await receiver.upload(.init(path: file.path, offset: Int64(offset), data: data.subdata(in: offset..<end)), id: id, secret: secret) }
        catch { throw WorkspaceDatabaseError.execute("Receiver chunk \(file.path) at \(offset): \(error)") }
        offset = end
      }
    }
    do { #expect(try await receiver.verify(id, secret: secret).phase == .verified) }
    catch { throw WorkspaceDatabaseError.execute("Receiver verification: \(error)") }
    #expect(try await destination.companionNote(id: sourceNote.id) == nil)
    let restarted = try LibraryTransferReceiver(directory: receiverRoot)
    try await restarted.restoreFences(database: destination)
    let auth = try CompanionAuthentication(fileURL: destination.supportDirectory.appending(path: "companion-devices.json"))
    do { #expect(try await restarted.commit(id, secret: secret, database: destination, authentication: auth).phase == .committed) }
    catch { throw WorkspaceDatabaseError.execute("Receiver activation: \(error)") }
    #expect(try await restarted.commit(id, secret: secret, database: destination, authentication: auth).phase == .committed)
    #expect(try await destination.companionNote(id: sourceNote.id)?.content == sourceNote.content)
    #expect(try await destination.companionNote(id: destinationNote.id)?.content == destinationNote.content)
    let saved = try await restarted.authenticated(id, secret: secret)
    let backup = try await WorkspaceDatabase(url: URL(fileURLWithPath: #require(saved.status.backupPath)).appending(path: "workspace.sqlite"), readOnlyProjection: true)
    #expect(try await backup.companionNote(id: sourceNote.id) == nil)
    #expect(try await backup.companionNote(id: destinationNote.id) != nil)
  }
  @Test func pairingMergeKeepsBothBearersAcrossRestartAndRevocationStillWins() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try CompanionAuthentication(fileURL: root.appending(path: "source-devices.json"))
    let destinationFile = root.appending(path: "destination-devices.json")
    let destination = try CompanionAuthentication(fileURL: destinationFile)
    let id = UUID().uuidString.lowercased(), library = UUID().uuidString.lowercased()
    let a = try await source.enrollLocalDevelopment(deviceID: id, name: "Dev · A", workspaceID: library)
    let b = try await destination.enrollLocalDevelopment(deviceID: id, name: "Dev · B", workspaceID: library)
    try await destination.mergeTransferredDevices(source.transferDevices())
    let reopened = try CompanionAuthentication(fileURL: destinationFile)
    #expect(try await reopened.authenticate(bearer: a.credential).id == id)
    #expect(try await reopened.authenticate(bearer: b.credential).id == id)
    let relocation = CompanionLibraryRelocation(transferID: UUID().uuidString.lowercased(), previousLibraryID: library,
      endpoint: URL(string: "https://mini.tail.ts.net/wovenmatter")!, libraryID: UUID().uuidString.lowercased())
    let nonce = Data(repeating: 22, count: 32), key = Data(SHA256.hash(data: Data(a.credential.utf8)))
    let keyID = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    let proof = try await reopened.transferRelocationProof(deviceID: id, challenge: nonce, relocation: relocation, credentialID: keyID)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: nonce + (try encoder.encode(relocation)), using: SymmetricKey(data: key)))
    try await reopened.revoke(deviceID: id)
    await #expect(throws: CompanionAPIError.self) { _ = try await reopened.authenticate(bearer: a.credential) }
    await #expect(throws: CompanionAPIError.self) { _ = try await reopened.authenticate(bearer: b.credential) }
    try await reopened.mergeTransferredDevices(source.transferDevices())
    await #expect(throws: CompanionAPIError.self) { _ = try await reopened.authenticate(bearer: a.credential) }
    await #expect(throws: CompanionAPIError.self) { _ = try await reopened.transferRelocationProof(deviceID: id, challenge: nonce, relocation: relocation, credentialID: keyID) }
  }
  @Test func conflictingSavedArtifactsRetainBothCompleteByteStreams() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await database(root, "source"), destination = try await database(root, "destination")
    let sourceIdentity = try await source.companionLibraryIdentity(), targetIdentity = try await destination.companionLibraryIdentity()
    let workspace = UUID().uuidString.lowercased(), artifact = UUID().uuidString.lowercased()
    for (database, library, host) in [(source, sourceIdentity.libraryID, sourceIdentity.hostDeviceID), (destination, targetIdentity.libraryID, targetIdentity.hostDeviceID)] {
      _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(id: workspace, libraryID: library,
        ownerDeviceID: sourceIdentity.hostDeviceID, kind: .mac, name: "Owner", executionDeviceID: sourceIdentity.hostDeviceID)), deviceID: host)
    }
    let original = Data("Destination artifact bytes".utf8), incoming = Data("Source artifact bytes".utf8)
    for (database, bytes) in [(source, incoming), (destination, original)] {
      let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let upload = try await database.registerCompanionArtifact(.init(manifest: .init(id: artifact, workspaceID: workspace, title: "Output",
        mediaType: "text/plain", byteCount: Int64(bytes.count), sha256: sha)), deviceID: sourceIdentity.hostDeviceID)
      _ = try await database.appendCompanionArtifactChunk(.init(id: artifact, revision: upload.manifest.revision, offset: 0, data: bytes), deviceID: sourceIdentity.hostDeviceID)
      _ = try await database.commitCompanionArtifact(.init(id: artifact, revision: upload.manifest.revision), deviceID: sourceIdentity.hostDeviceID)
    }
    let a = root.appending(path: "a.sqlite"), b = root.appending(path: "b.sqlite"), id = UUID().uuidString.lowercased()
    try await source.backupLibrary(to: a); try await destination.backupLibrary(to: b)
    _ = try LibraryTransferSQLite.merge(source: a, into: b, transferID: id, sourceLibraryID: sourceIdentity.libraryID, destinationLibraryID: targetIdentity.libraryID)
    let merged = try await WorkspaceDatabase(url: b, readOnlyProjection: true)
    #expect(try await merged.companionArtifactChunk(id: artifact, offset: 0).data == original)
    let recovered = LibraryTransferSQLite.recoveryID(transferID: id, table: "companion_saved_artifacts", id: artifact)
    #expect(try await merged.companionArtifactChunk(id: recovered, offset: 0).data == incoming)
  }

  @Test func movingLibraryNeverMovesItsScheduledExecutionsToAnotherMac() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await database(root, "source"), destination = try await database(root, "destination")
    let identity = try await source.companionLibraryIdentity(), target = try await destination.companionLibraryIdentity()
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Source", executionDeviceID: identity.hostDeviceID)
    _ = try await source.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let event = try await source.saveCalendarEvent(draft: .init(title: "Stay on source", startsAt: start, timeZoneID: "UTC",
      task: .init(prompt: "Fixture only", configuration: .init(runtimeKind: .codex, title: "Source task"))), creating: true)
    let session = try await #require(source.companionSnapshot().conversations.first?.id)
    try await source.setSessionTools(.init(enabled: [.timers]), sessionID: session)
    let timer = WorkspaceSessionTimer(sessionID: session, instruction: "Stay on source", nextFireAt: start)
    try await source.saveSessionTimer(timer, callerID: session)
    let projected = root.appending(path: "projected.sqlite"), mergedFile = root.appending(path: "merged.sqlite")
    try await source.backupLibrary(to: projected); try await destination.backupLibrary(to: mergedFile)
    let export = try await WorkspaceDatabase(url: projected)
    try await export.projectLibraryTransferOrigins()
    _ = try LibraryTransferSQLite.merge(source: projected, into: mergedFile, transferID: UUID().uuidString.lowercased(), sourceLibraryID: identity.libraryID, destinationLibraryID: target.libraryID)
    let merged = try await WorkspaceDatabase(url: mergedFile)
    #expect(try await merged.companionCalendarSnapshot().records.first { $0.id == event }?.ownerDeviceID == identity.hostDeviceID)
    #expect(try await merged.dueCalendarRuns(now: start).isEmpty)
    #expect(try await merged.dueSessionTimers(now: start).isEmpty)
    #expect(try await merged.sessionTimers().contains { $0.id == timer.id })
    try await source.retireLibraryAuthority(workspace: workspace)
    _ = try await source.executionCalendarSnapshot(libraryID: identity.libraryID, workspaceID: workspace.id)
    #expect(try await source.dueCalendarRuns(now: start).contains { $0.eventID == event })
    #expect(try await source.dueSessionTimers(now: start).contains { $0.id == timer.id })
  }
}
