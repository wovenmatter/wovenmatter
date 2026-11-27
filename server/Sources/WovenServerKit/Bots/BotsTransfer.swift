import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

// Transfer: the host's server moves the bots to another machine's
// server, over their server-to-server connection. Each side is one state
// machine; each step below is taken in one place, on the `BotsHost` actor,
// and kept in a marker file so a restart ends the transfer in one of two
// states: the bots on the old host, or on the new one.
//
// The old host (`OutgoingStep`):
//  sending     The runtime is stopped (running turns are interrupted; Pi
//              Durable picks its work up again wherever the bots start next).
//              Each bot's files are written out of the engine as archives into
//              `D/bots-transfer/files`; the target is told every file (the bots
//              folder and the archives) with its size and digest, and what its
//              library must hold; the files are sent in pieces.
//  started     The target was asked to start the bots. While it works, the old
//              host asks it every `heartbeat` how it stands.
//  committing  The target was asked to become the host. Only its answer (or
//              its setting arriving by sync) decides what follows; the old host
//              waits for it however long that takes.
//  removing    The target is the host. The old host removes every container
//              and volume of the bots in its engine, the bots folder, and the
//              bot chats it owned, retrying until it has.
//
// The target (`IncomingTransfer.Phase`):
//  receiving   Files arrive in `D/bots-incoming`.
//  installing  Every digest checked, the bots folder is in place, the archives
//              are read into the engine, the runtime starts, and the library
//              is filled until it holds every bot and chat.
//  confirmed   It holds everything and waits for the commit.
//  committing  It writes `bots.host` as itself. From here nothing gives the
//              transfer back.
//
// Giving back: before `committing`, the target stops what it started and
// removes what it received when the old host says so, when it has heard
// nothing of the transfer for `targetSilence`, or when it restarts. The old
// host starts its bots again once the target has answered that it gave the
// transfer back, or, when it cannot reach the target, once `targetSilence`
// plus `stopMargin` have passed since it last asked the target anything other
// than to give back: by then the target has stopped by its own rule.

/// How a transfer writes each bot's files out of the engine and back:
/// `node bots/src/cli.ts files export|import|remove`. Tests give a stand-in.
struct BotsFiles: Sendable {
  enum Action: String, Sendable {
    /// Writes `<folder>/<botId>.tar` for each bot that has files.
    case export
    /// Reads those archives into this engine.
    case `import`
    /// Removes every container and volume of the bots from this engine.
    case remove
  }

  var run: @Sendable (_ action: Action, _ config: URL, _ folder: URL?) async throws -> Void

  static let node = BotsFiles { action, config, folder in
    guard let node = Resources.node else { throw RuntimeError.failed("The bots need Node, which is not on this machine.") }
    let entry = Resources.root.appendingPathComponent("bots/src/cli.ts").path
    var arguments = [entry, "files", action.rawValue, "--config", config.path]
    if let folder { arguments += ["--dir", folder.path] }
    let (status, errors) = try await runNode(node, arguments, in: config.deletingLastPathComponent())
    guard status == 0 else {
      let last = errors.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(status)"
      throw RuntimeError.failed("The bots' files could not be \(action == .export ? "written out" : action == .import ? "read in" : "removed"): \(last)")
    }
  }

  /// Runs Node to its end with only what it needs of the environment (the
  /// server's own may hold keys), and returns its status and standard error.
  private static func runNode(_ node: String, _ arguments: [String], in directory: URL) async throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = [
      "PATH": ChildProcess.searchPath(ProcessInfo.processInfo.environment["PATH"]),
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory(),
      "LANG": "en_US.UTF-8", "NODE_ENV": "production",
    ]
    let errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    let collected = Mutex(Data())
    errors.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      collected.withLock { $0 = ($0 + data).suffix(16384) }
    }
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
    try? await Task.sleep(for: .milliseconds(50))
    errors.fileHandleForReading.readabilityHandler = nil
    return (status, String(decoding: collected.withLock { $0 }, as: UTF8.self))
  }
}

/// A transfer this machine receives.
struct IncomingTransfer: Sendable {
  enum Phase: Sendable {
    case receiving, installing, confirmed, committing
  }

  var id: String
  var source: String
  var files: [BotsTransferFile]
  var expected: BotsTransferExpected
  var phase = Phase.receiving
  /// When the old host last asked anything of this transfer.
  var lastHeard = ContinuousClock.now
  /// The install, once the old host asked for it.
  var work: Task<Void, any Error>?
}

/// The old host's steps.
enum OutgoingStep: String, Codable {
  case sending, started, committing, removing
}

/// The target's steps, as far as a restart needs them.
private enum IncomingStep: String, Codable {
  case receiving, installed
}

/// A side's step, kept in a file so a restart knows how a transfer ended.
private struct TransferMarker<Step: Codable & Sendable>: Codable, Sendable {
  var id: String
  /// The other machine.
  var machineID: String
  var step: Step
}

extension BotsHost {
  // MARK: Time limits

  /// A target that hears nothing of its transfer for this long gives it back.
  static let targetSilence = Duration.seconds(60)
  /// What the target may take to stop the bots once it has given up.
  static let stopMargin = Duration.seconds(30)
  /// How often the old host asks the target how it stands while the bots start there.
  static let heartbeat = Duration.seconds(5)
  /// The longest the old host waits for the reply to one call.
  static let callLimit = Duration.seconds(30)
  /// How long the target has to read the bots in, start them, and hold every chat.
  static let installLimit = Duration.seconds(15 * 60)

  // MARK: Files

  private var outgoingFolder: URL { dataFolder.appendingPathComponent("bots-transfer", isDirectory: true) }
  private var incomingFolder: URL { dataFolder.appendingPathComponent("bots-incoming", isDirectory: true) }
  private var outgoingMarker: URL { runtimeFolder.appendingPathComponent("transfer-out.json") }
  private var incomingMarker: URL { runtimeFolder.appendingPathComponent("transfer-in.json") }
  /// The last transfer this machine committed to as the target.
  private var committedFile: URL { runtimeFolder.appendingPathComponent("transfer-committed") }

  private func writeMarker<Step: Codable & Sendable>(_ marker: TransferMarker<Step>, to url: URL) throws {
    try FileManager.default.createDirectory(at: runtimeFolder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(marker).write(to: url, options: .atomic)
  }

  private func readMarker<Step: Codable & Sendable>(_ url: URL, as _: Step.Type) -> TransferMarker<Step>? {
    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TransferMarker<Step>.self, from: $0) }
  }

  private func step(_ id: String, _ target: String, _ step: OutgoingStep) throws {
    try writeMarker(TransferMarker(id: id, machineID: target, step: step), to: outgoingMarker)
  }

  private func committed(_ id: String) -> Bool {
    (try? String(contentsOf: committedFile, encoding: .utf8)) == id
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func freshFolder(_ url: URL) throws {
    remove(url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  private func name(of machineID: String) async -> String {
    (try? await library.machine(machineID))?.name ?? machineID
  }

  // MARK: The old host

  /// `TransferBots`: runs the transfer to `target` and returns once the bots
  /// run there. The transfer goes on if the caller goes away.
  func transfer(to target: String, caller: Caller) async throws {
    guard setting == thisMachine, hostID == thisMachine, hold == nil, outgoing == nil, incoming == nil, ending == nil else {
      if setting == thisMachine { throw ProtocolError(.busy, "The bots are already moving.") }
      throw ProtocolError(.notOwner, "This machine does not run the bots.", machineID: setting)
    }
    guard target != thisMachine, let machine = try await library.machine(target) else {
      throw ProtocolError(.badRequest, "Choose another of your machines.")
    }
    guard let client = await peers.client(for: target) else {
      throw ProtocolError(.ownerUnreachable, "\(machine.name) is not reachable.", machineID: target)
    }
    let id = UUID().uuidString.lowercased()
    let work = Task { try await self.sendBots(id, to: target, client: client) }
    outgoing = work
    defer { outgoing = nil }
    try await work.value
  }

  private func progress(_ target: String, _ phase: BotsTransferPhase, sent: Int64? = nil, total: Int64? = nil,
                        message: String? = nil) {
    setStatus(localStatus(.transferring, message: message,
                          transfer: BotsTransferProgress(targetMachineID: target, phase: phase, bytesSent: sent, bytesTotal: total)))
  }

  /// Before asking the target anything but to give back.
  private func asking() {
    lastAsked = .now
  }

  private func sendBots(_ id: String, to target: String, client: Client) async throws {
    try step(id, target, .sending)
    hold = .sending(target: target)
    progress(target, .stopping)
    await reconcileHost()
    await handingOver.run()
    var started = false
    do {
      progress(target, .exporting)
      try freshFolder(outgoingFolder)
      let archives = outgoingFolder.appendingPathComponent("files", isDirectory: true)
      try await prepareEngine()
      try await hosting.files.run(.export, configURL, archives)
      let expected = try await library.botsTransferExpected()
      let files = try Self.listFiles(in: botsFolder, as: "bots") + Self.listFiles(in: archives, as: "files")
      let total = files.reduce(0) { $0 + $1.size }
      progress(target, .copying, sent: 0, total: total)
      asking()
      _ = try await client.call(ReceiveBots(transferID: id, files: files, expected: expected), timeout: Self.callLimit)
      var sent: Int64 = 0
      for file in files {
        let url = (file.path.hasPrefix("bots/") ? botsFolder : archives)
          .appendingPathComponent(String(file.path.drop { $0 != "/" }.dropFirst()))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        repeat {
          let data = try handle.read(upToCount: Self.pieceSize) ?? Data()
          asking()
          _ = try await client.call(ReceiveBotsPiece(transferID: id, path: file.path, offset: offset, data: data),
                                    timeout: Self.callLimit)
          offset += Int64(data.count)
          sent += Int64(data.count)
          progress(target, .copying, sent: sent, total: total)
          if data.isEmpty { break }
        } while offset < file.size
      }
      progress(target, .starting)
      try step(id, target, .started)
      started = true
      try await startThere(id, client: client)
    } catch {
      if await giveUp(id, target: target, started: started) { return }
      throw error
    }
    try step(id, target, .committing)
    let committed: Bool
    do {
      asking()
      _ = try await client.call(CommitReceivedBots(transferID: id), timeout: Self.callLimit)
      committed = true
    } catch let refused as ProtocolError {
      // It answered: it is not the host, and gives the transfer back.
      if await giveUp(id, target: target, started: true) { return }
      throw refused
    } catch {
      committed = await outcome(id, target: target)
    }
    guard committed else {
      if await giveUp(id, target: target, started: true) { return }
      throw ProtocolError(.failed, "The connection to \(await name(of: target)) was lost. The bots run here again.")
    }
    await removeCopy(id, target: target)
  }

  /// Asks the target to start the bots, and asks how it stands every
  /// `heartbeat` meanwhile so it knows this machine still waits.
  private func startThere(_ id: String, client: Client) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        await self.asking()
        _ = try await client.call(StartReceivedBots(transferID: id), timeout: Self.installLimit + Self.callLimit)
      }
      group.addTask {
        while true {
          try await Task.sleep(for: Self.heartbeat)
          await self.asking()
          _ = try? await client.call(ReceivedBotsState(transferID: id), timeout: Self.heartbeat)
        }
      }
      try await group.next()
      group.cancelAll()
    }
  }

  static let pieceSize = 4 << 20

  /// Every regular file under `folder`, as `<prefix>/<relative path>`, with its size and digest.
  static func listFiles(in folder: URL, as prefix: String) throws -> [BotsTransferFile] {
    let manager = FileManager.default
    guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
      return []
    }
    var files: [BotsTransferFile] = []
    let base = folder.resolvingSymlinksInPath().path
    for case let url as URL in walker {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { continue }
      let path = url.resolvingSymlinksInPath().path
      guard path.hasPrefix(base + "/") else { continue }
      files.append(BotsTransferFile(path: prefix + "/" + path.dropFirst(base.count + 1), size: Int64(values.fileSize ?? 0),
                                    digest: try Library.digest(ofFile: url)))
    }
    return files.sorted { $0.path < $1.path }
  }

  /// The commit's reply was lost: asks the target until it says whether it
  /// is the host, or its setting arrives here. Never guesses.
  private func outcome(_ id: String, target: String) async -> Bool {
    while true {
      if setting == target { return true }
      if let client = await peers.client(for: target) {
        asking()
        switch try? await client.call(ReceivedBotsState(transferID: id), timeout: Self.callLimit) {
        case .committed?: return true
        case ReceivedBotsOutcome.none?: return false
        case .pending?:
          asking()
          if (try? await client.call(CommitReceivedBots(transferID: id), timeout: Self.callLimit)) != nil { return true }
        case nil: break
        }
      }
      progress(target, .starting, message: "Waiting for \(await name(of: target)) to answer.")
      try? await Task.sleep(for: .seconds(2))
    }
  }

  /// Before the switch: the target gives back what it started, then the
  /// bots start here again. Returns true when the target turned out to be
  /// the host after all (this machine then removed its copy).
  private func giveUp(_ id: String, target: String, started: Bool) async -> Bool {
    // Once the target cannot have heard anything but "give back" for this
    // long, it has stopped by its own rule.
    let quiet = lastAsked + Self.targetSilence + Self.stopMargin
    while true {
      if let client = await peers.client(for: target) {
        do {
          _ = try await client.call(AbortReceivedBots(transferID: id), timeout: Self.callLimit)
          break
        } catch let refused as ProtocolError where refused.code == .busy {
          // It has begun to make itself the host: only its answer decides.
          if await outcome(id, target: target) {
            await removeCopy(id, target: target)
            return true
          }
          break
        } catch {}
      }
      // A target that never started the bots cleans up by itself.
      guard started, ContinuousClock.now < quiet else { break }
      progress(target, .starting, message: "Waiting for \(await name(of: target)) to stop the bots.")
      try? await Task.sleep(for: .seconds(2))
    }
    remove(outgoingFolder)
    remove(outgoingMarker)
    hold = nil
    await reconcileHost()
    return false
  }

  /// After the switch: this machine follows the new host and removes its copy.
  private func removeCopy(_ id: String, target: String) async {
    try? step(id, target, .removing)
    hold = .moved(target: target)
    // The value the target wrote, written here too so a restart reads it at once.
    _ = try? await library.setSetting(botsHostSetting, to: .string(target))
    setting = target
    await reconcileHost(keepEngine: true)
    progress(target, .removing)
    do {
      try await prepareEngine()
      try await hosting.files.run(.remove, configURL, nil)
    } catch {
      // Tried again in a minute, and at the next start.
      FileHandle.standardError.write(Data("woven-server: the bots' old copy was not removed yet: \(ProtocolError(error).message)\n".utf8))
      await releaseEngine()
      Task {
        try? await Task.sleep(for: .seconds(60))
        if hold == .moved(target: target) { await removeCopy(id, target: target) }
      }
      return
    }
    await releaseEngine()
    remove(botsFolder)
    remove(outgoingFolder)
    try? await library.removeBotChats()
    tenure.end()
    remove(outgoingMarker)
    hold = nil
    await reconcileHost()
  }

  // MARK: The target

  /// `ReceiveBots`: a transfer from the host's server begins.
  func receive(_ request: ReceiveBots, caller: Caller) async throws {
    let source = caller.hello.machine.id
    // The library's value: the cached one may not have caught up with sync yet.
    let stored = ((try? await library.setting(botsHostSetting)) ?? nil)?.value.string
    guard caller.hello.role == .server, source == stored, source != thisMachine else {
      throw ProtocolError(.refused, "Only the bots' host sends them.")
    }
    await ending?.value
    if let incoming {
      guard incoming.id != request.transferID else { throw ProtocolError(.badRequest, "That transfer has begun.") }
      guard await abortIncoming(incoming.id) else { throw ProtocolError(.busy, "This machine is becoming the bots' host.") }
    }
    // Nothing held here and nothing outgoing: a removal still under way would
    // remove what this transfer puts in place.
    guard incoming == nil, ending == nil, hold == nil, outgoing == nil,
          readMarker(outgoingMarker, as: OutgoingStep.self) == nil else {
      throw ProtocolError(.busy, "This machine is still removing its old copy of the bots. Try again shortly.")
    }
    for file in request.files {
      guard Self.safe(file.path) else { throw ProtocolError(.badRequest, "Not a transfer path: \(file.path)") }
    }
    try freshFolder(incomingFolder)
    for file in request.files {
      let url = incomingFolder.appendingPathComponent(file.path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
      guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw ProtocolError(.failed, "Could not write \(url.path).")
      }
    }
    try writeMarker(TransferMarker(id: request.transferID, machineID: source, step: IncomingStep.receiving), to: incomingMarker)
    incoming = IncomingTransfer(id: request.transferID, source: source, files: request.files, expected: request.expected)
    startWatchdog()
  }

  /// `bots/<relative>` or `files/<name>.tar`, nothing that climbs out.
  private static func safe(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
    return parts[0] == "bots" || (parts[0] == "files" && parts.count == 2 && path.hasSuffix(".tar"))
  }

  /// The old host asked something of transfer `id`.
  private func heard(_ id: String) {
    if incoming?.id == id { incoming?.lastHeard = .now }
  }

  /// `ReceiveBotsPiece`: appends to one file.
  func receivePiece(_ request: ReceiveBotsPiece) throws {
    guard let transfer = incoming, transfer.id == request.transferID, transfer.phase == .receiving, transfer.work == nil else {
      throw ProtocolError(.notFound, "No such transfer.")
    }
    heard(transfer.id)
    guard let file = transfer.files.first(where: { $0.path == request.path }),
          request.offset + Int64(request.data.count) <= file.size else {
      throw ProtocolError(.badRequest, "Not a file of this transfer: \(request.path)")
    }
    let handle = try FileHandle(forWritingTo: incomingFolder.appendingPathComponent(file.path))
    defer { try? handle.close() }
    guard Int64(try handle.seekToEnd()) == request.offset else {
      throw ProtocolError(.badRequest, "\(request.path) is not at \(request.offset).")
    }
    try handle.write(contentsOf: request.data)
  }

  /// `StartReceivedBots`: checks, installs, starts, and waits until the
  /// library holds every bot and chat. On any failure it gives everything back.
  func startReceived(_ id: String) async throws {
    guard let transfer = incoming, transfer.id == id else { throw ProtocolError(.notFound, "No such transfer.") }
    heard(id)
    if let work = transfer.work { return try await work.value }
    guard transfer.phase == .receiving else { return }
    let work = Task { try await self.install(transfer) }
    incoming?.work = work
    do {
      try await work.value
    } catch {
      await abortIncoming(id)
      throw ProtocolError(error)
    }
  }

  /// Fails once transfer `id` is no longer the one this machine holds: after
  /// every wait, the install goes on only while it is.
  private func stillCurrent(_ id: String) throws {
    guard incoming?.id == id else { throw ProtocolError(.failed, "The transfer was given up.") }
  }

  private func install(_ transfer: IncomingTransfer) async throws {
    let id = transfer.id
    for file in transfer.files {
      let url = incomingFolder.appendingPathComponent(file.path)
      let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
      guard size == file.size, try Library.digest(ofFile: url) == file.digest else {
        throw ProtocolError(.failed, "\(file.path) arrived damaged.")
      }
    }
    try stillCurrent(id)
    try writeMarker(TransferMarker(id: id, machineID: transfer.source, step: IncomingStep.installed), to: incomingMarker)
    incoming?.phase = .installing
    remove(botsFolder)
    let received = incomingFolder.appendingPathComponent("bots", isDirectory: true)
    if FileManager.default.fileExists(atPath: received.path) {
      try FileManager.default.moveItem(at: received, to: botsFolder)
    } else {
      try FileManager.default.createDirectory(at: botsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    // No bot has files when none was sent.
    let archives = incomingFolder.appendingPathComponent("files", isDirectory: true)
    try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try await prepareEngine()
    try stillCurrent(id)
    try await hosting.files.run(.import, configURL, archives)
    try stillCurrent(id)
    // A new stint: whatever bot chats and checkpoints this library still holds
    // from an earlier one are gone, so the bots save their whole history again,
    // under sessions that carry what the person set on the old host's.
    try await library.removeBotChats()
    try stillCurrent(id)
    tenure.end()
    let sessions = thisMachine + ":" + tenure.current
    try await library.carryBotChats(transfer.expected.chats, sessions: sessions)
    try stillCurrent(id)
    hold = .receiving(source: transfer.source)
    await reconcileHost()
    let deadline = ContinuousClock.now + Self.installLimit
    while true {
      try stillCurrent(id)
      if status.state == .ready, try await library.botsTransferMissing(transfer.expected, sessions: sessions) == nil { break }
      try stillCurrent(id)
      guard ContinuousClock.now < deadline else {
        let missing = try await library.botsTransferMissing(transfer.expected, sessions: sessions) ?? "nothing"
        throw ProtocolError(.failed, status.state == .ready
          ? "\(await name(of: thisMachine)) did not receive \(missing) from the bots." : status.message ?? "The bots did not start.")
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    try stillCurrent(id)
    incoming?.phase = .confirmed
  }

  /// `CommitReceivedBots`: this machine becomes the host. Once begun, nothing
  /// gives the transfer back.
  func commitReceived(_ id: String) async throws {
    if committed(id) { return }
    guard let transfer = incoming, transfer.id == id else { throw ProtocolError(.notFound, "No such transfer.") }
    heard(id)
    if transfer.phase == .committing {
      // A repeated commit waits for the first.
      while incoming?.id == id { try await Task.sleep(for: .milliseconds(50)) }
      guard committed(id) else { throw ProtocolError(.failed, "The bots could not be moved here.") }
      return
    }
    guard transfer.phase == .confirmed else { throw ProtocolError(.notFound, "The bots have not started here yet.") }
    incoming?.phase = .committing
    await hosting.committing()
    do {
      _ = try await library.setSetting(botsHostSetting, to: .string(thisMachine))
    } catch {
      incoming?.phase = .confirmed
      throw error
    }
    try? id.write(to: committedFile, atomically: true, encoding: .utf8)
    setting = thisMachine
    watchdog?.cancel()
    watchdog = nil
    incoming = nil
    remove(incomingFolder)
    remove(incomingMarker)
    hold = nil
    await reconcileHost()
  }

  /// `AbortReceivedBots`: replies once this machine holds nothing of the
  /// transfer; refused once it has begun to make itself the host.
  func abortReceived(_ id: String) async throws {
    guard !committed(id), await abortIncoming(id) else {
      throw ProtocolError(.busy, "\(await name(of: thisMachine)) is becoming the bots' host.")
    }
  }

  /// `ReceivedBotsState`.
  func receivedState(_ id: String) -> ReceivedBotsOutcome {
    heard(id)
    if committed(id) { return .committed }
    return incoming?.id == id || ending != nil ? .pending : .none
  }

  /// Gives transfer `id` back: from now on it is not current, so the install
  /// stops at its next step; once the install has ended, what it started is
  /// stopped and what it received removed. False when the commit has begun.
  @discardableResult
  func abortIncoming(_ id: String) async -> Bool {
    guard let transfer = incoming, transfer.id == id else {
      await ending?.value
      return true
    }
    guard transfer.phase != .committing else { return false }
    incoming = nil
    watchdog?.cancel()
    watchdog = nil
    await beginEnding { await self.giveBack(transfer) }.value
    return true
  }

  /// Starts a giving back, which `receive` and `ReceivedBotsState` wait for.
  private func beginEnding(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    endings += 1
    let mine = endings
    let task = Task {
      await body()
      self.ended(mine)
    }
    ending = task
    return task
  }

  private func ended(_ number: Int) {
    if endings == number { ending = nil }
  }

  private func giveBack(_ transfer: IncomingTransfer) async {
    _ = try? await transfer.work?.value
    if case .receiving? = hold { hold = nil }
    await reconcileHost(keepEngine: true)
    if transfer.work != nil { await removeReceived() } else { await releaseEngine() }
    remove(incomingFolder)
    remove(incomingMarker)
  }

  /// The received bots folder, anything read into this engine, and any chat
  /// the bots saved here meanwhile.
  private func removeReceived() async {
    if (try? await prepareEngine()) != nil { try? await hosting.files.run(.remove, configURL, nil) }
    await releaseEngine()
    remove(botsFolder)
    try? await library.removeBotChats()
    tenure.end()
  }

  /// Gives the transfer back once the old host has asked nothing of it for `targetSilence`.
  private func startWatchdog() {
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, let transfer = await self.incoming else { return }
        if transfer.phase != .committing, ContinuousClock.now - transfer.lastHeard > Self.targetSilence {
          await self.abortIncoming(transfer.id)
          return
        }
      }
    }
  }

  // MARK: After a restart

  /// A transfer the last run of this server left: each side ends it in one
  /// of the two states, the bots on the old host or on the new one.
  func recoverTransfer() {
    if let marker = readMarker(incomingMarker, as: IncomingStep.self) {
      let (library, me) = (library, thisMachine)
      _ = beginEnding {
        let setting = ((try? await library.setting(botsHostSetting)) ?? nil)?.value.string
        await self.recoverIncoming(marker, becameHost: setting == me)
      }
    }
    guard let marker = readMarker(outgoingMarker, as: OutgoingStep.self) else { return }
    let (id, target) = (marker.id, marker.machineID)
    switch marker.step {
    case .removing:
      hold = .moved(target: target)
      Task { await removeCopy(id, target: target) }
    case .committing:
      hold = .sending(target: target)
      Task {
        if await outcome(id, target: target) { await removeCopy(id, target: target) }
        else { _ = await giveUp(id, target: target, started: true) }
      }
    case .sending, .started:
      // Nothing was asked of the target since this server stopped.
      hold = .sending(target: target)
      lastAsked = .now
      Task { _ = await giveUp(id, target: target, started: marker.step == .started) }
    }
  }

  private func recoverIncoming(_ marker: TransferMarker<IncomingStep>, becameHost: Bool) async {
    if becameHost {
      // It made itself the host just before the restart.
      try? marker.id.write(to: committedFile, atomically: true, encoding: .utf8)
    } else if marker.step == .installed {
      await removeReceived()
    }
    remove(incomingFolder)
    remove(incomingMarker)
  }

  // MARK: Choosing the first host

  /// `BotsPresence`: what this machine knows of the bots.
  func presence() async -> BotsPresenceReply {
    let stored = ((try? await library.setting(botsHostSetting)) ?? nil)?.value.string.flatMap { $0.isEmpty ? nil : $0 }
    let saved = (try? await library.savedBots().bots.isEmpty) == false
    let moving = hold != nil || incoming != nil || outgoing != nil || ending != nil
    return BotsPresenceReply(hostMachineID: stored ?? setting, hasBots: saved || moving)
  }

  /// `ChooseBotsHost`: the first host, only while no machine knows of any bots.
  func chooseHost(_ machineID: String) async throws {
    func unknown() async throws {
      let here = await presence()
      guard here.hostMachineID == nil, !here.hasBots else {
        throw ProtocolError(.refused, "The bots already have a host. Moving them is a transfer.")
      }
    }
    try await unknown()
    let known = try await library.machine(machineID) != nil
    guard machineID == thisMachine || known else {
      throw ProtocolError(.badRequest, "Choose one of your machines.")
    }
    var askedChosen = machineID == thisMachine
    for (peerID, client) in await peers.linked() {
      guard let there = try? await client.call(BotsPresence(), timeout: .seconds(10)) else { continue }
      if peerID == machineID { askedChosen = true }
      if there.hostMachineID != nil || there.hasBots {
        throw ProtocolError(.refused, "\(await name(of: peerID)) knows of the bots already. Wait until it has synced.",
                            machineID: peerID)
      }
    }
    guard askedChosen else {
      throw ProtocolError(.ownerUnreachable, "\(await name(of: machineID)) is not reachable.", machineID: machineID)
    }
    try await unknown()
    _ = try await library.setSetting(botsHostSetting, to: .string(machineID))
  }
}

// MARK: Routes

func registerBotsTransfer(_ router: inout Router, bots: BotsHost) {
  router.on(TransferBots.self) { request, caller in
    try await bots.transfer(to: request.targetMachineID, caller: caller)
    return Done()
  }
  router.on(ReceiveBots.self) { request, caller in
    try await bots.receive(request, caller: caller)
    return Done()
  }
  router.on(ReceiveBotsPiece.self) { request, _ in
    try await bots.receivePiece(request)
    return Done()
  }
  router.on(StartReceivedBots.self) { request, _ in
    try await bots.startReceived(request.transferID)
    return Done()
  }
  router.on(CommitReceivedBots.self) { request, _ in
    try await bots.commitReceived(request.transferID)
    return Done()
  }
  router.on(AbortReceivedBots.self) { request, _ in
    try await bots.abortReceived(request.transferID)
    return Done()
  }
  router.on(ChooseBotsHost.self) { request, _ in
    try await bots.chooseHost(request.machineID)
    return Done()
  }
  router.on(BotsPresence.self) { _, _ in
    await bots.presence()
  }
  router.on(ReceivedBotsState.self) { request, _ in
    await bots.receivedState(request.transferID)
  }
}
