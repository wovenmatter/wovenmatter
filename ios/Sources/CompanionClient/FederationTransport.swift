import Foundation
import WovenMatterCompanion

public protocol FederationTransport: Sendable {
  func libraryIdentity() async throws -> CompanionLibraryIdentity
  func executionWorkspaces() async throws -> [CompanionExecutionWorkspace]
  func registerWorkspace(_ registration: CompanionWorkspaceRegistration) async throws -> CompanionExecutionWorkspace
  func journal(after: Int64) async throws -> CompanionJournalPage
  func importJournal(_ batch: CompanionJournalBatch) async throws -> CompanionJournalBatchResult
  func artifactManifests() async throws -> [CompanionArtifactManifest]
  func registerArtifact(_ registration: CompanionArtifactRegistration) async throws -> CompanionArtifactTransfer
  func artifactStatus(_ id: String) async throws -> CompanionArtifactTransfer
  func uploadArtifactChunk(_ chunk: CompanionArtifactChunk) async throws -> CompanionArtifactTransfer
  func commitArtifact(_ commit: CompanionArtifactCommit) async throws -> CompanionArtifactManifest
  func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) async throws -> CompanionArtifactChunk
}

extension HTTPSCompanionTransport: FederationTransport {
  public func registerExecutionManagement(_ grant: CompanionExecutionManagementGrant) async throws {
    struct Acknowledgement: Decodable {}
    let _: Acknowledgement = try await request("v1/federation/workspaces/" + TailnetJSONClient.safeID(grant.workspaceID) + "/management", method: "POST", body: JSONEncoder().encode(grant))
  }
  public func executionCredential(workspaceID: String) async throws -> DirectWorkspaceCredential {
    let value: CompanionExecutionCredential = try await request("v1/federation/workspaces/" + TailnetJSONClient.safeID(workspaceID) + "/credential", method: "POST", body: Data("{}".utf8))
    guard value.workspace.id == workspaceID, value.deviceID == credential.deviceID, let endpoint = value.workspace.endpoint else { throw MobileConnectionError.invalidResponse }
    let identity = try await workspaceIdentity()
    guard value.workspace.libraryID == identity else { throw MobileStore.Failure.wrongWorkspace }
    return .init(endpoint: endpoint, libraryID: identity, workspaceID: workspaceID, deviceID: value.deviceID, token: value.token)
  }
  public func libraryIdentity() async throws -> CompanionLibraryIdentity { try await request("v1/federation/identity") }
  public func executionWorkspaces() async throws -> [CompanionExecutionWorkspace] { try await request("v1/federation/workspaces") }
  public func registerWorkspace(_ registration: CompanionWorkspaceRegistration) async throws -> CompanionExecutionWorkspace {
    try await request("v1/federation/workspaces", method: "POST", body: JSONEncoder().encode(registration))
  }
  public func journal(after: Int64) async throws -> CompanionJournalPage { try await request("v1/federation/journal", query: [.init(name: "after", value: String(after))]) }
  public func importJournal(_ batch: CompanionJournalBatch) async throws -> CompanionJournalBatchResult {
    try await request("v1/federation/journal", method: "POST", body: JSONEncoder().encode(batch))
  }
  public func artifactManifests() async throws -> [CompanionArtifactManifest] { try await request("v1/federation/artifacts") }
  public func registerArtifact(_ registration: CompanionArtifactRegistration) async throws -> CompanionArtifactTransfer {
    try await request("v1/federation/artifacts/register", method: "POST", body: JSONEncoder().encode(registration))
  }
  public func artifactStatus(_ id: String) async throws -> CompanionArtifactTransfer { try await request("v1/federation/artifacts/" + TailnetJSONClient.safeID(id)) }
  public func uploadArtifactChunk(_ chunk: CompanionArtifactChunk) async throws -> CompanionArtifactTransfer {
    try await request("v1/federation/artifacts/chunk", method: "POST", body: JSONEncoder().encode(chunk))
  }
  public func commitArtifact(_ commit: CompanionArtifactCommit) async throws -> CompanionArtifactManifest {
    try await request("v1/federation/artifacts/commit", method: "POST", body: JSONEncoder().encode(commit))
  }
  public func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) async throws -> CompanionArtifactChunk {
    try await request("v1/federation/artifacts/" + TailnetJSONClient.safeID(id) + "/chunk", query: [.init(name: "revision", value: String(revision)), .init(name: "offset", value: String(offset))])
  }
}

extension MobileSyncEngine {
  func synchronizeFederation(using transport: any FederationTransport) async throws {
    let identity: CompanionLibraryIdentity
    do { identity = try await transport.libraryIdentity() }
    catch MobileConnectionError.http(404, _) { return } // Older paired Macs keep their v3 library contract.
    guard identity.protocolVersion == CompanionFederationProtocol.version else { throw MobileConnectionError.versionMismatch }
    try await store.verifyWorkspace(identity.libraryID)
    try await store.journal.bind(libraryID: identity.libraryID)
    let local = await store.journal.snapshot()
    let registered = try await transport.executionWorkspaces()
    let deviceID = await store.snapshot().deviceID
    for id in local.pendingRegistrations.sorted() {
      guard let workspace = local.workspaces[id] else { continue }
      if workspace.ownerDeviceID != deviceID {
        // An observing client forwards owner records, never re-registers the
        // remote workspace as its own. Provisioning already registered it.
        if let canonical = registered.first(where: { $0.id == id }) {
          try await store.journal.upsertWorkspace(canonical, pending: false)
        }
        continue
      }
      var registration = workspace
      registration.revision = local.centralWorkspaceRevisions[id] ?? 0
      let canonical = try await transport.registerWorkspace(.init(workspace: registration, expectedRevision: local.centralWorkspaceRevisions[id]))
      try await store.journal.upsertWorkspace(canonical, pending: false)
    }
    try await store.journal.mergeRegistry(registered)
    for _ in 0..<100 {
      let pending = await store.journal.snapshot().pendingEntries
      var entries: [CompanionJournalEntry] = [], bytes = 0
      for entry in pending.prefix(CompanionFederationProtocol.maximumBatchEntries) {
        let size = try JSONEncoder().encode(entry).count
        guard size <= CompanionFederationProtocol.maximumEntryBytes else { throw MobileConnectionError.responseTooLarge }
        if bytes + size > 7 * 1_024 * 1_024 { break }
        entries.append(entry); bytes += size
      }
      if entries.isEmpty { break }
      let receipt = try await transport.importJournal(.init(libraryID: identity.libraryID, entries: entries))
      try await store.journal.acknowledge(receipt, submitted: entries)
    }
    for _ in 0..<100 {
      let page = try await transport.journal(after: store.journal.snapshot().centralCursor)
      try await store.journal.receiveCentral(page)
      try await store.restoreExecutionProjection()
      if !page.hasMore { break }
    }
    try await store.artifacts.synchronize(using: transport)
  }
}
