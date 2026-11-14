import Foundation
import Testing
import WovenMatterShared

/// The fixture file is shared with the Node server's tests, which decode and
/// re-encode the same frames.
private struct StreamFixtures: Decodable {
  struct Named: Decodable { let name: String; let frame: JSONValue }
  struct Prefixed: Decodable { let frame: JSONValue; let hex: String }
  let `protocol`: Int
  let frames: [Named]
  let unknownFrames: [JSONValue]
  let lengthPrefixed: Prefixed

  static func load() throws -> Self {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "StreamProtocolFixtures.json")
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
}

private func json(_ value: JSONValue) throws -> Data { try JSONEncoder().encode(value) }

private func object(_ data: Data) throws -> NSObject {
  try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
}

@Suite struct StreamProtocolTests {
  @Test func fixturesRoundTripExactly() throws {
    let fixtures = try StreamFixtures.load()
    #expect(fixtures.protocol == StreamProtocol.version)
    for fixture in fixtures.frames {
      let source = try json(fixture.frame)
      let frame = try StreamProtocol.decode(source)
      if case .unknown = frame { Issue.record("\(fixture.name) decoded as an unknown frame") }
      let encoded = try StreamProtocol.encode(frame)
      #expect(try object(encoded) == object(source), "\(fixture.name) did not round-trip")
    }
  }

  @Test func everyFrameTypeAndItemKindHasAFixture() throws {
    let frames = try StreamFixtures.load().frames.map { try StreamProtocol.decode(json($0.frame)) }
    var types = Set<String>(), kinds = Set<String>()
    for frame in frames {
      switch frame {
      case .hello: types.insert("hello")
      case .request: types.insert("req")
      case .response: types.insert("res")
      case .subscribe: types.insert("sub")
      case .item(let item): types.insert("item"); kinds.insert(item.payload.kind)
      case .end: types.insert("end")
      case .cancel: types.insert("cancel")
      case .unknown: break
      }
    }
    #expect(types == ["hello", "req", "res", "sub", "item", "end", "cancel"])
    let known = Set(["conversations", "pending", "journal", "transcript", "capabilities", "session", "owner", "library", "synchronized", "server.state"])
    #expect(known.isSubset(of: kinds))
  }

  @Test func unknownFramesAndKindsAreTolerated() throws {
    let fixtures = try StreamFixtures.load()
    for frame in fixtures.unknownFrames {
      #expect(try StreamProtocol.decode(json(frame)) == .unknown("futureFrame"))
    }
    let item = try #require(fixtures.frames.first { $0.name == "item-unknown-kind" })
    guard case .item(let decoded) = try StreamProtocol.decode(json(item.frame)) else { Issue.record("not an item"); return }
    #expect(decoded.seq == 43)
    #expect(decoded.payload.kind == "futureKind")
  }

  /// A newer server's item of a kind this build knows, holding a value it does
  /// not, is valid JSON: it decodes as an ignored item that keeps its `seq`
  /// rather than failing the frame, which closes the socket with 4400 and
  /// reconnects into the same item.
  @Test func anItemOfAKnownKindThisBuildCannotReadIsIgnoredAndKeepsItsSequence() throws {
    func item(_ json: String) throws -> StreamItem {
      guard case .item(let item) = try StreamProtocol.decode(Data(json.utf8)) else { throw StreamProtocolError.unknownFrame("not an item") }
      return item
    }
    let journal = try item(#"{"t":"item","id":"s1","seq":44,"kind":"journal","data":{"entry":{"eventID":"e","workspaceID":"w","originSequence":44,"conversationID":"c","kind":"forkedConversation"}}}"#)
    #expect(journal.seq == 44 && journal.payload.kind == "journal")
    guard case .unknown(_, let data) = journal.payload else { Issue.record("decoded as a journal entry"); return }
    #expect(data.objectValue?["entry"]?.objectValue?["originSequence"]?.intValue == 44)
    let transcript = try item(#"{"t":"item","id":"s2","kind":"transcript","data":{"transcript":{"conversationID":7},"snapshot":true}}"#)
    #expect(transcript.payload == .unknown(kind: "transcript", data: .object(["transcript": .object(["conversationID": .number(7)]), "snapshot": .bool(true)])))
    // Inside an item, only the part this build cannot read is dropped.
    let pending = try item(#"{"t":"item","id":"s1","kind":"pending","data":{"interactions":[{"id":"q1","conversationID":"c","kind":"signature","title":"Sign","options":[],"questions":[]},{"id":"q2","conversationID":"c","kind":"question","title":"Which?","options":[],"questions":[]}]}}"#)
    guard case .pending(let value) = pending.payload else { Issue.record("not pending"); return }
    #expect(value.interactions.map(\.id) == ["q2"])
    // A frame that is not JSON, or has no type, is still a protocol violation.
    #expect(throws: (any Error).self) { try StreamProtocol.decode(Data("{".utf8)) }
    #expect(throws: (any Error).self) { try StreamProtocol.decode(Data(#"{"id":"s1","kind":"journal"}"#.utf8)) }
    #expect(throws: (any Error).self) { try StreamProtocol.decode(Data(#"{"t":"item","kind":"journal","data":{}}"#.utf8)) }
  }

  @Test func lengthPrefixedFramesMatchTheFixtureAndSplit() throws {
    let fixture = try StreamFixtures.load().lengthPrefixed
    let frame = try StreamProtocol.decode(json(fixture.frame))
    let data = try StreamProtocol.lengthPrefixed(frame)
    #expect(data.map { String(format: "%02x", $0) }.joined() == fixture.hex)

    var buffer = data + data + data.prefix(3)
    let split = try StreamProtocol.takeLengthPrefixedFrames(from: &buffer)
    #expect(split == [frame, frame])
    #expect(buffer.count == 3)
    buffer.append(data.dropFirst(3))
    #expect(try StreamProtocol.takeLengthPrefixedFrames(from: &buffer) == [frame])
    #expect(buffer.isEmpty)
  }

  @Test func oversizedFramesAreRefused() throws {
    var buffer = Data([0x7f, 0xff, 0xff, 0xff])
    #expect(throws: StreamProtocolError.self) { try StreamProtocol.takeLengthPrefixedFrames(from: &buffer) }
    let huge = StreamFrame.item(.init(id: "s", payload: .serverState(.init(scopes: [String(repeating: "x", count: StreamProtocol.maximumFrameBytes)]))))
    #expect(throws: StreamProtocolError.self) { try StreamProtocol.encode(huge) }
  }

  @Test func typedRequestsAndResponses() throws {
    let command = LibraryCommand(commandID: "c1", deviceID: "d1", kind: .stop, conversationID: "v1", runID: "r1")
    let request = try StreamRequest(id: "q", method: .executionCommand, params: StreamCommandParams(command: command))
    #expect(try request.decodeParams(StreamCommandParams.self).command == command)
    let receipt = LibraryCommandReceipt(commandID: "c1", deviceID: "d1", status: .accepted)
    #expect(try StreamResponse(id: "q", encoding: receipt).decodeResult(LibraryCommandReceipt.self) == receipt)
    let failure = StreamResponse(id: "q", error: .init(.conflict, "busy"))
    #expect(throws: StreamError.self) { try failure.decodeResult(LibraryCommandReceipt.self) }
  }
}
