import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

// Transfer: the home machine's server moves the bots to another machine's
// server, over their server-to-server connection.
//
// On the old home, in order:
//  1. The runtime is stopped (running turns are interrupted; Pi Durable picks
//     its work up again wherever the bots start next). The engine stays up.
//  2. Each bot's files are written out of the engine as archives into
//     `D/bots-transfer/files`, and the target is told every file (the bots
//     folder and the archives) with its size and digest, and what its library
//     must hold: the bots, chats and checkpoints of this library.
//  3. The files are sent in pieces, written to disk on the target.
//  4. The target checks every digest, puts the bots folder in place, reads the
//     archives into its engine, starts the runtime, and replies once its
//     library holds every bot and chat under sessions it owns.
//  5. The switch: the target sets `bots.home` to itself.
//  6. The old home removes its copy: every container and volume of the bots in
//     its engine, the bots folder, and the bot chats and Forum rooms it owned.
//
// Until the switch the target stops what it started and removes what it
// received when told to, when the old home has been out of reach for a
// minute, or when it restarts. Before the switch the old home starts its bots
// again only once the target has answered that it stopped them (or after two
// minutes out of reach). Each side keeps a marker file of its step, so a
// server restart ends the transfer in one of two states: the bots on the old
// home, or on the new one.

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
  var id: String
  var source: String
  var files: [BotsTransferFile]
  var expected: BotsTransferExpected
  /// The bots folder is in place and its files may be in the engine.
  var installed = false
  /// The runtime runs and the library holds every bot and chat.
  var confirmedAt: ContinuousClock.Instant?
  var lastHeard = ContinuousClock.now
}

/// A side's step, kept in a file so a restart knows how a transfer ended.
private struct TransferMarker: Codable {
  enum Step: String, Codable {
    // The old home's steps.
    case sending, started, committing, removing
    // The target's.
    case receiving, installed
  }

  var id: String
  /// The other machine.
  var machineID: String
  var step: Step
}

extension BotsHost {
  // MARK: Files

  private var outgoingFolder: URL { dataFolder.appendingPathComponent("bots-transfer", isDirectory: true) }
  private var incomingFolder: URL { dataFolder.appendingPathComponent("bots-incoming", isDirectory: true) }
  private var outgoingMarker: URL { runtimeFolder.appendingPathComponent("transfer-out.json") }
  private var incomingMarker: URL { runtimeFolder.appendingPathComponent("transfer-in.json") }
  /// The last transfer this machine committed to as the target.
  private var committedFile: URL { runtimeFolder.appendingPathComponent("transfer-committed") }

  private func writeMarker(_ marker: TransferMarker, to url: URL) throws {
    try FileManager.default.createDirectory(at: runtimeFolder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(marker).write(to: url, options: .atomic)
  }

  private func readMarker(_ url: URL) -> TransferMarker? {
    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TransferMarker.self, from: $0) }
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func freshFolder(_ url: URL) throws {
    remove(url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  // MARK: The old home

  /// `TransferBots`: runs the transfer to `target` and returns once the bots
  /// run there. The transfer goes on if the caller goes away.
  func transfer(to target: String, caller: Caller) async throws {
    guard setting == thisMachine, home == thisMachine, hold == nil, outgoing == nil else {
      if outgoing != nil || hold != nil { throw ProtocolError(.busy, "The bots are already moving.") }
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

  private func sendBots(_ id: String, to target: String, client: Client) async throws {
    try writeMarker(TransferMarker(id: id, machineID: target, step: .sending), to: outgoingMarker)
    hold = .sending(target: target)
    progress(target, .stopping)
    await reconcileHome()
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
      _ = try await client.call(ReceiveBots(transferID: id, files: files, expected: expected))
      var sent: Int64 = 0
      for file in files {
        let url = (file.path.hasPrefix("bots/") ? botsFolder : archives)
          .appendingPathComponent(String(file.path.drop { $0 != "/" }.dropFirst()))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        repeat {
          let data = try handle.read(upToCount: Self.pieceSize) ?? Data()
          _ = try await client.call(ReceiveBotsPiece(transferID: id, path: file.path, offset: offset, data: data))
          offset += Int64(data.count)
          sent += Int64(data.count)
          progress(target, .copying, sent: sent, total: total)
          if data.isEmpty { break }
        } while offset < file.size
      }
      progress(target, .starting)
      try writeMarker(TransferMarker(id: id, machineID: target, step: .started), to: outgoingMarker)
      started = true
      _ = try await client.call(StartReceivedBots(transferID: id))
    } catch {
      await giveUp(id, target: target, started: started)
      throw error
    }
    try writeMarker(TransferMarker(id: id, machineID: target, step: .committing), to: outgoingMarker)
    let committed: Bool
    do {
      _ = try await client.call(CommitReceivedBots(transferID: id))
      committed = true
    } catch let refused as ProtocolError {
      await giveUp(id, target: target, started: true)
      throw refused
    } catch {
      committed = await outcome(id, target: target)
    }
    guard committed else {
      await giveUp(id, target: target, started: true)
      throw ProtocolError(.failed, "The connection to \(await name(of: target)) was lost. The bots run here again.")
    }
    await removeCopy(id, target: target)
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

  private func name(of machineID: String) async -> String {
    (try? await library.machine(machineID))?.name ?? machineID
  }

  /// The commit's reply was lost: asks the target until it says whether it is the home.
  private func outcome(_ id: String, target: String) async -> Bool {
    while true {
      if let client = await peers.client(for: target) {
        switch try? await client.call(ReceivedBotsState(transferID: id)) {
        case .committed?: return true
        case ReceivedBotsOutcome.none?: return false
        case .pending?:
          if (try? await client.call(CommitReceivedBots(transferID: id))) != nil { return true }
        case nil: break
        }
      }
      progress(target, .starting, message: "Waiting for \(await name(of: target)) to answer.")
      try? await Task.sleep(for: .seconds(2))
    }
  }

  /// Before the switch: the target gives back what it started, then the bots start here again.
  private func giveUp(_ id: String, target: String, started: Bool) async {
    let deadline = ContinuousClock.now + .seconds(120)
    repeat {
      if let client = await peers.client(for: target), (try? await client.call(AbortReceivedBots(transferID: id))) != nil {
        break
      }
      // A target that never started the bots cleans up by itself.
      guard started else { break }
      try? await Task.sleep(for: .seconds(2))
    } while ContinuousClock.now < deadline
    remove(outgoingFolder)
    remove(outgoingMarker)
    hold = nil
    await reconcileHome()
  }

  /// After the switch: this machine follows the new home and removes its copy.
  private func removeCopy(_ id: String, target: String) async {
    try? writeMarker(TransferMarker(id: id, machineID: target, step: .removing), to: outgoingMarker)
    hold = .moved(target: target)
    // The value the target wrote, written here too so a restart reads it at once.
    _ = try? await library.setSetting(botsHomeSetting, to: .string(target))
    await reconcileHome(keepEngine: true)
    do {
      try await prepareEngine()
      try await hosting.files.run(.remove, configURL, nil)
    } catch {
      // Left for the next start to try again.
      await releaseEngine()
      return
    }
    await releaseEngine()
    remove(botsFolder)
    remove(outgoingFolder)
    try? await library.removeBotChats()
    tenure.end()
    remove(outgoingMarker)
    hold = nil
    await reconcileHome()
  }

  // MARK: The target

  /// `ReceiveBots`: a transfer from the home machine's server begins.
  func receive(_ request: ReceiveBots, caller: Caller) async throws {
    let source = caller.hello.machine.id
    guard caller.hello.role == .server, source == setting else {
      throw ProtocolError(.refused, "Only the bots' home machine sends them.")
    }
    if let incoming {
      guard incoming.id != request.transferID else { throw ProtocolError(.badRequest, "That transfer has begun.") }
      await abortIncoming()
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
    try writeMarker(TransferMarker(id: request.transferID, machineID: source, step: .receiving), to: incomingMarker)
    incoming = IncomingTransfer(id: request.transferID, source: source, files: request.files, expected: request.expected)
    startWatchdog()
  }

  /// `bots/<relative>` or `files/<name>.tar`, nothing that climbs out.
  private static func safe(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
    return parts[0] == "bots" || (parts[0] == "files" && parts.count == 2 && path.hasSuffix(".tar"))
  }

  /// `ReceiveBotsPiece`: appends to one file.
  func receivePiece(_ request: ReceiveBotsPiece) throws {
    guard var transfer = incoming, transfer.id == request.transferID, !transfer.installed else {
      throw ProtocolError(.notFound, "No such transfer.")
    }
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
    transfer.lastHeard = .now
    incoming = transfer
  }

  /// `StartReceivedBots`: checks, installs, starts, and waits until the
  /// library holds every bot and chat. On any failure it gives everything back.
  func startReceived(_ id: String) async throws {
    guard let transfer = incoming, transfer.id == id, transfer.confirmedAt == nil else {
      throw ProtocolError(.notFound, "No such transfer.")
    }
    if let incomingWork { return try await incomingWork.value }
    let work = Task { try await self.install(transfer) }
    incomingWork = work
    defer { incomingWork = nil }
    do {
      try await work.value
    } catch {
      if incoming?.id == id { await abortIncoming() }
      throw ProtocolError(error)
    }
  }

  private func install(_ transfer: IncomingTransfer) async throws {
    for file in transfer.files {
      let url = incomingFolder.appendingPathComponent(file.path)
      let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
      guard size == file.size, try Library.digest(ofFile: url) == file.digest else {
        throw ProtocolError(.failed, "\(file.path) arrived damaged.")
      }
    }
    try writeMarker(TransferMarker(id: transfer.id, machineID: transfer.source, step: .installed), to: incomingMarker)
    incoming?.installed = true
    remove(botsFolder)
    let received = incomingFolder.appendingPathComponent("bots", isDirectory: true)
    if FileManager.default.fileExists(atPath: received.path) {
      try FileManager.default.moveItem(at: received, to: botsFolder)
    } else {
      try FileManager.default.createDirectory(at: botsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try await prepareEngine()
    try await hosting.files.run(.import, configURL, incomingFolder.appendingPathComponent("files", isDirectory: true))
    // A new stint: whatever bot chats and checkpoints this library still holds
    // from an earlier one are gone, so the bots save their whole history again.
    try await library.removeBotChats()
    tenure.end()
    let sessions = thisMachine + ":" + tenure.current
    hold = .receiving(source: transfer.source)
    await reconcileHome()
    let deadline = ContinuousClock.now + .seconds(15 * 60)
    while true {
      try Task.checkCancellation()
      guard incoming?.id == transfer.id else { throw ProtocolError(.failed, "The transfer was given up.") }
      if status.state == .ready, try await library.botsTransferMissing(transfer.expected, sessions: sessions) == nil { break }
      guard ContinuousClock.now < deadline else {
        let missing = try await library.botsTransferMissing(transfer.expected, sessions: sessions) ?? "nothing"
        throw ProtocolError(.failed, status.state == .ready
          ? "\(await name(of: thisMachine)) did not receive \(missing) from the bots." : status.message ?? "The bots did not start.")
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    incoming?.confirmedAt = .now
  }

  /// `CommitReceivedBots`: this machine becomes the home.
  func commitReceived(_ id: String) async throws {
    if (try? String(contentsOf: committedFile, encoding: .utf8)) == id { return }
    guard let transfer = incoming, transfer.id == id, transfer.confirmedAt != nil else {
      throw ProtocolError(.notFound, "No such transfer.")
    }
    _ = try await library.setSetting(botsHomeSetting, to: .string(thisMachine))
    try? id.write(to: committedFile, atomically: true, encoding: .utf8)
    finishIncoming()
    hold = nil
    await reconcileHome()
  }

  /// `AbortReceivedBots`.
  func abortReceived(_ id: String) async {
    if incoming?.id == id { await abortIncoming() }
  }

  /// `ReceivedBotsState`.
  func receivedState(_ id: String) -> ReceivedBotsOutcome {
    if (try? String(contentsOf: committedFile, encoding: .utf8)) == id { return .committed }
    return incoming?.id == id ? .pending : .none
  }

  private func finishIncoming() {
    watchdog?.cancel()
    watchdog = nil
    incoming = nil
    remove(incomingFolder)
    remove(incomingMarker)
  }

  /// Stops what the transfer started here and removes what it received.
  func abortIncoming() async {
    guard let transfer = incoming else { return }
    incomingWork?.cancel()
    watchdog?.cancel()
    watchdog = nil
    incoming = nil
    hold = nil
    await reconcileHome(keepEngine: true)
    if transfer.installed { await removeReceived() } else { await releaseEngine() }
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

  /// Gives a transfer back when the old home has been out of reach for a
  /// minute, has sent nothing for ten, or has not committed five minutes
  /// after the bots started here.
  private func startWatchdog() {
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      var unreachableSince: ContinuousClock.Instant?
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard let self, let transfer = await self.incoming else { return }
        let now = ContinuousClock.now
        if await self.peers.client(for: transfer.source) == nil {
          unreachableSince = unreachableSince ?? now
        } else {
          unreachableSince = nil
        }
        let lost = unreachableSince.map { now - $0 > .seconds(60) } ?? false
        let quiet = !transfer.installed && now - transfer.lastHeard > .seconds(600)
        let late = transfer.confirmedAt.map { now - $0 > .seconds(300) } ?? false
        if lost || quiet || late {
          await self.abortIncoming()
          return
        }
      }
    }
  }

  // MARK: After a restart

  /// A transfer the last run of this server left: each side ends it in one
  /// of the two states, the bots on the old home or on the new one.
  func recoverTransfer() {
    if let marker = readMarker(incomingMarker) {
      Task {
        let setting = ((try? await library.setting(botsHomeSetting)) ?? nil)?.value.string
        if setting == thisMachine {
          // It made itself home just before the restart.
          try? marker.id.write(to: committedFile, atomically: true, encoding: .utf8)
          remove(incomingFolder)
          remove(incomingMarker)
        } else {
          if marker.step == .installed { await removeReceived() }
          remove(incomingFolder)
          remove(incomingMarker)
        }
      }
    }
    guard let marker = readMarker(outgoingMarker) else { return }
    let target = marker.machineID
    switch marker.step {
    case .removing:
      hold = .moved(target: target)
      Task { await removeCopy(marker.id, target: target) }
    case .committing:
      hold = .sending(target: target)
      Task {
        if await outcome(marker.id, target: target) { await removeCopy(marker.id, target: target) }
        else { await giveUp(marker.id, target: target, started: true) }
      }
    case .sending, .started, .receiving, .installed:
      hold = .sending(target: target)
      Task { await giveUp(marker.id, target: target, started: marker.step != .sending) }
    }
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
    await bots.abortReceived(request.transferID)
    return Done()
  }
  router.on(ReceivedBotsState.self) { request, _ in
    await bots.receivedState(request.transferID)
  }
}
