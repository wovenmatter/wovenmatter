import Foundation
import WovenProtocol
import WovenServerKit

// woven-probe: talks to a running woven-server over its Unix socket, for
// checking it by hand. The socket is --socket PATH or $WOVEN_SOCKET; a data
// folder there means that folder's server socket.
let usage = """
  usage: woven-probe [--socket PATH|DATA-FOLDER] COMMAND
    runtimes                         which runtimes are installed and signed in here
    install RUNTIME                  install or update a runtime
    sign-ins                         Pi Durable's providers on this machine
    sign-in PROVIDER                 run a subscription's sign-in; prompts are read from stdin
    sign-out PROVIDER
    set-key PROVIDER [KEY]           set (or, without KEY, remove) an API key everywhere
    machines | sessions | folders | settings | folder-create NAME
    devices                          tailnet computers without a Woven server
    device-install HOST [USER]       install the Linux server there over SSH
    device-update MACHINE | remove MACHINE | rename NAME [MACHINE]
    server MACHINE start|stop|restart  control a machine's server, as Settings does (stop confirmed)
    server-log MACHINE               the end of a machine's server log
    create RUNTIME [TITLE] [--folder ID]
    send SESSION TEXT [--attach FILE]... [--approve OPTION]
                                     send a turn and print the stream until it ends
    watch SESSION                    print the live stream until interrupted
    items SESSION                    print the saved items
    configure SESSION [--model M] [--thinking T] [--permission P]
    answer SESSION PROMPT ANSWER | interrupt SESSION | stop SESSION | delete SESSION
    goal SESSION [TEXT]              set a session's goal, or without TEXT clear it
    schedules                        the scheduler's entries, with what this machine fired of its own
    task RUNTIME TITLE PROMPT [--in SECONDS] [--every UNIT] [--model M] [--folder ID]
                                     schedule a task on this machine, by default in 5 seconds
    schedule-delete ID
    artifacts                        notes, pages, sheets and apps, with their stamps
    artifact ID                      print an artifact's document
    artifact-create KIND TITLE [FILE]
                                     create one (note, canvas, spreadsheet, html), FILE its document
    artifact-write ID FILE [--based-on STAMP]
                                     write a document, by default based on an old stamp so it conflicts
    versions ID                      an artifact's version history
    trash ID | restore ID
    app-state ID KEY JSON            set one key of an app's saved state
    setting KEY JSON                 set a synced setting, e.g. setting tools.defaults '["notes"]'
    databases | db-create NAME | db-execute ID SQL | db-query ID SQL
    bots                             the bots and their chats as the library holds them
    bots-call JSON                   pass one request to the bots runtime, e.g. '{"type":"bots.list"}'
    bots-follow [OPEN_JSON]          print the bots' status and messages (or one opened conversation's)
    bots-home MACHINE                choose the bots' first home, as Settings → Bots does
    bots-transfer MACHINE            move the bots to that machine, as Settings → Bots does
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
guard var socket else { fail("say which server: --socket PATH or WOVEN_SOCKET") }
var isFolder: ObjCBool = false
if FileManager.default.fileExists(atPath: socket, isDirectory: &isFolder), isFolder.boolValue {
  socket = SocketFolder.directory(for: URL(fileURLWithPath: socket, isDirectory: true)).appendingPathComponent("server.sock").path
}

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
    case .toolOutput:
      break
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
          + (status.isThisMachine ? "\tthis machine" : "\t\(status.appVersion ?? "-")\t\(status.address ?? "-"):\(status.port.map(String.init) ?? "-")"))
    }
  case "devices":
    for device in try await client.call(FindDevices()) {
      out("\(device.name)\t\(device.address)\t\(device.platform?.rawValue ?? "-")")
    }
  case "device-install":
    _ = try await client.call(InstallServer(host: argument(0, "HOST"), user: arguments.count > 1 ? arguments[1] : nil))
    out("installed")
  case "device-update":
    _ = try await client.call(UpdateServer(machineID: argument(0, "MACHINE")))
    out("updated")
  case "server":
    let action = ServerAction(rawValue: argument(1, "ACTION")) ?? .restart
    _ = try await client.call(ControlServer(machineID: argument(0, "MACHINE"), action: action, confirmed: true))
    out(action.rawValue)
  case "server-log":
    out(try await client.call(ServerLog(machineID: argument(0, "MACHINE"))), terminator: "")
  case "remove":
    _ = try await client.call(RemoveMachine(machineID: argument(0, "MACHINE")))
    out("removed")
  case "rename":
    let machine = try await client.call(RenameMachine(name: argument(0, "NAME"), machineID: arguments.count > 1 ? arguments[1] : nil))
    out("\(machine.id)\t\(machine.name)")
  case "sessions":
    for session in try await client.call(ListSessions(includeArchived: true)) {
      out("\(session.id)\t\(session.runtime.rawValue)\t\(session.title)\t\(session.directory)\t\(session.model ?? "-")")
    }
  case "folders":
    for folder in try await client.call(ListFolders()) { out("\(folder.id)\t\(folder.name)\t\(folder.machineID)\t\(folder.path)") }
  case "folder-create":
    let folder = try await client.call(CreateFolder(name: argument(0, "NAME")))
    out("\(folder.id)\t\(folder.path)")
  case "settings":
    for setting in try await client.call(ListSettings()) { out("\(setting.key)\t\(json(setting.value))") }
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
    for item in items {
      out("#\(item.sequence) \(item.id.prefix(8)) " + (item.author.map { "[\($0.name)] " } ?? "") + describe(item.content))
    }
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
  case "goal":
    let session = try await client.call(SetGoal(sessionID: argument(0, "SESSION"), goal: arguments.count > 1 ? arguments[1] : nil))
    out("goal \(session.goal ?? "(none)")")
  case "schedules":
    for entry in try await client.call(ListSchedules()) {
      let draft = entry.draft, state = entry.state
      out([entry.id, entry.kind.rawValue, draft.title, draft.startsAt.formatted(.iso8601),
           draft.recurrence.map { "every \($0.interval) \($0.unit.rawValue)" } ?? "once", draft.sessionID ?? "-",
           "next " + (state?.nextFireAt?.formatted(.iso8601) ?? "-"), "fired " + (state?.lastFiredAt?.formatted(.iso8601) ?? "-"),
           "run " + (state?.lastSessionID ?? "-"), state?.lastError ?? ""].joined(separator: "\t"))
    }
  case "task":
    let delay = TimeInterval(options("--in").first ?? "5") ?? 5
    let every = options("--every").first.flatMap(Recurrence.Unit.init(rawValue:))
    let model = options("--model").first, folder = options("--folder").first
    guard let machineID = await client.remote?.machine.id else { fail("no server hello") }
    let entry = try await client.call(SaveSchedule(draft: ScheduleDraft(
      machineID: machineID, kind: .task, title: argument(1, "TITLE"), prompt: argument(2, "PROMPT"),
      runtime: RuntimeKind(rawValue: argument(0, "RUNTIME")), folderID: folder, model: model,
      startsAt: Date().addingTimeInterval(delay), recurrence: every.map { Recurrence(unit: $0) })))
    out("task \(entry.id) at \(entry.draft.startsAt.formatted(.iso8601))")
  case "schedule-delete":
    _ = try await client.call(DeleteSchedule(id: argument(0, "ID")))
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
  case "artifacts":
    for artifact in try await client.call(ListArtifacts(includeTrashed: true)) {
      out("\(artifact.id)\t\(artifact.kind.rawValue)\t\(artifact.title)\t\(artifact.stamp)" + (artifact.trashed ? "\ttrashed" : ""))
    }
  case "artifact":
    out(try await client.call(ReadArtifact(artifactID: argument(0, "ID"))).body)
  case "artifact-create":
    let kind = NoteArtifactKind(rawValue: argument(0, "KIND")) ?? .note
    let body = arguments.count > 2 ? try String(contentsOfFile: arguments[2], encoding: .utf8) : nil
    out(try await client.call(CreateArtifact(kind: kind, title: argument(1, "TITLE"), body: body)).artifact.id)
  case "artifact-write":
    let id = argument(0, "ID")
    let body = try String(contentsOfFile: argument(1, "FILE"), encoding: .utf8)
    let basedOn = options("--based-on").first ?? "an earlier version"
    let written = try await client.call(WriteArtifact(artifactID: id, basedOn: basedOn, body: body))
    out("\(written.document.artifact.stamp)" + (written.replacedUnseen ? "\treplaced a version unseen" : ""))
  case "versions":
    for version in try await client.call(ListArtifactVersions(artifactID: argument(0, "ID"))) {
      out("\(version.id)\t\(version.reason.rawValue)\t\(version.title)\t\(version.savedAt)")
    }
  case "trash", "restore":
    _ = try await client.call(UpdateArtifact(artifactID: argument(0, "ID"), trashed: command == "trash"))
    out("done")
  case "app-state":
    let id = argument(0, "ID"), key = argument(1, "KEY")
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(argument(2, "JSON").utf8))
    let current = NoteDocument.decode(try await client.call(ReadArtifact(artifactID: id)).body).artifactState?[key]?.version
    let result = try await client.call(EditAppState(artifactID: id, edits: [ArtifactStateEdit(action: .set, key: key, value: value,
                                                                                               expectedVersion: current)]))
    out("version \(result.version)")
  case "databases":
    for database in try await client.call(ListDatabases()) {
      out("\(database.id)\t\(database.name)\t\(database.machineID)\t\(database.copyDigest ?? "-")")
    }
  case "db-create":
    out(try await client.call(CreateDatabase(name: argument(0, "NAME"))).id)
  case "db-execute":
    out("\(try await client.call(ExecuteDatabase(databaseID: argument(0, "ID"), sql: argument(1, "SQL"))).changes) changed")
  case "db-query":
    out(try await client.call(QueryDatabase(databaseID: argument(0, "ID"), sql: argument(1, "SQL"))).json)
  case "bots":
    let saved = try await client.call(ListSavedBots())
    for bot in saved.bots {
      out("bot \(bot.id)\t\(bot.name)\t\(bot.isAdmin ? "admin" : "bot")\thome \(bot.homeMachineID)" + (bot.trashed ? "\ttrashed" : ""))
    }
    for chat in saved.chats {
      out("chat \(chat.session.id)\t\(chat.kind.rawValue)\t\(chat.session.title)\tconversation \(chat.conversationID)"
          + (chat.parentConversationID.map { "\tparent \($0)" } ?? "") + (chat.session.pinned ? "\tpinned" : ""))
    }
  case "setting":
    let value = try Wire.decoder.decode(JSONValue.self, from: Data(argument(1, "JSON").utf8))
    out(json(try await client.call(SetSetting(key: argument(0, "KEY"), value: value))))
  case "bots-call":
    let request = try Wire.decoder.decode(JSONValue.self, from: Data(argument(0, "JSON").utf8))
    out(json(try await client.call(BotsCall(request: request))))
  case "bots-home":
    _ = try await client.call(ChooseBotsHome(machineID: argument(0, "MACHINE")))
    out("chosen")
  case "bots-transfer":
    _ = try await client.call(TransferBots(targetMachineID: argument(0, "MACHINE")))
    out("transferred")
  case "bots-follow":
    let open = try arguments.first.map { try Wire.decoder.decode(JSONValue.self, from: Data($0.utf8)) }
    let subscription = try await client.subscribe(SubscribeBots(open: open))
    out(json(subscription.reply))
    for try await event in subscription.events {
      switch event {
      case .status(let status): out("status " + json(status))
      case .message(let message): out(String(decoding: try Wire.encoder.encode(message), as: UTF8.self))
      }
    }
    out("(ended)")
  default:
    fail(usage)
  }
} catch let error as ProtocolError {
  fail("\(error.code.rawValue): \(error.message)")
} catch {
  fail("\(error)")
}
await client.close()
