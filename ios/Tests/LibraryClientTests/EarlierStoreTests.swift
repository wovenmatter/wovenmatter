import XCTest
import CryptoKit
import WovenMatterShared
@testable import LibraryClient

/// The phone's store, journal and membership file exactly as the release
/// before this build saved them (copied byte for byte from files it wrote).
/// Each holds a number that this build neither reads nor writes; everything
/// else in them must open unchanged.
final class EarlierStoreTests: XCTestCase {
  private static let storeIndex = #"{"version":2,"state":{"formatVersion":1,"bases":{},"outbox":[{"submitted":false,"mutation":{"operationID":"0117c1f7-5249-483f-9d90-e7c37f731483","resourceID":"f0000000-0000-4000-8000-00000000000f","folderExecution":{"rootPath":"\/ExecutionProjects\/f0000000-0000-4000-8000-00000000000f","workspaceID":"device:f005b2dc-a1fe-4f39-b7ea-ed5f14549758"},"title":"Projects","kind":"createFolder","deviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"}},{"submitted":false,"mutation":{"deviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","content":"1fe0ddedc598195c6b1edfe00e8ceb9ae285841ebc4ddfe018511e347dfc1bda","operationID":"cbe0fd46-f34d-4e4e-845d-4983a01300f7","resourceID":"c0000000-0000-4000-8000-00000000000c","title":"Earlier note","kind":"createNote","folderID":"f0000000-0000-4000-8000-00000000000f"}}],"transcripts":{"quick-chat":{"messages":[{"id":"m1","role":"user","content":"61f8313b6d507bb66351437cf7b3df5bb415987cc090962cac472e92e706689c","createdAt":"","conversationID":"quick-chat"},{"conversationID":"quick-chat","role":"assistant","content":"a85faf3215291e97607221624bf1a7c5503f350d861d67981bd3e71e9fbac181","createdAt":"","id":"m2"}],"activities":[],"conversationID":"quick-chat"}},"deletedNotes":[],"cursor":0,"launches":[],"conflicts":{},"chatDrafts":{"draft-key":{"text":"4c081908fc560f0bc5f04138d8bfd85f07256f079241abc24364d34ceb0e5c1f","noteID":"c0000000-0000-4000-8000-00000000000c"}},"commands":[],"uncachedNoteIDs":[],"conversations":{"quick-chat":{"updatedAt":"","preview":"","title":"Quick Chat","id":"quick-chat"}},"executionConversationIDs":["quick-chat"],"workspaceID":"library-earlier","localRevisionParents":{},"deviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","transcriptRecency":["quick-chat"],"folders":{"f0000000-0000-4000-8000-00000000000f":{"execution":{"rootPath":"\/ExecutionProjects\/f0000000-0000-4000-8000-00000000000f","workspaceID":"device:f005b2dc-a1fe-4f39-b7ea-ed5f14549758"},"id":"f0000000-0000-4000-8000-00000000000f","updatedAt":"2026-11-19T16:26:56Z","revision":0,"name":"Projects"}},"notes":{"c0000000-0000-4000-8000-00000000000c":{"content":"1fe0ddedc598195c6b1edfe00e8ceb9ae285841ebc4ddfe018511e347dfc1bda","title":"Earlier note","folderID":"f0000000-0000-4000-8000-00000000000f","contentByteCount":205,"updatedAt":"2026-11-19T16:26:56Z","revision":0,"id":"c0000000-0000-4000-8000-00000000000c","contentIncluded":true}}}}"#
  private static let journalIndex = #"{"state":{"formatVersion":1,"libraryID":"library-earlier","transcripts":{"quick-chat":{"messages":[{"conversationID":"quick-chat","role":"user","content":"61f8313b6d507bb66351437cf7b3df5bb415987cc090962cac472e92e706689c","createdAt":"","id":"m1"},{"conversationID":"quick-chat","role":"assistant","content":"a85faf3215291e97607221624bf1a7c5503f350d861d67981bd3e71e9fbac181","createdAt":"","id":"m2"}],"conversationID":"quick-chat","activities":[]}},"entries":{"96f73007-e9a1-4a61-8d9c-00aaaf032280":{"nativeRecord":{"sha256":"bde26b972e9eb6ffa1ce9a28667f73c3fca411ca91406cfe6fd4a5777c32d2c2","data":"YmRlMjZiOTcyZTllYjZmZmExY2U5YTI4NjY3ZjczYzNmY2E0MTFjYTkxNDA2Y2ZlNmZkNGE1Nzc3YzMyZDJjMg==","partCount":1,"partIndex":0,"recordID":"activity-a1","format":"wovenmatter.activity.v1","byteCount":33},"eventID":"96f73007-e9a1-4a61-8d9c-00aaaf032280","originSequence":4,"conversationID":"quick-chat","workspaceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","kind":"nativeRecord","runID":"run-1"},"bc918334-08ec-41d8-b1a2-95c3732c53a8":{"originSequence":2,"kind":"transcript","transcript":{"messages":[{"id":"m1","role":"user","conversationID":"quick-chat","content":"61f8313b6d507bb66351437cf7b3df5bb415987cc090962cac472e92e706689c","createdAt":""},{"id":"m2","role":"assistant","conversationID":"quick-chat","content":"a85faf3215291e97607221624bf1a7c5503f350d861d67981bd3e71e9fbac181","createdAt":""}],"conversationID":"quick-chat","activities":[]},"conversationID":"quick-chat","eventID":"bc918334-08ec-41d8-b1a2-95c3732c53a8","workspaceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"},"b9e2a4a5-566b-45cb-a175-737f92ee73b9":{"originSequence":1,"conversation":{"title":"Quick Chat","id":"quick-chat","updatedAt":"","preview":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},"kind":"conversation","conversationID":"quick-chat","workspaceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","eventID":"b9e2a4a5-566b-45cb-a175-737f92ee73b9"},"420368b3-bb5f-4db0-a278-06755be545b8":{"nativeRecord":{"sha256":"c2f5f9bda113d468771b505d5b87885de1ba37f9a3ee6423dbe401f2c9679f99","data":"YzJmNWY5YmRhMTEzZDQ2ODc3MWI1MDVkNWI4Nzg4NWRlMWJhMzdmOWEzZWU2NDIzZGJlNDAxZjJjOTY3OWY5OQ==","partCount":1,"partIndex":0,"recordID":"pi-entry","format":"pi-durable.entry.v1","byteCount":229},"eventID":"420368b3-bb5f-4db0-a278-06755be545b8","originSequence":3,"conversationID":"quick-chat","workspaceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","kind":"nativeRecord","runID":"run-1"}},"pendingEventIDs":["b9e2a4a5-566b-45cb-a175-737f92ee73b9","96f73007-e9a1-4a61-8d9c-00aaaf032280","bc918334-08ec-41d8-b1a2-95c3732c53a8","420368b3-bb5f-4db0-a278-06755be545b8"],"libraryCursor":0,"commands":{},"conversations":{"quick-chat":{"updatedAt":"","preview":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","title":"Quick Chat","id":"quick-chat"}},"deletedConversationIDs":[],"conversationOwners":{"quick-chat":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"},"libraryWorkspaceRevisions":{"mac-workspace":4},"originSequences":{"f005b2dc-a1fe-4f39-b7ea-ed5f14549758":4},"workspaces":{"mac-workspace":{"ownerDeviceID":"a0000000-0000-4000-8000-00000000000a","name":"Studio","endpoint":"https:\/\/studio.example.ts.net:8443\/wovenmatter","journalDeviceIDs":[],"capabilities":["execution.v1","history.library.v1","stream.v1"],"revision":4,"executionDeviceID":"a0000000-0000-4000-8000-00000000000a","deleted":false,"libraryID":"library-earlier","kind":"mac","id":"mac-workspace"},"f005b2dc-a1fe-4f39-b7ea-ed5f14549758":{"ownerDeviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","name":"iPhone","journalDeviceIDs":[],"capabilities":["quick-chat","notes","approvals","questions"],"revision":0,"executionDeviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","deleted":false,"libraryID":"library-earlier","kind":"ios","id":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"}},"pendingRegistrations":["f005b2dc-a1fe-4f39-b7ea-ed5f14549758"],"directCursors":{}},"version":2}"#
  private static let membership = #"{"formatVersion":1,"syncStatus":{"peers":[{"state":"online","version":"0.4.6","name":"Box","kind":"linux","deviceID":"b0000000-0000-4000-8000-00000000000b"}],"schema":"3f2a","version":"0.4.6","conflicts":0,"quarantined":0,"deviceID":"a0000000-0000-4000-8000-00000000000a"},"updatedAt":813326400,"pairedName":"Studio","members":[{"revoked":false,"deviceID":"a0000000-0000-4000-8000-00000000000a","kind":"mac","endpoints":["https:\/\/studio.example.ts.net:8443\/wovenmatter"],"name":"Studio"},{"revoked":false,"deviceID":"b0000000-0000-4000-8000-00000000000b","kind":"linux","endpoints":["https:\/\/box.example.ts.net\/wovenmatter"],"name":"Box"}],"preferredHostDeviceID":"a0000000-0000-4000-8000-00000000000a","pairedEndpoint":"https:\/\/studio.example.ts.net:8443\/wovenmatter","currentHost":{"endpoint":"https:\/\/studio.example.ts.net:8443\/wovenmatter","name":"Studio","kind":"mac","deviceID":"a0000000-0000-4000-8000-00000000000a"},"pairedHostDeviceID":"a0000000-0000-4000-8000-00000000000a","membersRevision":"rev-7","deviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"}"#
  /// Bodies are saved beside each index under the SHA-256 of their bytes.
  private static let storeBodies = [
    #"{"blocks":[{"type":"richText","value":{"id":"block-1","runs":[{"bold":false,"italic":false,"text":"Written before the update","underline":false}],"style":"paragraph"}}],"html":"","kind":"note","version":2}"#,
    #"An unsent draft"#,
    #"Asked before the update"#,
    #"Answered before the update"#,
  ]
  private static let journalBodies = [
    #"Asked before the update"#,
    #"Answered before the update"#,
    #"{"id":"a1","title":"Read a note"}"#,
    #"{"conversationId":7,"id":42,"kind":"pi.assistant","model":[{"model":"test-model","provider":"openai","role":"assistant","timestamp":1791633600000,"usage":{"cacheRead":5,"cacheWrite":0,"input":120,"output":30,"totalTokens":155}}]}"#,
    #""#,
  ]
  private static let phone = "f005b2dc-a1fe-4f39-b7ea-ed5f14549758"
  private static let mac = "a0000000-0000-4000-8000-00000000000a"
  private static let noteID = "c0000000-0000-4000-8000-00000000000c"
  private static let folderID = "f0000000-0000-4000-8000-00000000000f"

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func write(_ bodies: [String], to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for body in bodies {
      let data = Data(body.utf8)
      try data.write(to: directory.appendingPathComponent(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }
  }
  /// The earlier release's files, laid out as the phone has them.
  private func earlierStore() throws -> URL {
    let file = try directory().appendingPathComponent("mobile-library.json")
    try Data(Self.storeIndex.utf8).write(to: file)
    try write(Self.storeBodies, to: file.deletingLastPathComponent().appendingPathComponent("mobile-library.json.bodies"))
    try Data(Self.journalIndex.utf8).write(to: file.appendingPathExtension("execution"))
    try write(Self.journalBodies, to: file.appendingPathExtension("execution.bodies"))
    return file
  }
  private func object(_ file: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  }

  func testTheFixturesAreTheEarlierShape() throws {
    let file = try earlierStore()
    for index in [file, file.appendingPathExtension("execution")] {
      let root = try object(index)
      XCTAssertEqual(root["version"] as? Int, 2)
      XCTAssertEqual((root["state"] as? [String: Any])?["formatVersion"] as? Int, 1)
    }
  }

  func testAStoreSavedByTheEarlierReleaseOpensWithEverything() async throws {
    let file = try earlierStore()
    let state = try await MobileStore(file: file).snapshot()
    XCTAssertEqual(state.deviceID, Self.phone)
    XCTAssertEqual(state.workspaceID, "library-earlier")
    XCTAssertEqual(state.folders[Self.folderID]?.name, "Projects")
    XCTAssertEqual(state.folders[Self.folderID]?.execution?.workspaceID, "device:" + Self.phone)
    let note = try XCTUnwrap(state.notes[Self.noteID])
    XCTAssertEqual(note.title, "Earlier note"); XCTAssertEqual(note.folderID, Self.folderID)
    XCTAssertEqual(note.content, Self.storeBodies[0], "The note's stored bytes, with the number an earlier build left in them")
    XCTAssertEqual(NoteDocument.decode(note.content).plainText, "Written before the update")
    XCTAssertTrue(RichDocumentEditing.canEdit(note.content), "A note stored with the earlier key stays editable")
    XCTAssertEqual(state.outbox.map(\.mutation.kind), [.createFolder, .createNote])
    XCTAssertEqual(state.outbox.last?.mutation.content, note.content)
    XCTAssertEqual(state.chatDrafts["draft-key"], .init(text: "An unsent draft", noteID: Self.noteID))
    XCTAssertEqual(state.conversations["quick-chat"]?.title, "Quick Chat")
    XCTAssertEqual(state.transcripts["quick-chat"]?.messages.map(\.content), ["Asked before the update", "Answered before the update"])
    XCTAssertEqual(state.executionConversationIDs, ["quick-chat"])
    XCTAssertEqual(state.transcriptRecency, ["quick-chat"])
  }

  func testAJournalSavedByTheEarlierReleaseOpensWithEverything() async throws {
    let file = try earlierStore()
    let journal = try await MobileStore(file: file).journal.snapshot()
    XCTAssertEqual(journal.libraryID, "library-earlier")
    XCTAssertEqual(Set(journal.workspaces.keys), [Self.phone, "mac-workspace"])
    XCTAssertEqual(journal.workspaces["mac-workspace"]?.revision, 4)
    XCTAssertEqual(journal.libraryWorkspaceRevisions, ["mac-workspace": 4])
    XCTAssertEqual(journal.pendingRegistrations, [Self.phone])
    XCTAssertEqual(journal.entries.count, 4)
    XCTAssertEqual(journal.pendingEventIDs, Set(journal.entries.keys))
    XCTAssertEqual(journal.originSequences, [Self.phone: 4])
    XCTAssertEqual(journal.conversationWorkspaceIDs, ["quick-chat": Self.phone])
    XCTAssertEqual(journal.transcripts["quick-chat"]?.messages.map(\.content), ["Asked before the update", "Answered before the update"])
    let records = journal.entries.values.compactMap(\.nativeRecord)
    let entry = try XCTUnwrap(records.first { $0.recordID == "pi-entry" })
    XCTAssertEqual(String(decoding: entry.data, as: UTF8.self), Self.journalBodies[3])
    // Rows already stored keep the tags they were written with, and are still recognised.
    XCTAssertEqual(entry.format, "pi-durable.entry.v1")
    XCTAssertTrue(NativeRecordFormat.piDurableEntry.matches(entry.format))
    let activity = try XCTUnwrap(records.first { $0.recordID == "activity-a1" })
    XCTAssertEqual(activity.format, "wovenmatter.activity.v1")
    XCTAssertTrue(NativeRecordFormat.activity.matches(activity.format))
    let samples = try DeviceUsageProjection.samples(in: journal, workspaceID: Self.phone, from: .distantPast, to: .distantFuture)
    XCTAssertEqual(samples.map(\.totalTokens), [155], "Usage saved under the earlier tag is still counted")
    XCTAssertEqual(samples.first?.model, "test-model")
  }

  func testWhatIsSavedAfterwardsHoldsNoNumberAndLosesNothing() async throws {
    let file = try earlierStore()
    var store: MobileStore? = try MobileStore(file: file)
    let before = await store!.snapshot(), journalBefore = await store!.journal.snapshot()
    try await store!.saveChatDraft(key: "after", draft: .init(text: "Written after the update"))
    let entry = Data(#"{"conversationId":7,"id":43,"kind":"pi.assistant","model":[]}"#.utf8)
    try await store!.journal.appendNativeRecord(workspaceID: Self.phone, conversationID: "quick-chat", runID: "run-2", recordID: "pi-entry-2",
      format: NativeRecordFormat.piDurableEntry.name, data: entry)
    store = nil

    for index in [file, file.appendingPathExtension("execution")] {
      let root = try object(index)
      XCTAssertEqual(Set(root.keys), ["state"], index.lastPathComponent)
      XCTAssertNil((root["state"] as? [String: Any])?["formatVersion"], index.lastPathComponent)
    }
    let saved = String(decoding: try Data(contentsOf: file.appendingPathExtension("execution")), as: UTF8.self)
    XCTAssertNotNil(saved.range(of: #""format":"pi-durable.entry.v1""#), "A stored row is not rewritten to change its tag")
    XCTAssertNotNil(saved.range(of: #""format":"pi-durable.entry""#), "A new row carries the name written from now on")

    let reopened = try MobileStore(file: file)
    var expected = before; expected.chatDrafts["after"] = .init(text: "Written after the update")
    let state = await reopened.snapshot(), journal = await reopened.journal.snapshot()
    XCTAssertEqual(state, expected)
    XCTAssertEqual(journal.entries.count, journalBefore.entries.count + 1)
    for (id, entry) in journalBefore.entries { XCTAssertEqual(journal.entries[id], entry, id) }
    XCTAssertEqual(journal.workspaces, journalBefore.workspaces)
    XCTAssertEqual(journal.transcripts, journalBefore.transcripts)
  }

  /// Quick Chat offers every Pi entry again each time it exports its history.
  /// An entry already stored under the earlier tag is that same record: it is
  /// neither stored twice nor refused as a reused identity.
  func testAStoredRecordOfferedAgainUnderTodaysNameIsTheSameRecord() async throws {
    let journal = try MobileStore(file: try earlierStore()).journal
    let before = await journal.snapshot()
    let again = try await journal.appendNativeRecord(workspaceID: Self.phone, conversationID: "quick-chat", runID: "run-1", recordID: "pi-entry",
      format: NativeRecordFormat.piDurableEntry.name, data: Data(Self.journalBodies[3].utf8))
    XCTAssertEqual(again.map(\.nativeRecord?.format), ["pi-durable.entry.v1"])
    let after = await journal.snapshot()
    XCTAssertEqual(after, before)
    // Another format, or other bytes, under the same identity is still refused.
    do {
      try await journal.appendNativeRecord(workspaceID: Self.phone, conversationID: "quick-chat", runID: "run-1", recordID: "pi-entry",
        format: NativeRecordFormat.activity.name, data: Data(Self.journalBodies[3].utf8))
      XCTFail("A record's identity was reused for another format")
    } catch WorkspaceJournal.Failure.reusedIdentity {}
    do {
      try await journal.appendNativeRecord(workspaceID: Self.phone, conversationID: "quick-chat", runID: "run-1", recordID: "pi-entry",
        format: NativeRecordFormat.piDurableEntry.name, data: Data("{}".utf8))
      XCTFail("A record's identity was reused for other bytes")
    } catch WorkspaceJournal.Failure.reusedIdentity {}
  }

  func testAMembershipFileSavedByTheEarlierReleaseLoadsAndIsSavedWithoutItsNumber() throws {
    let file = try directory().appendingPathComponent("membership.json")
    try Data(Self.membership.utf8).write(to: file)
    XCTAssertEqual(try object(file)["formatVersion"] as? Int, 1)
    let state = try XCTUnwrap(MobileLibraryHosts.load(file: file))
    XCTAssertEqual(state.deviceID, Self.phone)
    XCTAssertEqual(state.pairedEndpoint.absoluteString, "https://studio.example.ts.net:8443/wovenmatter")
    XCTAssertEqual(state.pairedHostDeviceID, Self.mac); XCTAssertEqual(state.pairedName, "Studio")
    XCTAssertEqual(state.members.map(\.name), ["Studio", "Box"])
    XCTAssertEqual(state.members.map(\.kind), ["mac", "linux"])
    XCTAssertEqual(state.membersRevision, "rev-7")
    XCTAssertEqual(state.preferredHostDeviceID, Self.mac)
    XCTAssertEqual(state.currentHost?.deviceID, Self.mac)
    XCTAssertEqual(state.syncStatus?.peers.map(\.state), ["online"])
    XCTAssertEqual(state.syncStatus?.version, "0.4.6")
    XCTAssertEqual(state.updatedAt, Date(timeIntervalSince1970: 1_791_633_600))

    try MobileLibraryHosts.save(state, to: file)
    XCTAssertNil(try object(file)["formatVersion"])
    XCTAssertEqual(try MobileLibraryHosts.load(file: file), state)
  }

  /// A saved index is recognised by holding a `state` object. Anything else
  /// (here the state alone, as the very first builds saved it) is refused
  /// instead of opening as an empty library.
  func testAFileThatIsNotASavedIndexIsRefused() throws {
    let root = try directory()
    let bare = try XCTUnwrap((try object(try earlierStore())["state"]) as? [String: Any])
    let file = root.appendingPathComponent("mobile-library.json")
    try JSONSerialization.data(withJSONObject: bare).write(to: file)
    XCTAssertThrowsError(try MobileStorePersistence.load(from: file))
    try Data(#"{"version":2}"#.utf8).write(to: file)
    XCTAssertThrowsError(try MobileStorePersistence.load(from: file))
    XCTAssertThrowsError(try WorkspaceJournalPersistence.load(at: file))
  }
}
