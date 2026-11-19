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
  }

  private struct SelfLink: Error {}

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

  /// Looks at the tailnet now and connects to any machine not yet linked.
  func discover() async {
    guard let machines = try? await tailnet.machines() else { return }
    for machine in machines where links[machine] == nil {
      links[machine] = Task { [weak self] in await self?.link(machine) }
    }
  }

  /// Fetches a file this machine lacks from whichever linked machine has it.
  func fetchContent(_ digest: String) async -> Bool {
    for client in clients.values {
      var data = Data()
      do {
        while true {
          let chunk = try await client.call(FetchContent(digest: digest, offset: Int64(data.count)))
          data.append(chunk.data)
          if chunk.data.isEmpty || Int64(data.count) >= chunk.size { break }
        }
        guard Library.digest(of: data) == digest else { continue }
        try await library.storeContent(data)
        return true
      } catch {
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
    statuses[peerID] = Status(online: true, appVersion: remote.appVersion)
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
