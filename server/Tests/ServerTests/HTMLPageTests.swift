import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

@Test
func aPagesLocalImagesAreEmbeddedOnceAndAMissingOneIsNamed() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-page-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 24)
  let image = folder.appendingPathComponent("dot.png").path
  try png.write(to: URL(fileURLWithPath: image))
  let text = folder.appendingPathComponent("notes.png").path
  try Data("not an image".utf8).write(to: URL(fileURLWithPath: text))
  let large = folder.appendingPathComponent("large.png").path
  try (png + Data(count: HTMLPages.imageLimit)).write(to: URL(fileURLWithPath: large))
  let gone = folder.appendingPathComponent("gone.png").path

  let page = try HTMLPages.prepare("""
    <img src="\(image)"><div style='background:url(\(image))'></div><script>const a = `\(image)`</script>
    <img src="//cdn.example.com/a.png"><img src="https://example.com/b.png">
    <img src="\(text)"><img src="\(large)"><img src="\(gone)"><img src="\(gone)">
    """)
  let uri = "data:image/png;base64," + png.base64EncodedString()
  #expect(page.html.components(separatedBy: uri).count == 4)
  #expect(page.html.contains("\"//cdn.example.com/a.png\"") && page.html.contains("\"https://example.com/b.png\""))
  #expect(page.missingImages == [text, large, gone])

  #expect(throws: ToolFailure.self) { try HTMLPages.prepare(String(repeating: "a", count: HTMLPages.authoredLimit + 1)) }
  // Three references to a 10 MiB image make a page over 25 MiB.
  let full = folder.appendingPathComponent("full.png").path
  try (png + Data(count: HTMLPages.imageLimit - png.count)).write(to: URL(fileURLWithPath: full))
  #expect(throws: ToolFailure.self) { try HTMLPages.prepare("<img src='\(full)'><img src='\(full)'><img src='\(full)'>") }
}

private struct PageServer {
  let server: WovenServer
  let socket: String

  static func start(tailnet: StandInTailnet) async throws -> PageServer {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
    let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: ("127.0.0.1", 0), appVersion: "test", machineName: "test",
      tailnet: tailnet, runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    return PageServer(server: try await WovenServer.start(options), socket: socket)
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))
    return client
  }
}

@Test(.timeLimit(.minutes(1)))
func aPublishedPageIsSavedOnceShownLiveAndFetchedOnAnotherMachine() async throws {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let a = try await PageServer.start(tailnet: tailnetA), b = try await PageServer.start(tailnet: tailnetB)
  defer { a.server.stopLater(); b.server.stopLater() }
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()
  let onA = try await a.connect(), onB = try await b.connect()
  let session = try await onA.call(CreateSession(runtime: StandInRuntime.kind, title: "Sales"))

  // The stand-in calls the tool over its tool socket and then reports the call, as a runtime does.
  let html = "<h1>Quarterly sales</h1>" + String(repeating: "<i>bar</i>", count: 5000)
  let arguments = String(decoding: try Wire.encoder.encode(JSONValue.object([
    "html": .string(html), "title": .string("Sales by quarter"), "height": .integer(320)])), as: UTF8.self)
  let subscription = try await onA.subscribe(SubscribeSession(sessionID: session.id))
  _ = try await onA.call(SendTurn(sessionID: session.id, text: "woven render_html \(arguments)"))
  var live: [SessionItem] = []
  for try await event in subscription.events {
    if case .itemFinished(let item) = event { live.append(item) }
    if event == .runState(.idle) { break }
  }

  let items = try await onA.call(SessionItems(sessionID: session.id))
  #expect(items == live)
  #expect(items.count == 3)
  guard items.count == 3, case .htmlPage(let page) = items[1].content, case .toolCall(let call) = items[2].content else {
    Issue.record("Expected the message, the page, then the call: \(items.map(\.content))")
    return
  }
  #expect(page == HTMLPage(title: "Sales by quarter", height: 320, digest: Library.digest(of: Data(html.utf8)),
                           size: Int64(html.utf8.count)))
  #expect(!call.failed && call.kind == .page)
  #expect(!call.input.contains("Quarterly sales") && call.input.contains("characters, shown in the chat"))
  #expect(try await a.server.library.content(page.digest)?.data == Data(html.utf8))

  // B has the small item by sync, and its UI fetches the page through B.
  var copied: [SessionItem] = []
  for _ in 0..<200 where copied != items {
    copied = try await onB.call(SessionItems(sessionID: session.id))
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(copied == items)
  #expect(try await b.server.library.hasContent(page.digest) == false)
  #expect(try await onB.call(FetchContent(digest: page.digest)).data == Data(html.utf8))
}
