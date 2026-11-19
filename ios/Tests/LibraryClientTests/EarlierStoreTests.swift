import XCTest
import CryptoKit
import WovenMatterShared
@testable import LibraryClient

/// The phone's store and journal exactly as the release before this build
/// saved them (copied byte for byte from files it wrote): the input of the
/// one-time conversion that runs when each is first opened.
final class EarlierStoreTests: XCTestCase {
  private static let storeIndex = #"{"version":2,"state":{"formatVersion":1,"bases":{},"outbox":[{"submitted":false,"mutation":{"operationID":"0117c1f7-5249-483f-9d90-e7c37f731483","resourceID":"f0000000-0000-4000-8000-00000000000f","folderExecution":{"rootPath":"\/ExecutionProjects\/f0000000-0000-4000-8000-00000000000f","workspaceID":"device:f005b2dc-a1fe-4f39-b7ea-ed5f14549758"},"title":"Projects","kind":"createFolder","deviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"}},{"submitted":false,"mutation":{"deviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","content":"1fe0ddedc598195c6b1edfe00e8ceb9ae285841ebc4ddfe018511e347dfc1bda","operationID":"cbe0fd46-f34d-4e4e-845d-4983a01300f7","resourceID":"c0000000-0000-4000-8000-00000000000c","title":"Earlier note","kind":"createNote","folderID":"f0000000-0000-4000-8000-00000000000f"}}],"transcripts":{"quick-chat":{"messages":[{"id":"m1","role":"user","content":"61f8313b6d507bb66351437cf7b3df5bb415987cc090962cac472e92e706689c","createdAt":"","conversationID":"quick-chat"},{"conversationID":"quick-chat","role":"assistant","content":"a85faf3215291e97607221624bf1a7c5503f350d861d67981bd3e71e9fbac181","createdAt":"","id":"m2"}],"activities":[],"conversationID":"quick-chat"}},"deletedNotes":[],"cursor":0,"launches":[],"conflicts":{},"chatDrafts":{"draft-key":{"text":"4c081908fc560f0bc5f04138d8bfd85f07256f079241abc24364d34ceb0e5c1f","noteID":"c0000000-0000-4000-8000-00000000000c"}},"commands":[],"uncachedNoteIDs":[],"conversations":{"quick-chat":{"updatedAt":"","preview":"","title":"Quick Chat","id":"quick-chat"}},"executionConversationIDs":["quick-chat"],"workspaceID":"library-earlier","localRevisionParents":{},"deviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","transcriptRecency":["quick-chat"],"folders":{"f0000000-0000-4000-8000-00000000000f":{"execution":{"rootPath":"\/ExecutionProjects\/f0000000-0000-4000-8000-00000000000f","workspaceID":"device:f005b2dc-a1fe-4f39-b7ea-ed5f14549758"},"id":"f0000000-0000-4000-8000-00000000000f","updatedAt":"2026-11-19T16:26:56Z","revision":0,"name":"Projects"}},"notes":{"c0000000-0000-4000-8000-00000000000c":{"content":"1fe0ddedc598195c6b1edfe00e8ceb9ae285841ebc4ddfe018511e347dfc1bda","title":"Earlier note","folderID":"f0000000-0000-4000-8000-00000000000f","contentByteCount":205,"updatedAt":"2026-11-19T16:26:56Z","revision":0,"id":"c0000000-0000-4000-8000-00000000000c","contentIncluded":true}}}}"#
  private static let journalIndex = #"{"state":{"formatVersion":1,"libraryID":"library-earlier","transcripts":{"quick-chat":{"messages":[{"conversationID":"quick-chat","role":"user","content":"61f8313b6d507bb66351437cf7b3df5bb415987cc090962cac472e92e706689c","createdAt":"","id":"m1"},{"conversationID":"quick-chat","role":"assistant","content":"a85faf3215291e97607221624bf1a7c5503f350d861d67981bd3e71e9fbac181","createdAt":"","id":"m2"}],"conversationID":"quick-chat","activities":[]}},"entries":{"96f73007-e9a1-4a61-8d9c-00aaaf032280":{"nativeRecord":{"sha256":"bde26b972e9eb6ffa1ce9a28667f73c3fca411ca91406cfe6fd4a5777c32d2c2","data":"YmRlMjZiOTcyZTllYjZmZmExY2U5YTI4NjY3ZjczYzNmY2E0MTFjYTkxNDA2Y2ZlNmZkNGE1Nzc3YzMyZDJjMg==","partCount":1,"partIndex":0,"recordID":"activity-a1","format":"wovenmatter.activity.v1","byteCount":33},"eventID":"96f73007-e9a1-4a61-8d9c-00aaaf032280","originSequence":4,"conversationID":"quick-chat","workspaceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","kind":"nativeRecord","runID":"run-1"},"bc918334-08ec-41d8-b1a2-95c3732c53a8":{"originSequence":2,"kind":"transcript","transcript":{"messages":[{"id":"m1","role":"user","conversationID":"quick-chat","content":"61f8313b6d507bb66351437cf7b3df5bb415987cc090962cac472e92e706689c","createdAt":""},{"id":"m2","role":"assistant","conversationID":"quick-chat","content":"a85faf3215291e97607221624bf1a7c5503f350d861d67981bd3e71e9fbac181","createdAt":""}],"conversationID":"quick-chat","activities":[]},"conversationID":"quick-chat","eventID":"bc918334-08ec-41d8-b1a2-95c3732c53a8","workspaceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"},"b9e2a4a5-566b-45cb-a175-737f92ee73b9":{"originSequence":1,"conversation":{"title":"Quick Chat","id":"quick-chat","updatedAt":"","preview":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},"kind":"conversation","conversationID":"quick-chat","workspaceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","eventID":"b9e2a4a5-566b-45cb-a175-737f92ee73b9"},"420368b3-bb5f-4db0-a278-06755be545b8":{"nativeRecord":{"sha256":"c2f5f9bda113d468771b505d5b87885de1ba37f9a3ee6423dbe401f2c9679f99","data":"YzJmNWY5YmRhMTEzZDQ2ODc3MWI1MDVkNWI4Nzg4NWRlMWJhMzdmOWEzZWU2NDIzZGJlNDAxZjJjOTY3OWY5OQ==","partCount":1,"partIndex":0,"recordID":"pi-entry","format":"pi-durable.entry.v1","byteCount":229},"eventID":"420368b3-bb5f-4db0-a278-06755be545b8","originSequence":3,"conversationID":"quick-chat","workspaceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","kind":"nativeRecord","runID":"run-1"}},"pendingEventIDs":["b9e2a4a5-566b-45cb-a175-737f92ee73b9","96f73007-e9a1-4a61-8d9c-00aaaf032280","bc918334-08ec-41d8-b1a2-95c3732c53a8","420368b3-bb5f-4db0-a278-06755be545b8"],"libraryCursor":0,"commands":{},"conversations":{"quick-chat":{"updatedAt":"","preview":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","title":"Quick Chat","id":"quick-chat"}},"deletedConversationIDs":[],"conversationOwners":{"quick-chat":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"},"libraryWorkspaceRevisions":{"mac-workspace":4},"originSequences":{"f005b2dc-a1fe-4f39-b7ea-ed5f14549758":4},"workspaces":{"mac-workspace":{"ownerDeviceID":"a0000000-0000-4000-8000-00000000000a","name":"Studio","endpoint":"https:\/\/studio.example.ts.net:8443\/wovenmatter","journalDeviceIDs":[],"capabilities":["execution.v1","history.library.v1","stream.v1"],"revision":4,"executionDeviceID":"a0000000-0000-4000-8000-00000000000a","deleted":false,"libraryID":"library-earlier","kind":"mac","id":"mac-workspace"},"f005b2dc-a1fe-4f39-b7ea-ed5f14549758":{"ownerDeviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","name":"iPhone","journalDeviceIDs":[],"capabilities":["quick-chat","notes","approvals","questions"],"revision":0,"executionDeviceID":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758","deleted":false,"libraryID":"library-earlier","kind":"ios","id":"f005b2dc-a1fe-4f39-b7ea-ed5f14549758"}},"pendingRegistrations":["f005b2dc-a1fe-4f39-b7ea-ed5f14549758"],"directCursors":{}},"version":2}"#
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
  private static let noteID = "c0000000-0000-4000-8000-00000000000c"
  private static let folderID = "f0000000-0000-4000-8000-00000000000f"

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
  private func write(_ bodies: [String], to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for body in bodies { try Data(body.utf8).write(to: directory.appendingPathComponent(digest(body))) }
  }
  /// That release's files, laid out as the phone has them.
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

  /// The store: opening it converts it. Everything that release saved is
  /// there, each note has lost the number stored inside its document, and the
  /// index is saved again at once in today's shape, so a second open finds
  /// nothing to convert.
  func testTheStoreIsConvertedOnceWhenItIsOpened() async throws {
    let file = try earlierStore(), bodies = file.deletingLastPathComponent().appendingPathComponent("mobile-library.json.bodies")
    XCTAssertTrue(EarlierPhoneFiles.isEarlierIndex(try Data(contentsOf: file)))
    let stored = Self.storeBodies[0], converted = String(stored.dropLast(#","version":2}"#.count)) + "}"
    XCTAssertTrue(stored.hasSuffix(#","version":2}"#))

    var store: MobileStore? = try MobileStore(file: file)
    let state = await store!.snapshot()
    store = nil
    XCTAssertEqual(state.deviceID, Self.phone)
    XCTAssertEqual(state.workspaceID, "library-earlier")
    XCTAssertEqual(state.folders[Self.folderID]?.name, "Projects")
    XCTAssertEqual(state.folders[Self.folderID]?.execution?.workspaceID, "device:" + Self.phone)
    let note = try XCTUnwrap(state.notes[Self.noteID])
    XCTAssertEqual(note.title, "Earlier note"); XCTAssertEqual(note.folderID, Self.folderID)
    XCTAssertEqual(note.content, converted)
    XCTAssertEqual(note.contentByteCount, converted.utf8.count)
    XCTAssertEqual(NoteDocument.decode(note.content).plainText, "Written before the update")
    XCTAssertTrue(RichDocumentEditing.canEdit(note.content))
    XCTAssertEqual(state.outbox.map(\.mutation.kind), [.createFolder, .createNote])
    XCTAssertEqual(state.outbox.last?.mutation.content, converted, "The pending write of the note is converted with it")
    XCTAssertEqual(state.chatDrafts["draft-key"], .init(text: "An unsent draft", noteID: Self.noteID))
    XCTAssertEqual(state.conversations["quick-chat"]?.title, "Quick Chat")
    XCTAssertEqual(state.transcripts["quick-chat"]?.messages.map(\.content), ["Asked before the update", "Answered before the update"])
    XCTAssertEqual(state.executionConversationIDs, ["quick-chat"])
    XCTAssertEqual(state.transcriptRecency, ["quick-chat"])

    // Saved again in today's shape by the open itself: nothing to find a second time.
    let saved = try Data(contentsOf: file)
    XCTAssertFalse(EarlierPhoneFiles.isEarlierIndex(saved))
    XCTAssertEqual(Set(try object(file).keys), ["state"])
    XCTAssertNil((try object(file)["state"] as? [String: Any])?["formatVersion"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: bodies.appendingPathComponent(digest(converted)).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bodies.appendingPathComponent(digest(stored)).path))
    let reopened = try await MobileStore(file: file).snapshot()
    XCTAssertEqual(reopened, state)
    XCTAssertEqual(try Data(contentsOf: file), saved, "A second open rewrites nothing")
  }

  /// The journal: opening it converts it. Native records carry today's
  /// format names, the copies of other machines' registry rows carry today's
  /// capability names, and nothing else changes. The index is saved again at
  /// once, so a second open finds nothing to convert.
  func testTheJournalIsConvertedOnceWhenItIsOpened() async throws {
    let file = try earlierStore(), index = file.appendingPathExtension("execution")
    XCTAssertTrue(EarlierPhoneFiles.isEarlierIndex(try Data(contentsOf: index)))
    for tag in ["pi-durable.entry.v1", "wovenmatter.activity.v1", "history.library.v1", "stream.v1", "execution.v1"] {
      XCTAssertNotNil(Self.journalIndex.range(of: "\"" + tag + "\""), tag)
    }
    var store: MobileStore? = try MobileStore(file: file)
    let journal = await store!.journal.snapshot()
    XCTAssertEqual(journal.libraryID, "library-earlier")
    XCTAssertEqual(Set(journal.workspaces.keys), [Self.phone, "mac-workspace"])
    XCTAssertEqual(journal.workspaces["mac-workspace"]?.capabilities, [ExecutionWorkspace.libraryHistoryCapability, StreamProtocol.capability])
    XCTAssertEqual(journal.workspaces["mac-workspace"]?.isLiveLibraryMac, true)
    XCTAssertEqual(journal.workspaces[Self.phone]?.capabilities, ["quick-chat", "notes", "approvals", "questions"])
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
    XCTAssertEqual(entry.format, NativeRecordFormat.piDurableEntry.name)
    // A record's bytes are covered by its digest and hold no tag: they are untouched.
    XCTAssertEqual(String(decoding: entry.data, as: UTF8.self), Self.journalBodies[3])
    XCTAssertEqual(entry.sha256, digest(Self.journalBodies[3]))
    XCTAssertEqual(records.first { $0.recordID == "activity-a1" }?.format, NativeRecordFormat.activity.name)
    let samples = try DeviceUsageProjection.samples(in: journal, workspaceID: Self.phone, from: .distantPast, to: .distantFuture)
    XCTAssertEqual(samples.map(\.totalTokens), [155])
    // Quick Chat offers every entry again when it exports its history: the converted record is that record.
    let again = try await store!.journal.appendNativeRecord(workspaceID: Self.phone, conversationID: "quick-chat", runID: "run-1", recordID: "pi-entry",
      format: NativeRecordFormat.piDurableEntry.name, data: Data(Self.journalBodies[3].utf8))
    XCTAssertEqual(again.map(\.eventID), journal.entries.values.filter { $0.nativeRecord?.recordID == "pi-entry" }.map(\.eventID))
    store = nil

    // Saved again in today's shape by the open itself: nothing to find a second time.
    let saved = try Data(contentsOf: index), text = String(decoding: saved, as: UTF8.self)
    XCTAssertFalse(EarlierPhoneFiles.isEarlierIndex(saved))
    XCTAssertEqual(Set(try object(index).keys), ["state"])
    for earlier in [".v1\"", ".v2\"", "-v1\"", "/v1\"", "/v2\"", "formatVersion"] { XCTAssertNil(text.range(of: earlier), earlier) }
    let reopened = try await MobileStore(file: file).journal.snapshot()
    XCTAssertEqual(reopened, journal)
    XCTAssertEqual(try Data(contentsOf: index), saved, "A second open rewrites nothing")
  }

  /// Quick Chat's saved records: that release said what a record is with a
  /// number. The file is rewritten once with today's flag and the number gone.
  func testQuickChatRecordsAreConvertedOnce() throws {
    let earlier = Data(#"{"selectedConnectionID":"c","workspaceID":"local","connections":[],"conversations":{"chat":{"id":"chat","quickChatVersion":1,"title":"Chat","connectionID":"c","modelJSON":"{}","status":"ready","updatedAt":""},"kept":{"id":"kept","quickChatVersion":0,"title":"Kept","connectionID":"c","modelJSON":"{}","status":"retained","updatedAt":""}}}"#.utf8)
    let converted = try XCTUnwrap(EarlierPhoneFiles.convertedQuickChatPreferences(earlier))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: converted) as? [String: Any])
    let records = try XCTUnwrap(root["conversations"] as? [String: [String: Any]])
    XCTAssertEqual(records.mapValues { $0["savedHistoryOnly"] as? Bool }, ["chat": false, "kept": true])
    XCTAssertEqual(records.mapValues { $0["status"] as? String }, ["chat": "ready", "kept": "retained"])
    XCTAssertTrue(records.values.allSatisfy { $0["quickChatVersion"] == nil })
    XCTAssertEqual(root["selectedConnectionID"] as? String, "c")
    XCTAssertNil(EarlierPhoneFiles.convertedQuickChatPreferences(converted), "Nothing is left to convert")
    XCTAssertNil(EarlierPhoneFiles.convertedQuickChatPreferences(Data(#"{"conversations":{},"connections":[]}"#.utf8)))
  }
}
