import CryptoKit
import XCTest
@testable import CompanionClient
import WovenMatterCompanion

final class LibraryRelocationTests: XCTestCase {
  func testRetainedWorkspaceAndTransferredNodePersistCredentialsSeparately() async throws {
    let rootSink = RelocationCredentialSink(), childSink = RelocationCredentialSink()
    let root = MobileCredential(endpoint: URL(string: "https://mini.tail.ts.net/wovenmatter")!, workspaceID: UUID().uuidString.lowercased(), deviceID: UUID().uuidString.lowercased(), token: "synthetic-root-node-credential")
    let child = MobileCredential(endpoint: root.endpoint, workspaceID: root.workspaceID, deviceID: UUID().uuidString.lowercased(), token: "synthetic-retained-child-credential")
    let rootTransport = try HTTPSCompanionTransport(credential: root, persistCredential: { rootSink.save($0) })
    let childTransport = try HTTPSCompanionTransport(credential: child, persistCredential: { childSink.save($0) })
    try await rootTransport.rememberLibraryCandidates([URL(string: "https://next.tail.ts.net/wovenmatter")!])
    XCTAssertEqual(rootSink.values.first?.deviceID, root.deviceID)
    XCTAssertTrue(childSink.values.isEmpty)
    XCTAssertEqual(childTransport.credential, child)
    try await childTransport.rememberLibraryCandidates([root.endpoint])
    XCTAssertEqual(childSink.values.first?.token, child.token)
    XCTAssertEqual(rootSink.values.count, 1)
  }
  func testProofRequiresOriginalVerifierFreshNonceAndExactLibrary() throws {
    let library = UUID().uuidString.lowercased(), nonce = Data(repeating: 11, count: 32)
    var credential = MobileCredential(endpoint: URL(string: "https://old.tail.ts.net/wovenmatter")!, workspaceID: library,
      deviceID: UUID().uuidString.lowercased(), token: "synthetic-existing-device-bearer")
    let relocation = CompanionLibraryRelocation(transferID: UUID().uuidString.lowercased(), previousLibraryID: library,
      endpoint: URL(string: "https://mini.tail.ts.net/wovenmatter")!, libraryID: UUID().uuidString.lowercased())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let key = SymmetricKey(data: SHA256.hash(data: Data(credential.token.utf8)))
    let signature = Data(HMAC<SHA256>.authenticationCode(for: nonce + (try encoder.encode(relocation)), using: key))
    XCTAssertTrue(try LibraryRelocationResolver.verify(.init(relocation: relocation, signature: signature), credential: credential, nonce: nonce))
    XCTAssertFalse(try LibraryRelocationResolver.verify(.init(relocation: relocation, signature: signature), credential: credential, nonce: Data(repeating: 12, count: 32)))
    credential.token = "another-device-bearer"
    XCTAssertFalse(try LibraryRelocationResolver.verify(.init(relocation: relocation, signature: signature), credential: credential, nonce: nonce))
    let otherLibrary = CompanionLibraryRelocation(transferID: relocation.transferID, previousLibraryID: UUID().uuidString.lowercased(), endpoint: relocation.endpoint, libraryID: relocation.libraryID)
    XCTAssertFalse(try LibraryRelocationResolver.verify(.init(relocation: otherLibrary, signature: signature), credential: credential, nonce: nonce))
    let publicEndpoint = CompanionLibraryRelocation(transferID: relocation.transferID, previousLibraryID: library, endpoint: URL(string: "https://example.com/wovenmatter")!, libraryID: relocation.libraryID)
    XCTAssertFalse(try LibraryRelocationResolver.verify(.init(relocation: publicEndpoint, signature: signature), credential: credential, nonce: nonce))
  }

  func testOfflineWritingAndDirectHistorySurviveRelocationAndRestartByteForByte() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "relocation-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "library.json"), library = UUID().uuidString.lowercased()
    let store = try MobileStore(file: file)
    try await store.apply(CompanionSnapshot(workspaceID: library, cursor: 400))
    try await store.journal.bind(libraryID: library)
    let owner = await store.snapshot().deviceID, foreign = UUID().uuidString.lowercased()
    try await store.journal.upsertWorkspace(.init(id: owner, libraryID: library, ownerDeviceID: owner, kind: .mac, name: "Own Mac"))
    try await store.journal.upsertWorkspace(.init(id: foreign, libraryID: library, ownerDeviceID: foreign, kind: .mac, name: "Other Mac"), pending: false)
    let content = try NoteDocument(blocks: [.richText(.init(text: "Writing saved while central is offline"))]).encoded()
    _ = try await store.createNote(folderID: nil, title: "Pending", content: content)
    let own = try await store.journal.append(workspaceID: owner, conversation: .init(id: "own-chat", title: "Local work"))
    let remote = CompanionJournalEntry(eventID: "foreign-event", workspaceID: foreign, originSequence: 1,
      conversationID: "remote-chat", kind: .conversation, conversation: .init(id: "remote-chat", title: "Remote work"))
    try await store.journal.receiveWorkspace(.init(libraryID: library, cursor: 1, entries: [remote]), workspaceID: foreign)
    try await store.journal.receiveCentral(.init(libraryID: library, cursor: Int64(own.count), entries: own))
    let before = await store.snapshot(), history = await store.journal.snapshot()
    let backupDirectory = directory.appending(path: "backup")
    try await store.backupForLibraryTransfer(to: backupDirectory)
    let backedUp = try MobileStore(file: backupDirectory.appending(path: "library.json"))
    let saved = await backedUp.snapshot(), savedHistory = await backedUp.journal.snapshot()
    XCTAssertEqual(saved, before); XCTAssertEqual(savedHistory, history)
    let transfer = UUID().uuidString.lowercased()
    try await store.acceptLibraryRelocation(transfer)
    let reopened = try MobileStore(file: file), after = await reopened.snapshot(), journal = await reopened.journal.snapshot()
    XCTAssertEqual(after.cursor, 0); XCTAssertEqual(after.hasLibrarySnapshot, false)
    XCTAssertEqual(after.libraryRelocationID, transfer)
    XCTAssertEqual(after.notes, before.notes); XCTAssertEqual(after.outbox, before.outbox)
    XCTAssertEqual(after.deviceID, owner); XCTAssertEqual(after.workspaceID, library)
    XCTAssertEqual(journal.centralCursor, 0)
    XCTAssertEqual(journal.directCursors, history.directCursors)
    XCTAssertEqual(journal.entries, history.entries); XCTAssertEqual(journal.pendingEventIDs, history.pendingEventIDs)
    let pending = await reopened.journal.pendingOwnerEntries(deviceID: owner)
    XCTAssertTrue(pending.allSatisfy { $0.workspaceID == owner })
    try await reopened.acceptLibraryRelocation(transfer)
    let again = await reopened.snapshot(); XCTAssertEqual(after, again)
  }
}

private final class RelocationCredentialSink: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [MobileCredential] = []
  func save(_ value: MobileCredential) { lock.withLock { stored.append(value) } }
  var values: [MobileCredential] { lock.withLock { stored } }
}
