import Foundation
import WovenLibrary
import WovenProtocol
import WovenServerCore

/// The device's links to the person's machines. Each machine in the address
/// book gets one connection the device opens, as a device, kept up with
/// back-off; over it the device's library and that server's stay level.
/// Every server reached tells the device where the others are. A machine on
/// another release is reached but not synced, and says which release it runs.
actor Machines: Peers {
  /// Opens a connection to a server; a test may give another.
  typealias Dial = @Sendable (_ host: String, _ port: Int) async throws -> any MessageTransport

  private let library: Library
  private let appVersion: String
  private let dial: Dial
  private let handOff: ContentHandOff
  private var book: AddressBook
  private var links: [String: Task<Void, Never>] = [:]
  private var clients: [String: Client] = [:]
  private var statuses: [String: PeerStatus] = [:]
  private var active = true
  private var watcher: Task<Void, Never>?

  init(library: Library, appVersion: String, folder: URL, dial: @escaping Dial) {
    self.library = library
    self.appVersion = appVersion
    self.dial = dial
    book = AddressBook(file: folder.appendingPathComponent("machines.json"))
    handOff = ContentHandOff(library: library, file: folder.appendingPathComponent("content-handed.json"))
  }

  /// Dials every machine in the address book, and forgets one the library
  /// says was removed.
  func start() {
    for id in book.entries.keys { link(id) }
    let changes = library.changes()
    watcher = Task { [weak self] in
      for await _ in changes { await self?.forgetRemoved() }
    }
  }

  func stop() {
    watcher?.cancel()
    unlinkAll()
  }

  /// Leaves every machine while the app is in the background, and dials
  /// them all again at once when it comes back.
  func setActive(_ value: Bool) {
    guard value != active else { return }
    active = value
    if value {
      for id in book.entries.keys { link(id) }
    } else {
      unlinkAll()
    }
  }

  /// Dials the server a connection code names. Once it answers as a Woven
  /// server on this release, every machine it knows is remembered.
  func add(_ code: ConnectionCode) async throws {
    let client: Client
    let remote: Hello
    do {
      (client, remote) = try await open(host: code.address, port: code.port)
    } catch let error as DeviceConnectionError {
      throw error
    } catch is ProtocolError {
      throw DeviceConnectionError.notWoven(address: code.address, port: code.port)
    } catch {
      throw DeviceConnectionError.unreachable(address: code.address, port: code.port)
    }
    defer { Task { await client.close() } }
    guard remote.appVersion == appVersion else {
      throw DeviceConnectionError.otherRelease(machineName: remote.machine.name, appVersion: remote.appVersion)
    }
    book.set(remote.machine.id, .init(name: remote.machine.name, host: code.address, port: code.port,
                                      appVersion: remote.appVersion))
    await learn(from: client)
    for id in book.entries.keys { link(id) }
  }

  /// Forgets every machine. The library stays as it is.
  func forgetAll() async {
    unlinkAll()
    for id in book.entries.keys { await handOff.forget(id) }
    book.removeAll()
    statuses.removeAll()
  }

  // MARK: Peers

  /// Every remembered machine, online or not, at its address, so the UI can
  /// reach it directly and keep trying while it is offline. A machine not
  /// reached since launch has the release it last said it runs; one never
  /// reached is taken to run this one, so nothing claims an update is needed
  /// before anything is known.
  func reached() -> [String: PeerStatus] {
    book.entries.reduce(into: [:]) { result, item in
      let (id, entry) = item
      result[id] = PeerStatus(online: statuses[id]?.online ?? false,
                              appVersion: statuses[id]?.appVersion ?? entry.appVersion ?? appVersion,
                              address: entry.host, port: entry.port)
    }
  }

  /// Fetches a file from whichever linked server has it, a piece at a time,
  /// checks its digest and stores it.
  func fetchContent(_ digest: String) async -> Bool {
    for client in clients.values {
      guard let file = try? library.incomingFile() else { return false }
      do {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var received: Int64 = 0
        while true {
          let chunk = try await client.call(FetchContent(digest: digest, offset: received))
          try handle.write(contentsOf: chunk.data)
          received += Int64(chunk.data.count)
          if chunk.data.isEmpty || received >= chunk.size { break }
        }
        try handle.close()
        guard try Library.digest(ofFile: file) == digest else {
          try? FileManager.default.removeItem(at: file)
          continue
        }
        try await library.storeContent(movingFile: file)
        return true
      } catch {
        try? FileManager.default.removeItem(at: file)
      }
    }
    return false
  }

  // MARK: Links

  private func link(_ id: String) {
    guard active, links[id] == nil, !library.isRemoved else { return }
    links[id] = Task { [weak self] in await self?.keep(id) }
  }

  private func unlinkAll() {
    for link in links.values { link.cancel() }
    links.removeAll()
    for client in clients.values { Task { await client.close() } }
    clients.removeAll()
    for id in statuses.keys { statuses[id]?.online = false }
  }

  /// Keeps one machine linked, reconnecting with back-off, for as long as
  /// it is in the address book.
  private func keep(_ id: String) async {
    var delay = Duration.seconds(1)
    while !Task.isCancelled, active, !library.isRemoved, let entry = book.entries[id] {
      do {
        try await follow(id, entry)
        delay = .seconds(1)
      } catch let error as ProtocolError where error.code == .versionMismatch {
        delay = .seconds(60)
      } catch {}
      try? await Task.sleep(for: delay)
      delay = min(delay * 2, .seconds(60))
    }
    if links[id] != nil, !Task.isCancelled { links[id] = nil }
  }

  /// One connection's life: hello, then sync until it closes. Content the
  /// device made goes to the server before the rows that point at it.
  private func follow(_ id: String, _ entry: AddressBook.Entry) async throws {
    let (client, remote) = try await open(host: entry.host, port: entry.port)
    defer {
      if clients[id] === client { clients[id] = nil }
      statuses[id]?.online = false
      Task { await client.close() }
    }
    // Another machine answers there now: remember it, and look for this one again.
    guard remote.machine.id == id else {
      book.set(remote.machine.id, .init(name: remote.machine.name, host: entry.host, port: entry.port,
                                        appVersion: remote.appVersion))
      link(remote.machine.id)
      throw ConnectionClosed()
    }
    statuses[id] = PeerStatus(online: false, appVersion: remote.appVersion, address: entry.host, port: entry.port)
    var reached = entry
    reached.name = remote.machine.name
    reached.appVersion = remote.appVersion
    book.set(id, reached)
    // Two machines on different app releases do not sync.
    guard remote.appVersion == appVersion else {
      throw ProtocolError(.versionMismatch, "\(remote.machine.name) runs \(remote.appVersion).", machineID: id)
    }
    clients[id] = client
    statuses[id]?.online = true
    await learn(from: client)
    let library = library, handOff = handOff
    let announced = try await client.subscribe(SubscribeLibrary())
    let changes = library.changes()
    try await library.pull(from: client, machineID: id)
    try await handOff.handOver(to: client, machineID: id)
    try await library.push(to: client)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await _ in announced.events { try await library.pull(from: client, machineID: id) }
      }
      group.addTask {
        for await _ in changes {
          try await handOff.handOver(to: client, machineID: id)
          try await library.push(to: client)
        }
      }
      // Machines that join later, or answer somewhere new, are learned as they appear.
      group.addTask { [weak self] in
        while true {
          try await Task.sleep(for: .seconds(60))
          await self?.learn(from: client)
        }
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  /// Connects and says hello as this device; fails within ten seconds when
  /// nothing answers as a Woven server.
  private func open(host: String, port: Int) async throws -> (Client, Hello) {
    guard let device = try await library.machine(library.machineID) else { throw ConnectionClosed() }
    let client = Client(transport: try await dial(host, port))
    let timer = Task {
      try await Task.sleep(for: .seconds(10))
      await client.close()
    }
    defer { timer.cancel() }
    do {
      let remote = try await client.open(Hello(role: .device, machine: device, appVersion: appVersion))
      guard remote.role == .server else { throw DeviceConnectionError.notWoven(address: host, port: port) }
      return (client, remote)
    } catch let error as DeviceConnectionError {
      await client.close()
      throw error
    } catch {
      await client.close()
      throw DeviceConnectionError.notWoven(address: host, port: port)
    }
  }

  /// Remembers where every machine a server knows answers.
  private func learn(from client: Client) async {
    guard let listed = try? await client.call(ListMachines(), timeout: .seconds(20)) else { return }
    for status in listed {
      guard let host = status.address, let port = status.port, !status.machine.platform.isDevice else { continue }
      let known = book.entries[status.machine.id]
      let entry = AddressBook.Entry(name: status.machine.name, host: host, port: port,
                                    appVersion: known?.appVersion ?? status.appVersion)
      if book.set(status.machine.id, entry) { link(status.machine.id) }
    }
  }

  /// A machine removed from the library is forgotten here too.
  private func forgetRemoved() async {
    for id in book.entries.keys {
      guard let row = try? await library.row("machines", id: id), row.deleted else { continue }
      links.removeValue(forKey: id)?.cancel()
      if let client = clients.removeValue(forKey: id) { await client.close() }
      statuses[id] = nil
      book.remove(id)
      await handOff.forget(id)
    }
  }
}

/// Why a connection code did not connect, for the person.
public enum DeviceConnectionError: Error, LocalizedError, Sendable, Hashable {
  /// Nothing answered there.
  case unreachable(address: String, port: Int)
  /// Something answered that is not a Woven Matter server.
  case notWoven(address: String, port: Int)
  /// That machine runs another release, so the two cannot sync until both run the same one.
  case otherRelease(machineName: String, appVersion: String)

  public var errorDescription: String? {
    switch self {
    case .unreachable(let address, let port):
      "Nothing answered at \(address):\(port). Check that the Mac is on and that Tailscale is connected on both."
    case .notWoven(let address, let port):
      "\(address):\(port) is not a Woven Matter server."
    case .otherRelease(let name, let version):
      "\(name) runs Woven Matter \(version). Update so both run the same release."
    }
  }
}
