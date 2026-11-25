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

/// A large page can come from a file the agent wrote on this machine instead
/// of its HTML; exactly one of them, and never from a bot, whose files are
/// elsewhere. A script's call keeps the path.
@Test
func aVisualReplyCanComeFromAFileOnThisMachine() throws {
  let page = FileManager.default.temporaryDirectory.appendingPathComponent("woven-\(UUID().uuidString).html")
  try Data("<h1>Sales</h1>".utf8).write(to: page)
  defer { try? FileManager.default.removeItem(at: page) }
  func authored(_ fields: [String: JSONValue], fromBot: Bool = false) -> String {
    do { return try VisualReplies.authored(Arguments(value: .object(fields)), fromBot: fromBot) } catch { return "\(error)" }
  }
  #expect(authored(["path": .string(page.path)]) == "<h1>Sales</h1>")
  #expect(authored(["html": .string("<p>Hi</p>"), "path": .string("")]) == "<p>Hi</p>")
  #expect(authored(["path": .string(page.path)], fromBot: true).contains("give the HTML itself as `html`"))
  #expect(authored(["html": .string("<p>Hi</p>"), "path": .string(page.path)]) == "Give `html` or `path`, not both.")
  #expect(authored([:]) == "Give `html`, or the `path` of an HTML file.")
  #expect(authored(["path": .string("page.html")]).contains("absolute"))
  #expect(authored(["path": .string(page.path + ".gone")]).hasPrefix("There is no file"))

  let input = #"{"path":"\#(page.path)","title":"Sales"}"#
  let call = VisualReplies.withoutVisualReply(ToolCall(name: "execute", input: "", kind: .code,
                                                       calls: [ToolCall(name: "woven.render_html", input: input)]))
  #expect(call.calls == [ToolCall(name: "woven.render_html", input: input, kind: .visualReply)])
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
  let machine = try await VisualReplyServer.start(tailnet: StandInTailnet())
  defer { machine.server.stopLater() }
  let tools = try #require(await machine.server.bots.toolsForTests)
  let offered = tools.listing(forBots: true).compactMap { $0["name"]?.string }
  #expect(["render_html", "preview_html", "browser", "computer"].allSatisfy(offered.contains))
  let bot = ToolCaller(machineID: machine.server.machineID, botID: "b1")
  #expect(await tools.call("list_bots", arguments: .object([:]), caller: bot) == .error("Bots cannot use list_bots."))

  let image = FileManager.default.temporaryDirectory.appendingPathComponent("woven-\(UUID().uuidString).png")
  try (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 24)).write(to: image)
  defer { try? FileManager.default.removeItem(at: image) }
  let html = "<p>Hi</p><img src=\"\(image.path)\">"

  let ui = try await machine.connect()
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
  #expect(previewed.structuredContent == output)

  let result = await tools.call("render_html", arguments: .object(["html": .string(html)]), caller: bot)
  #expect(!result.isError)
  let digest = try #require(result.meta?["wovenVisualReply"]?["digest"]?.string)
  #expect(try await machine.server.library.content(digest)?.data == Data(html.utf8))
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

@Test
func aScriptKeepsItsToolCallsWithoutTheVisualReplyOrAPageWrittenIntoIt() throws {
  let page = "<!doctype html><html><body>" + String(repeating: "<p>Quarterly sales</p>", count: 200) + "</body></html>"
  let json = String(decoding: try Wire.encoder.encode(JSONValue.object(["html": .string(page), "title": .string("Sales")])),
                    as: UTF8.self)
  let pieces = stride(from: 0, to: page.count, by: 300).map { offset in
    "'" + page.dropFirst(offset).prefix(300) + "'"
  }
  let scripts = [
    // In a template literal, with a part.
    "const title = 'Sales';\nawait tools.woven.render_html({ title, html: `\(page.replacingOccurrences(of: "Quarterly", with: "${title}"))` });",
    // In a JSON string.
    "await tools.mcp__woven__render_html(\(json));",
    // Built by concatenation, around a comment, a regular expression and a division.
    "// a 'quote\nconst ratio = 4 / 2; const tag = /<\\/?p>/g;\nconst html = " + pieces.joined(separator: " +\n  ")
      + ";\nawait tools.woven.render_html({ html: html.replace(tag, '') });",
  ]
  for script in scripts {
    let call = VisualReplies.withoutVisualReply(ToolCall(
      name: "execute", input: script, output: "done", kind: .code,
      calls: [ToolCall(name: "woven.list_sessions", input: "{}"),
              ToolCall(name: "woven.render_html", input: json),
              ToolCall(name: "mcp__woven__render_html", input: json)]))
    let encoded = String(decoding: try Wire.encoder.encode(call), as: UTF8.self).lowercased()
    #expect(!encoded.contains("<html") && !encoded.contains("<!doctype") && !encoded.contains("quarterly"), "\(script.prefix(60))")
    #expect(call.input.contains("characters)") && call.output == "done")
    #expect(call.calls?.map(\.kind) == [nil, .visualReply, .visualReply])
    #expect(call.calls?[1].input.contains("\"title\":\"Sales\"") == true)
  }
  // Short literals, comments and code stay as written.
  let short = "const a = 'x' + \"y\"; // `not a template\nconst b = `${a}${'}'}` / 2; const c = /'/;"
  #expect(CodeCalls.elidingLongLiterals(short) == short)
  // A long string that does not end on its line is left as written.
  let open = "const a = '" + String(repeating: "x", count: 3_000) + "\nconst b = 1;"
  #expect(CodeCalls.elidingLongLiterals(open) == open)
}

@Test
func aScriptKeepsItsFirstToolCallsAndSaysHowManyMoreItMade() {
  let calls = (0..<250).map { ToolCall(name: "woven.read_session", input: #"{"sessionID":"s\#($0)"}"#) }
  let call = VisualReplies.withoutVisualReply(ToolCall(name: "codemode", input: "", kind: .code, calls: calls))
  #expect(call.calls?.count == CodeCalls.callLimit)
  #expect(call.calls?.dropLast() == calls.prefix(CodeCalls.callLimit - 1))
  #expect(call.calls?.last == ToolCall(name: "", input: "", title: "151 more tool calls"))
  // Read again, it stays as it is.
  #expect(VisualReplies.withoutVisualReply(call) == call)
  // A stored tool call from before scripts reads without calls.
  let stored = try? JSONDecoder().decode(ToolCall.self, from: Data(#"{"name":"bash","input":"ls","failed":false}"#.utf8))
  #expect(stored == ToolCall(name: "bash", input: "ls"))
}

@Test(.timeLimit(.minutes(1)))
func aScriptThatPublishesAVisualReplyIsSavedAsTheVisualReplyAndOneScript() async throws {
  let machine = try await VisualReplyServer.start(tailnet: StandInTailnet())
  defer { machine.server.stopLater() }
  let ui = try await machine.connect()
  let session = try await ui.call(CreateSession(runtime: StandInRuntime.kind, title: "Sales"))
  _ = try await ui.call(UpdateSession(sessionID: session.id, tools: []))

  let html = "<!doctype html><title>Sales</title><h1>Quarterly sales</h1>" + String(repeating: "<i>bar</i>", count: 500)
  let arguments = String(decoding: try Wire.encoder.encode(JSONValue.object(["html": .string(html)])), as: UTF8.self)
  let subscription = try await ui.subscribe(SubscribeSession(sessionID: session.id))
  _ = try await ui.call(SendTurn(sessionID: session.id, text: "code woven render_html \(arguments)"))
  var shown: [ToolCall] = []
  for try await event in subscription.events {
    if case .itemStarted(let item) = event, case .toolCall(let call) = item.content { shown.append(call) }
    if case .toolActivity(_, let call) = event { shown.append(call) }
    if event == .runState(.idle) { break }
  }

  let items = try await ui.call(SessionItems(sessionID: session.id))
  guard items.count == 3, case .visualReply(let reply) = items[1].content, case .toolCall(let call) = items[2].content else {
    Issue.record("Expected the message, the visual reply, then the script: \(items.map(\.content))")
    return
  }
  #expect(reply.digest == Library.digest(of: Data(html.utf8)))
  #expect(call.kind == .code && !call.failed && call.calls?.count == 1 && call.calls?.first?.kind == .visualReply)
  for call in shown + [call] {
    let encoded = String(decoding: try Wire.encoder.encode(call), as: UTF8.self)
    #expect(!encoded.contains("Quarterly sales") && !encoded.contains("<!doctype"))
  }
}
