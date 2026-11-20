import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

@Test
func localImagesInAVisualReplyAreEmbeddedOnceAndAMissingOneIsNamed() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-visual-reply-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 24)
  let image = folder.appendingPathComponent("dot.png").path
  try png.write(to: URL(fileURLWithPath: image))
  let text = folder.appendingPathComponent("notes.png").path
  try Data("not an image".utf8).write(to: URL(fileURLWithPath: text))
  let large = folder.appendingPathComponent("large.png").path
  try (png + Data(count: VisualReplies.imageLimit)).write(to: URL(fileURLWithPath: large))
  let gone = folder.appendingPathComponent("gone.png").path

  let reply = try VisualReplies.prepare("""
    <img src="\(image)"><div style='background:url(\(image))'></div><script>const a = `\(image)`</script>
    <img src="//cdn.example.com/a.png"><img src="https://example.com/b.png">
    <img src="\(text)"><img src="\(large)"><img src="\(gone)"><img src="\(gone)">
    """)
  let uri = "data:image/png;base64," + png.base64EncodedString()
  #expect(reply.html.components(separatedBy: uri).count == 4)
  #expect(reply.html.contains("\"//cdn.example.com/a.png\"") && reply.html.contains("\"https://example.com/b.png\""))
  #expect(reply.missingImages == [text, large, gone])

  #expect(throws: ToolFailure.self) { try VisualReplies.prepare(String(repeating: "a", count: VisualReplies.authoredLimit + 1)) }
  // Three references to a 10 MiB image make a visual reply over 25 MiB.
  let full = folder.appendingPathComponent("full.png").path
  try (png + Data(count: VisualReplies.imageLimit - png.count)).write(to: URL(fileURLWithPath: full))
  #expect(throws: ToolFailure.self) { try VisualReplies.prepare("<img src='\(full)'><img src='\(full)'><img src='\(full)'>") }
  // A visual reply sized by the viewport would grow with its frame.
  #expect(throws: ToolFailure.self) { try VisualReplies.prepare("<div style='min-height: 100vh'></div>") }
  #expect(throws: ToolFailure.self) { try VisualReplies.prepare("<style>main{height:calc(50dvh - 2px)}</style>") }
}

@Test
func everyRuntimesReportOfTheCallIsKeptWithoutTheVisualReply() {
  let input = #"{"html":"<h1>Sales</h1>","title":"Sales"}"#
  let forms: [(name: String, title: String?)] = [
    ("mcp__woven__render_html", nil), ("other", "mcp__woven__render_html"), ("other", "mcp.woven.render_html"),
    ("woven_render_html", nil), ("render_html", nil), ("other", "Tool: woven/render_html"), ("other", "woven: render_html"),
  ]
  for form in forms {
    let call = VisualReplies.withoutVisualReply(ToolCall(name: form.name, input: input, title: form.title))
    #expect(call.kind == .visualReply && !call.input.contains("<h1>"), "\(form)")
  }
  for name in ["mcp__charts__render_html", "render_html_preview", "preview_html", "rewoven_render_html"] {
    #expect(VisualReplies.withoutVisualReply(ToolCall(name: name, input: input)).input == input, "\(name)")
  }
}

@Test(.timeLimit(.minutes(1)))
func aBotIsOfferedTheHostsToolsButNothingOnTheHostIsReadForItsVisualReply() async throws {
  let host = try await VisualReplyServer.start(tailnet: StandInTailnet())
  defer { host.server.stopLater() }
  let tools = try #require(await host.server.bots.toolsForTests)
  let offered = tools.listing(forBots: true).compactMap { $0["name"]?.string }
  #expect(["render_html", "preview_html", "browser", "computer"].allSatisfy(offered.contains))
  let bot = ToolCaller(machineID: host.server.machineID, botID: "b1")
  #expect(await tools.call("list_bots", arguments: .object([:]), caller: bot) == .error("Bots cannot use list_bots."))

  let image = FileManager.default.temporaryDirectory.appendingPathComponent("woven-\(UUID().uuidString).png")
  try (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 24)).write(to: image)
  defer { try? FileManager.default.removeItem(at: image) }
  let html = "<p>Hi</p><img src=\"\(image.path)\">"

  let ui = try await host.connect()
  let calls = try await ui.subscribe(SubscribeUITools())
  let asked = Task { () -> UIToolCall? in
    for try await call in calls.events {
      _ = try await ui.call(AnswerUITool(id: call.id, result: ToolResult(content: [.text(#"{"contentHeight":120}"#)])))
      return call
    }
    return nil
  }
  let previewed = await tools.call("preview_html", arguments: .object(["html": .string(html)]), caller: bot)
  #expect(try #require(try await asked.value).arguments["html"]?.string == html)
  guard case .text(let text)? = previewed.content.first else { Issue.record("No preview text"); return }
  let output = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  #expect(output["missingImages"]?.array == [.string(image.path)])

  let result = await tools.call("render_html", arguments: .object(["html": .string(html)]), caller: bot)
  #expect(!result.isError)
  let digest = try #require(result.meta?["wovenVisualReply"]?["digest"]?.string)
  #expect(try await host.server.library.content(digest)?.data == Data(html.utf8))
}

private struct VisualReplyServer {
  let server: WovenServer
  let socket: String

  static func start(tailnet: StandInTailnet) async throws -> VisualReplyServer {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
    let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: ("127.0.0.1", 0), appVersion: "test", machineName: "test",
      tailnet: tailnet, runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    return VisualReplyServer(server: try await WovenServer.start(options), socket: socket)
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))
    return client
  }
}

@Test(.timeLimit(.minutes(1)))
func aPublishedVisualReplyIsSavedOnceShownLiveAndFetchedOnAnotherMachine() async throws {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let a = try await VisualReplyServer.start(tailnet: tailnetA), b = try await VisualReplyServer.start(tailnet: tailnetB)
  defer { a.server.stopLater(); b.server.stopLater() }
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()
  let onA = try await a.connect(), onB = try await b.connect()
  let session = try await onA.call(CreateSession(runtime: StandInRuntime.kind, title: "Sales"))
  // No saved selection of tool groups switches it off.
  _ = try await onA.call(UpdateSession(sessionID: session.id, tools: []))

  // The stand-in calls the tool over its tool socket and then reports the call, as a runtime does.
  // Only the visual reply: its title is its own <title>, and it starts at the default height.
  let html = "<title>Sales by quarter</title><h1>Quarterly sales</h1>" + String(repeating: "<i>bar</i>", count: 5000)
  let arguments = String(decoding: try Wire.encoder.encode(JSONValue.object(["html": .string(html)])), as: UTF8.self)
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
  guard items.count == 3, case .visualReply(let reply) = items[1].content, case .toolCall(let call) = items[2].content else {
    Issue.record("Expected the message, the visual reply, then the call: \(items.map(\.content))")
    return
  }
  #expect(reply == VisualReply(title: "Sales by quarter", height: 320, digest: Library.digest(of: Data(html.utf8)),
                           size: Int64(html.utf8.count)))
  #expect(!call.failed && call.kind == .visualReply)
  #expect(!call.input.contains("Quarterly sales") && call.input.contains("characters, shown in the chat"))
  #expect(try await a.server.library.content(reply.digest)?.data == Data(html.utf8))

  // B has the small item by sync, and its UI fetches the visual reply through B.
  var copied: [SessionItem] = []
  for _ in 0..<200 where copied != items {
    copied = try await onB.call(SessionItems(sessionID: session.id))
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(copied == items)
  #expect(try await b.server.library.hasContent(reply.digest) == false)
  #expect(try await onB.call(FetchContent(digest: reply.digest)).data == Data(html.utf8))
}
