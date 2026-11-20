import Foundation
import Synchronization
import WovenProtocol

/// The server's command line, shared by `woven-server` on Linux and the Mac
/// app's own program run with `--server`:
///
///     DATA-FOLDER [--socket PATH|none] [--listen HOST:PORT|auto|none] [--port PORT] [--tailnet none]
///                 [--name NAME] [--app-version VERSION] [--folders PATH] [--stand-in-runtime] [--instance NAME]
///                 [--peer-port PORT]...
///
/// Opens the library in DATA-FOLDER, listens on a Unix socket for the UI on
/// this machine (default `server.sock` in the data folder's `SocketFolder`) and on this machine's
/// Tailscale address for other machines (default port 47337, or `--port`). `--listen auto`
/// listens there only when Tailscale is connected. `--tailnet none` keeps the
/// server to itself: it neither listens for nor looks for other machines.
/// New blank folders are made in `--folders` (default ~/Woven Matter).
/// `--instance` names a development instance; servers it installs on other
/// machines are that instance too (`woven-server-NAME`). `--peer-port`, for
/// development, also looks for a server on this machine's own tailnet address
/// at that port, so two instances on one Mac find each other.
/// Runs until SIGINT or SIGTERM, then stops cleanly, or until another machine
/// removes this one; `run` then returns `removedStatus`, the exit status that
/// says so.
public enum ServerCommand {
  public struct UsageError: Error, CustomStringConvertible {
    public let description: String
  }

  /// The exit status after another machine removed this one.
  public static let removedStatus: Int32 = 3

  /// Runs the server; returns the exit status.
  @discardableResult
  public static func run(_ arguments: [String]) async throws -> Int32 {
    var arguments = arguments
    guard let folder = arguments.first, !folder.hasPrefix("--") else {
      throw UsageError(description: "usage: DATA-FOLDER [--socket PATH|none] [--listen HOST:PORT|auto|none] [--port PORT] "
                       + "[--tailnet none] [--name NAME] [--app-version VERSION] [--folders PATH] [--stand-in-runtime] [--instance NAME]")
    }
    arguments.removeFirst()

    var socketPath: String? = try SocketFolder.path("server.sock", for: URL(fileURLWithPath: folder, isDirectory: true))
    var listen: String?
    var alone = false
    var name: String?
    var appVersion = ProcessInfo.processInfo.environment["WOVEN_APP_VERSION"] ?? "dev"
    var foldersRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Woven Matter", isDirectory: true)
    var standIn = false
    var port = wovenPort
    var instance: String?
    var peerPorts: [Int] = []
    while let option = arguments.first {
      arguments.removeFirst()
      func value() throws -> String {
        guard let value = arguments.first else { throw UsageError(description: "\(option) needs a value") }
        arguments.removeFirst()
        return value
      }
      switch option {
      case "--socket":
        let path = try value()
        if path != "none" { try SocketFolder.check(path) }
        socketPath = path == "none" ? nil : path
      case "--listen": listen = try value()
      case "--port":
        guard let number = Int(try value()), (0...65535).contains(number) else { throw UsageError(description: "--port takes a number") }
        port = number
      case "--tailnet":
        guard try value() == "none" else { throw UsageError(description: "--tailnet takes none") }
        alone = true
      case "--name": name = try value()
      case "--app-version": appVersion = try value()
      case "--folders": foldersRoot = URL(fileURLWithPath: try value(), isDirectory: true)
      case "--stand-in-runtime": standIn = true
      case "--instance": instance = try value()
      case "--peer-port":
        guard let number = Int(try value()), (1...65535).contains(number) else { throw UsageError(description: "--peer-port takes a number") }
        peerPorts.append(number)
      default: throw UsageError(description: "unknown option \(option)")
      }
    }

    var tailnet: any Tailnet = alone ? NoTailnet() : TailscaleTailnet(port: port)
    let this = alone ? nil : try? await tailnet.thisMachine()
    if let this, !peerPorts.isEmpty { tailnet = AlsoOnThisMachine(base: tailnet, this: this, ports: peerPorts) }
    var address: (host: String, port: Int)?
    switch alone ? "none" : listen {
    case "none":
      address = nil
    case "auto":
      address = this.map { ($0.host, port) }
    case let text?:
      guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else {
        throw UsageError(description: "--listen takes HOST:PORT, auto or none")
      }
      address = (String(text[..<colon]), port)
    case nil:
      guard let this else {
        throw UsageError(description: "Tailscale is not connected; pass --listen HOST:PORT, auto or none")
      }
      address = (this.host, port)
    }

    var options = WovenServer.Options(
      dataFolder: URL(fileURLWithPath: folder, isDirectory: true), socketPath: socketPath, listen: address,
      appVersion: appVersion, machineName: name ?? this?.name ?? localHostName(), tailnet: tailnet,
      runtimes: standardRuntimes(dataFolder: URL(fileURLWithPath: folder, isDirectory: true)) + (standIn ? [StandInRuntime()] : []),
      foldersRoot: foldersRoot)
    options.instance = instance
    // A development instance on Linux runs its bots in its own engine, `woven-bots-engine-NAME`.
    if let instance, ProcessInfo.processInfo.environment["WOVEN_BOTS_ENGINE_INSTANCE"] == nil {
      setenv("WOVEN_BOTS_ENGINE_INSTANCE", instance, 1)
    }
    options.offersStandIn = standIn
    let server = try await WovenServer.start(options)
    FileHandle.standardOutput.write(Data(("woven-server: machine \(server.machineID) on \(socketPath ?? "no socket")"
          + (address.map { ", \($0.host):\(server.port ?? $0.port)" } ?? "") + "\n").utf8))

    // Whichever comes first. Not a task group: that would wait for the other,
    // and neither ends when cancelled.
    let removed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let once = Mutex<CheckedContinuation<Bool, Never>?>(continuation)
      Task { await signalled([SIGINT, SIGTERM]); once.withLock { $0.take() }?.resume(returning: false) }
      Task { await server.waitUntilRemoved(); once.withLock { $0.take() }?.resume(returning: true) }
    }
    await server.stop()
    if removed {
      FileHandle.standardError.write(Data("woven-server: another machine removed this one; the next start begins afresh.\n".utf8))
      return removedStatus
    }
    return 0
  }

  /// Waits for the first of these signals, which no longer end the process.
  private static func signalled(_ numbers: [Int32]) async {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let sources = numbers.map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { continuation.finish() }
      source.resume()
      return source
    }
    for await _ in stream {}
    withExtendedLifetime(sources) {}
  }
}

/// This computer's host name without a domain. Never waits on the network,
/// as `ProcessInfo.hostName` can under launchd.
private func localHostName() -> String {
  var buffer = [CChar](repeating: 0, count: 256)
  guard gethostname(&buffer, buffer.count) == 0 else { return "Woven machine" }
  let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  return name.split(separator: ".").first.map(String.init) ?? name
}

/// No tailnet: nobody may connect from the network and there is nobody to find.
private struct NoTailnet: Tailnet {
  struct Alone: Error {}
  func caller(at address: String) async -> String? { nil }
  func machines() async throws -> [TailnetMachine] { [] }
  func thisMachine() async throws -> TailnetMachine { throw Alone() }
}

/// The tailnet, plus servers of other development instances on this machine's
/// own address (`--peer-port`).
private struct AlsoOnThisMachine: Tailnet {
  let base: any Tailnet
  let this: TailnetMachine
  let ports: [Int]

  func caller(at address: String) async -> String? { await base.caller(at: address) }
  func thisMachine() async throws -> TailnetMachine { try await base.thisMachine() }
  func devices() async throws -> [TailnetDevice] { try await base.devices() }

  func machines() async throws -> [TailnetMachine] {
    let others = (try? await base.machines()) ?? []
    return others + ports.map { TailnetMachine(name: "\(this.name)-\($0)", host: this.host, port: $0) }
  }
}
