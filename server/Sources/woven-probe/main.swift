import Foundation
import WovenProtocol
import WovenServerKit

// woven-probe: talks to a running woven-server over its Unix socket, for
// checking it by hand. The socket is --socket PATH or $WOVEN_SOCKET.
let usage = """
  usage: woven-probe [--socket PATH] COMMAND
    runtimes                         which runtimes are installed and signed in here
    install RUNTIME                  install or update a runtime
    sign-ins                         Pi Durable's providers on this machine
    sign-in PROVIDER                 run a subscription's sign-in; prompts are read from stdin
    sign-out PROVIDER
    set-key PROVIDER [KEY]           set (or, without KEY, remove) an API key everywhere
    machines | sessions | folders
    create RUNTIME [TITLE] [--folder ID]
    send SESSION TEXT [--attach FILE]... [--approve OPTION]
                                     send a turn and print the stream until it ends
    watch SESSION                    print the live stream until interrupted
    items SESSION                    print the saved items
    configure SESSION [--model M] [--thinking T] [--permission P]
    answer SESSION PROMPT ANSWER | interrupt SESSION | stop SESSION | delete SESSION
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("woven-probe: \(message)\n".utf8))
  exit(2)
}

func out(_ text: String, terminator: String = "\n") {
  FileHandle.standardOutput.write(Data((text + terminator).utf8))
}

func json<T: Encodable>(_ value: T) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  encoder.dateEncodingStrategy = .iso8601
  return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "?"
}

var arguments = Array(CommandLine.arguments.dropFirst())
var socket = ProcessInfo.processInfo.environment["WOVEN_SOCKET"]
if let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count {
  socket = arguments[index + 1]
  arguments.removeSubrange(index...(index + 1))
}

/// Takes every `--name VALUE` out of the arguments.
@MainActor func options(_ name: String) -> [String] {
  var values: [String] = []
  while let index = arguments.firstIndex(of: name), index + 1 < arguments.count {
    values.append(arguments[index + 1])
    arguments.removeSubrange(index...(index + 1))
  }
  return values
}

guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()
guard let socket else { fail("say which server: --socket PATH or WOVEN_SOCKET") }

let client: Client
do {
  client = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await client.open(Hello(role: .ui, machine: Machine(id: "probe", name: "woven-probe"),
                                  appVersion: ProcessInfo.processInfo.environment["WOVEN_APP_VERSION"] ?? "dev"))
} catch {
  fail("could not connect to \(socket): \(error)")
}

@MainActor func argument(_ index: Int, _ name: String) -> String {
  guard index < arguments.count else { fail("\(command) needs \(name)\n\(usage)") }
  return arguments[index]
}

func describe(_ content: ItemContent) -> String {
  switch content {
  case .userMessage(let text, let attachments):
    return "you: \(text)" + (attachments.isEmpty ? "" : " [" + attachments.map { "\($0.name) \($0.digest.prefix(12))" }.joined(separator: ", ") + "]")
  case .assistantMessage(let text):
    return "assistant: \(text)"
  case .toolCall(let call):
    var line = "tool \(call.kind?.rawValue ?? call.name): \(call.title ?? call.name)"
    if let plan = call.plan { line += " " + plan.map { "[\($0.status.rawValue)] \($0.text)" }.joined(separator: "; ") }
    else if !call.input.isEmpty { line += " input=\(call.input.prefix(200))" }
    if let output = call.output, !output.isEmpty { line += " → \(output.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(300))" }
    if call.failed { line += " (failed)" }
    return line
  case .notice(let notice):
    return "notice \(notice.kind.rawValue): \(notice.text)"
  }
}

func show(_ configuration: SessionConfiguration) {
  out("model: \(configuration.model ?? "-")  thinking: \(configuration.thinking ?? "-")  permission: \(configuration.permission ?? "-")")
  if !configuration.models.isEmpty { out("  models: " + configuration.models.prefix(12).map(\.id).joined(separator: ", ")
                                         + (configuration.models.count > 12 ? " … (\(configuration.models.count))" : "")) }
  if !configuration.thinkingLevels.isEmpty { out("  thinking levels: " + configuration.thinkingLevels.map(\.id).joined(separator: ", ")) }
  if !configuration.permissionModes.isEmpty { out("  permission modes: " + configuration.permissionModes.map(\.id).joined(separator: ", ")) }
  if !configuration.commands.isEmpty { out("  commands: " + configuration.commands.prefix(12).map { "/" + $0.name }.joined(separator: " ")) }
}

/// Prints a session's live events. Returns when the turn ends, if `untilIdle`.
@MainActor func follow(_ subscription: ClientSubscription<SubscribeSession>, sessionID: String, untilIdle: Bool,
            approve: String?, sawRunning: Bool = false) async throws {
  var running = sawRunning
  var streaming = false
  func endLine() { if streaming { out(""); streaming = false } }
  for try await event in subscription.events {
    switch event {
    case .itemStarted(let item):
      if case .assistantMessage = item.content { endLine(); out("assistant (streaming): ", terminator: ""); streaming = true }
      else { endLine(); out("… started " + describe(item.content)) }
    case .text(_, let delta):
      out(delta, terminator: "")
      streaming = true
    case .toolActivity(_, let call):
      endLine()
      out("… " + describe(.toolCall(call)))
    case .itemFinished(let item):
      endLine()
      out("✓ saved #\(item.sequence) " + describe(item.content))
    case .itemDropped(let id):
      endLine()
      out("✗ dropped \(id)")
    case .runState(let state):
      endLine()
      out("run: \(state.rawValue)")
      if state == .running { running = true }
      if untilIdle && running && state != .running { return }
    case .awaiting(let prompt):
      endLine()
      out("? \(prompt.kind.rawValue) \(prompt.id): \(prompt.text) options: " + prompt.options.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
          + (prompt.fields.isEmpty ? "" : " fields: " + prompt.fields.map { "\($0.id) (\($0.kind.rawValue))" }.joined(separator: ", ")))
      if let approve, let option = prompt.options.first(where: { $0.id == approve || $0.name == approve }) ?? prompt.options.first {
        out("  answering \(option.id)")
        _ = try await client.call(AnswerPrompt(sessionID: sessionID, promptID: prompt.id, answer: .option(option.id)))
      }
    case .answered(let id):
      out("answered \(id)")
    case .configuration(let configuration):
      endLine()
      out("configuration changed: ", terminator: "")
      show(configuration)
    }
  }
}

func mimeType(_ url: URL) -> String {
  switch url.pathExtension.lowercased() {
  case "png": "image/png"
  case "jpg", "jpeg": "image/jpeg"
  case "gif": "image/gif"
  case "txt", "md", "swift", "json", "py", "js", "html", "csv": "text/plain"
  case "pdf": "application/pdf"
  default: "application/octet-stream"
  }
}

do {
  switch command {
  case "runtimes":
    for status in try await client.call(ListRuntimes()) {
      let signedIn = status.signedIn.map { $0 ? "signed in" : "not signed in" } ?? "sign-in unknown"
      out("\(status.runtime.rawValue)\t\(status.installed ? "installed" : "not installed")\t\(status.version ?? "-")\t\(signedIn)"
          + (status.detail.map { "\t\($0)" } ?? ""))
    }
  case "install":
    out(json(try await client.call(InstallRuntime(runtime: RuntimeKind(rawValue: argument(0, "RUNTIME"))))))
  case "sign-ins":
    for signIn in try await client.call(ListSignIns()) {
      out("\(signIn.provider)\t\(signIn.kind.rawValue)\t\(signIn.connected ? "connected" : "-")\t\(signIn.name)")
    }
  case "sign-in":
    let flow = try await client.subscribe(StartSignIn(provider: argument(0, "PROVIDER")))
    for try await event in flow.events {
      switch event {
      case .open(let url, let code, let instructions):
        out("open \(url)" + (code.map { "  code \($0)" } ?? "") + (instructions.map { "  (\($0))" } ?? ""))
      case .prompt(let id, let message):
        out("\(message) ", terminator: "")
        _ = try await client.call(AnswerSignIn(flowID: flow.reply, promptID: id, answer: readLine() ?? ""))
      case .finished(let signIn):
        out("signed in: \(signIn.name) \(signIn.connected ? "connected" : "not connected")")
      case .failed(let message):
        out("failed: \(message)")
      }
    }
  case "sign-out":
    _ = try await client.call(SignOut(provider: argument(0, "PROVIDER")))
    out("done")
  case "set-key":
    _ = try await client.call(SetAPIKey(provider: argument(0, "PROVIDER"), key: arguments.count > 1 ? arguments[1] : nil))
    out("done")
  case "machines":
    for status in try await client.call(ListMachines()) {
      out("\(status.machine.id)\t\(status.machine.name)\t\(status.machine.platform.rawValue)\t\(status.online ? "online" : "offline")"
          + (status.isThisMachine ? "\tthis machine" : ""))
    }
  case "sessions":
    for session in try await client.call(ListSessions(includeArchived: true)) {
      out("\(session.id)\t\(session.runtime.rawValue)\t\(session.title)\t\(session.directory)\t\(session.model ?? "-")")
    }
  case "folders":
    for folder in try await client.call(ListFolders()) { out("\(folder.id)\t\(folder.name)\t\(folder.path)") }
  case "create":
    let folder = options("--folder").first
    let runtime = RuntimeKind(rawValue: argument(0, "RUNTIME"))
    let title = arguments.count > 1 ? arguments[1] : "Probe"
    let session = try await client.call(CreateSession(runtime: runtime, title: title, folderID: folder))
    out("session \(session.id)")
    out("directory \(session.directory)")
    let snapshot = try await client.subscribe(SubscribeSession(sessionID: session.id))
    show(snapshot.reply.configuration)
    try await client.unsubscribe(snapshot.id)
  case "send":
    let attachments = options("--attach")
    let approve = options("--approve").first
    let sessionID = argument(0, "SESSION")
    let text = argument(1, "TEXT")
    var attached: [Attachment] = []
    for path in attachments {
      let url = URL(fileURLWithPath: path)
      let data = try Data(contentsOf: url)
      let stored = try await client.call(PutContent(data: data))
      attached.append(Attachment(name: url.lastPathComponent, mimeType: mimeType(url), digest: stored.digest, size: stored.size))
    }
    let subscription = try await client.subscribe(SubscribeSession(sessionID: sessionID))
    out("(\(subscription.reply.items.count) saved items; run \(subscription.reply.run.rawValue))")
    _ = try await client.call(SendTurn(sessionID: sessionID, text: text, attachments: attached))
    try await follow(subscription, sessionID: sessionID, untilIdle: true, approve: approve)
  case "watch":
    let sessionID = argument(0, "SESSION")
    let subscription = try await client.subscribe(SubscribeSession(sessionID: sessionID))
    out("(\(subscription.reply.items.count) saved items; run \(subscription.reply.run.rawValue))")
    show(subscription.reply.configuration)
    for item in subscription.reply.inProgress { out("… in progress " + describe(item.content)) }
    try await follow(subscription, sessionID: sessionID, untilIdle: false, approve: nil)
  case "items":
    let items = try await client.call(SessionItems(sessionID: argument(0, "SESSION")))
    for item in items { out("#\(item.sequence) \(item.id.prefix(8)) " + describe(item.content)) }
    out("\(items.count) items, \(Set(items.map(\.id)).count) distinct ids, sequences "
        + (items.isEmpty || items.map(\.sequence) == Array(1...items.count) ? "1…\(items.count) without gaps" : "WITH GAPS"))
  case "configure":
    let model = options("--model").first, thinking = options("--thinking").first, permission = options("--permission").first
    show(try await client.call(ConfigureSession(sessionID: argument(0, "SESSION"), model: model, thinking: thinking, permission: permission)))
  case "answer":
    // A JSON object answers a form; anything else is an option's id.
    let text = argument(2, "ANSWER")
    let answer: PromptAnswer = if let values = try? Wire.decoder.decode([String: JSONValue].self, from: Data(text.utf8)) {
      .values(values)
    } else { .option(text) }
    _ = try await client.call(AnswerPrompt(sessionID: argument(0, "SESSION"), promptID: argument(1, "PROMPT"), answer: answer))
    out("done")
  case "interrupt":
    _ = try await client.call(InterruptTurn(sessionID: argument(0, "SESSION")))
    out("done")
  case "stop":
    _ = try await client.call(StopSession(sessionID: argument(0, "SESSION")))
    out("done")
  case "delete":
    _ = try await client.call(DeleteSession(sessionID: argument(0, "SESSION")))
    out("done")
  default:
    fail(usage)
  }
} catch let error as ProtocolError {
  fail("\(error.code.rawValue): \(error.message)")
} catch {
  fail("\(error)")
}
await client.close()
