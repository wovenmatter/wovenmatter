import Foundation
import WovenLibrary
import WovenProtocol

/// Server-to-server sync over the one protocol. Finds the other machines
/// through the tailnet, connects to each one that answers, pulls everything
/// past its cursor, then pulls again whenever that machine announces a change.
actor PeerSync {
  struct Status: Sendable {
    var online: Bool
    var appVersion: String
    /// The tailnet address its server answered on.
    var machine: TailnetMachine
  }

  private struct SelfLink: Error {}
  /// Another link already reaches the same machine (by its identifier).
  private struct DuplicateLink: Error {}

  private let library: Library
  private let tailnet: any Tailnet
  private let hello: Hello
  private let interval: Duration
  private var discovery: Task<Void, Never>?
  private var links: [TailnetMachine: Task<Void, Never>] = [:]
  private var clients: [String: Client] = [:]
  private(set) var statuses: [String: Status] = [:]

  init(library: Library, tailnet: any Tailnet, hello: Hello, interval: Duration) {
    self.library = library
    self.tailnet = tailnet
    self.hello = hello
    self.interval = interval
  }

  func start() {
    guard discovery == nil else { return }
    let interval = interval
    discovery = Task { [weak self] in
      while !Task.isCancelled {
        await self?.discover()
        try? await Task.sleep(for: interval)
      }
    }
  }

  func stop() {
    discovery?.cancel()
    discovery = nil
    for link in links.values { link.cancel() }
    links.removeAll()
    for client in clients.values { Task { await client.close() } }
    clients.removeAll()
  }

  /// Looks at the tailnet now, connects to any address not yet linked, and
  /// drops links to addresses the tailnet no longer lists (a renamed or
  /// readdressed machine), so no dead duplicate stays behind.
  func discover() async {
    guard let machines = try? await tailnet.machines() else { return }
    let listed = Set(machines)
    for (machine, task) in links where !listed.contains(machine) {
      task.cancel()
      links[machine] = nil
    }
    for machine in machines where links[machine] == nil {
      links[machine] = Task { [weak self] in await self?.link(machine) }
    }
  }

  /// The connection to another machine's server, while it is linked.
  func client(for machineID: String) -> Client? {
    clients[machineID]
  }

  /// Every machine linked now, with its connection.
  func linked() -> [String: Client] {
    clients
  }

  /// Where another machine's server was last reached on the tailnet.
  func address(of machineID: String) -> TailnetMachine? {
    statuses[machineID]?.machine
  }

  /// Looks at the tailnet until a server answers at `address`, for up to
  /// `timeout`; true when one did.
  func waitForServer(at address: String, timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if statuses.values.contains(where: { $0.machine.host == address && $0.online }) { return true }
      await discover()
      try? await Task.sleep(for: .seconds(2))
    }
    return false
  }

  private func unlinked(_ machine: TailnetMachine) {
    links[machine] = nil
  }

  /// Fetches a file this machine lacks from whichever linked machine has
  /// it, writing it to disk piece by piece rather than holding it in memory.
  func fetchContent(_ digest: String) async -> Bool {
    for client in clients.values {
      guard let file = try? library.incomingFile() else { return false }
      do {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        var received: Int64 = 0
        do {
          while true {
            let chunk = try await client.call(FetchContent(digest: digest, offset: received))
            try handle.write(contentsOf: chunk.data)
            received += Int64(chunk.data.count)
            if chunk.data.isEmpty || received >= chunk.size { break }
          }
          try handle.close()
        } catch {
          try? handle.close()
          throw error
        }
        guard try Library.digest(ofFile: file) == digest else {
          try? FileManager.default.removeItem(at: file)
          continue
        }
        try await library.storeContent(movingFile: file)
        return true
      } catch {
        try? FileManager.default.removeItem(at: file)
        continue
      }
    }
    return false
  }

  /// Keeps one machine linked, reconnecting with backoff.
  private func link(_ machine: TailnetMachine) async {
    var delay = Duration.seconds(1)
    while !Task.isCancelled {
      do {
        try await follow(machine)
        delay = .seconds(1)
      } catch is SelfLink {
        return
      } catch is DuplicateLink {
        // The other link serves that machine; discovery may try this address again later.
        unlinked(machine)
        return
      } catch {}
      try? await Task.sleep(for: delay)
      delay = min(delay * 2, .seconds(60))
    }
  }

  private func follow(_ machine: TailnetMachine) async throws {
    let client = Client(transport: try await connectWebSocket(.tcp(host: machine.host, port: machine.port)))
    // A machine that accepts the connection but never says hello is dropped.
    let timer = Task {
      try await Task.sleep(for: .seconds(10))
      await client.close()
    }
    let remote: Hello
    do {
      remote = try await client.open(hello)
      timer.cancel()
    } catch {
      timer.cancel()
      await client.close()
      throw error
    }
    let peerID = remote.machine.id
    guard peerID != library.machineID else {
      await client.close()
      throw SelfLink()
    }
    if clients[peerID] != nil {
      await client.close()
      throw DuplicateLink()
    }
    statuses[peerID] = Status(online: true, appVersion: remote.appVersion, machine: machine)
    defer {
      statuses[peerID]?.online = false
      if clients[peerID] === client { clients[peerID] = nil }
      Task { await client.close() }
    }
    // Two machines on different app releases do not sync.
    guard remote.appVersion == hello.appVersion else {
      throw ProtocolError(.versionMismatch, "\(remote.machine.name) runs \(remote.appVersion).", machineID: peerID)
    }
    clients[peerID] = client
    let changes = try await client.subscribe(SubscribeLibrary())
    try await pull(from: client, machineID: peerID)
    for try await _ in changes.events {
      try await pull(from: client, machineID: peerID)
    }
  }

  private func pull(from client: Client, machineID: String) async throws {
    while true {
      let cursor = try await library.cursor(for: machineID)
      let page = try await client.call(SyncPull(after: cursor))
      try await library.apply(page, from: machineID)
      if !page.more { return }
    }
  }
}
