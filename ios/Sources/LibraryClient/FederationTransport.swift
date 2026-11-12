import Foundation
import WovenMatterShared

public protocol FederationTransport: Sendable {
  func libraryIdentity() async throws -> LibraryIdentity
  func executionWorkspaces() async throws -> [ExecutionWorkspace]
  func registerWorkspace(_ registration: LibraryWorkspaceRegistration) async throws -> ExecutionWorkspace
  func journal(after: Int64) async throws -> ExecutionJournalPage
  func importJournal(_ batch: ExecutionJournalBatch) async throws -> ExecutionJournalBatchResult
  func artifactManifests() async throws -> [LibraryArtifactManifest]
  func registerArtifact(_ registration: LibraryArtifactRegistration) async throws -> LibraryArtifactTransfer
  func uploadArtifactChunk(_ chunk: LibraryArtifactChunk) async throws -> LibraryArtifactTransfer
  func commitArtifact(_ commit: LibraryArtifactCommit) async throws -> LibraryArtifactManifest
  func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) async throws -> LibraryArtifactChunk
}

extension HTTPSLibraryTransport: FederationTransport {
  public func registerExecutionManagement(_ grant: ExecutionManagementGrant) async throws {
    struct Acknowledgement: Decodable {}
    let _: Acknowledgement = try await request("v1/federation/workspaces/" + TailnetJSONClient.safeID(grant.workspaceID) + "/management", method: "POST", body: JSONEncoder().encode(grant))
  }
  public func executionCredential(workspaceID: String) async throws -> DirectWorkspaceCredential {
    let value: ExecutionCredential = try await request("v1/federation/workspaces/" + TailnetJSONClient.safeID(workspaceID) + "/credential", method: "POST", body: Data("{}".utf8))
    guard value.workspace.id == workspaceID, value.deviceID == credential.deviceID, let endpoint = value.workspace.endpoint else { throw MobileConnectionError.invalidResponse }
    let identity = try await workspaceIdentity()
    if value.workspace.libraryID != identity {
      guard let known = try await executionWorkspaces().first(where: { $0.id == workspaceID }),
            known.libraryID == value.workspace.libraryID, known.ownerDeviceID == value.workspace.ownerDeviceID,
            known.endpoint == endpoint else { throw MobileStore.Failure.wrongWorkspace }
    }
    return .init(endpoint: endpoint, libraryID: value.workspace.libraryID, workspaceID: workspaceID, deviceID: value.deviceID, token: value.token)
  }
  public func libraryIdentity() async throws -> LibraryIdentity { try await request("v1/federation/identity") }
  public func executionWorkspaces() async throws -> [ExecutionWorkspace] { try await request("v1/federation/workspaces") }
  public func registerWorkspace(_ registration: LibraryWorkspaceRegistration) async throws -> ExecutionWorkspace {
    try await request("v1/federation/workspaces", method: "POST", body: JSONEncoder().encode(registration))
  }
  public func journal(after: Int64) async throws -> ExecutionJournalPage { try await request("v1/federation/journal", query: [.init(name: "after", value: String(after))]) }
  public func importJournal(_ batch: ExecutionJournalBatch) async throws -> ExecutionJournalBatchResult {
    try await request("v1/federation/journal", method: "POST", body: JSONEncoder().encode(batch))
  }
  public func artifactManifests() async throws -> [LibraryArtifactManifest] { try await request("v1/federation/artifacts") }
  public func registerArtifact(_ registration: LibraryArtifactRegistration) async throws -> LibraryArtifactTransfer {
    try await request("v1/federation/artifacts/register", method: "POST", body: JSONEncoder().encode(registration))
  }
  public func uploadArtifactChunk(_ chunk: LibraryArtifactChunk) async throws -> LibraryArtifactTransfer {
    try await request("v1/federation/artifacts/chunk", method: "POST", body: JSONEncoder().encode(chunk))
  }
  public func commitArtifact(_ commit: LibraryArtifactCommit) async throws -> LibraryArtifactManifest {
    try await request("v1/federation/artifacts/commit", method: "POST", body: JSONEncoder().encode(commit))
  }
  public func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) async throws -> LibraryArtifactChunk {
    try await request("v1/federation/artifacts/" + TailnetJSONClient.safeID(id) + "/chunk", query: [.init(name: "revision", value: String(revision)), .init(name: "offset", value: String(offset))])
  }
}

extension MobileSyncEngine {
  func synchronizeFederation(using transport: any FederationTransport) async throws {
    let identity: LibraryIdentity
    do { identity = try await transport.libraryIdentity() }
    catch MobileConnectionError.http(404, _) { return } // Older paired Macs keep their v3 library contract.
    guard identity.protocolVersion == FederationProtocol.version else { throw MobileConnectionError.versionMismatch }
    try await store.verifyWorkspace(identity.libraryID)
    try await store.journal.bind(libraryID: identity.libraryID)
    let deviceID = await store.snapshot().deviceID
    try await store.journal.prepareOwnerPublication(deviceID: deviceID)
    let local = await store.journal.snapshot()
    let registered = try await transport.executionWorkspaces()
    for id in local.pendingRegistrations.sorted() {
      guard let workspace = local.workspaces[id] else { continue }
      if !WorkspaceJournal.isLocalExecutionOwner(workspace, deviceID: deviceID) {
        // Observers cache owner records and never publish or re-register them.
        if let canonical = registered.first(where: { $0.id == id }) {
          try await store.journal.upsertWorkspace(canonical, pending: false)
        }
        continue
      }
      var registration = workspace
      // After moving to another host of the library, that host may already
      // hold this registration (synced from a peer) at its own revision.
      let expected = local.centralWorkspaceRevisions[id] ?? registered.first(where: { $0.id == id })?.revision
      registration.revision = expected ?? 0
      let canonical = try await transport.registerWorkspace(.init(workspace: registration, expectedRevision: expected))
      try await store.journal.upsertWorkspace(canonical, pending: false)
    }
    try await store.journal.mergeRegistry(registered)
    try await store.journal.prepareOwnerPublication(deviceID: deviceID)
    for _ in 0..<100 {
      try Task.checkCancellation()
      let pending = await store.journal.pendingOwnerEntries(deviceID: deviceID)
      var entries: [ExecutionJournalEntry] = [], bytes = 0
      for entry in pending.prefix(FederationProtocol.maximumBatchEntries) {
        let size = try JSONEncoder().encode(entry).count
        guard size <= FederationProtocol.maximumEntryBytes else { throw MobileConnectionError.responseTooLarge }
        if bytes + size > 7 * 1_024 * 1_024 { break }
        entries.append(entry); bytes += size
      }
      if entries.isEmpty { break }
      let receipt = try await transport.importJournal(.init(libraryID: identity.libraryID, entries: entries))
      try await store.journal.acknowledge(receipt, submitted: entries)
    }
    for _ in 0..<100 {
      try Task.checkCancellation()
      let page = try await transport.journal(after: store.journal.snapshot().centralCursor)
      setLaneHasMore(.journal, page.hasMore)
      try await store.journal.receiveCentral(page)
      try await store.restoreExecutionProjection()
      if !page.hasMore { break }
    }

  }
}
