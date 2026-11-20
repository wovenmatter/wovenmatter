import Foundation

/// The server's command line, shared by `woven-server` on Linux and the Mac
/// app's own program run with `--server`:
///
///     DATA-FOLDER [--socket PATH|none] [--listen HOST:PORT|auto|none] [--port PORT] [--tailnet none]
///                 [--name NAME] [--app-version VERSION] [--folders PATH] [--stand-in-runtime]
///
/// Opens the library in DATA-FOLDER, listens on a Unix socket for the UI on
/// this machine (default DATA-FOLDER/server.sock) and on this machine's
/// Tailscale address for other machines (default port 47337, or `--port`). `--listen auto`
/// listens there only when Tailscale is connected. `--tailnet none` keeps the
/// server to itself: it neither listens for nor looks for other machines.
/// New blank folders are made in `--folders` (default ~/Woven Matter).
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
                       + "[--tailnet none] [--name NAME] [--app-version VERSION] [--folders PATH] [--stand-in-runtime]")
    }
    arguments.removeFirst()

    var socketPath: String? = URL(fileURLWithPath: folder).appendingPathComponent("server.sock").path
    var listen: String?
    var alone = false
    var name: String?
    var appVersion = ProcessInfo.processInfo.environment["WOVEN_APP_VERSION"] ?? "dev"
    var foldersRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Woven Matter", isDirectory: true)
    var standIn = false
    var port = wovenPort
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
      default: throw UsageError(description: "unknown option \(option)")
      }
    }

    let tailnet: any Tailnet = alone ? NoTailnet() : TailscaleTailnet()
    let this = alone ? nil : try? await tailnet.thisMachine()
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

    let server = try await WovenServer.start(WovenServer.Options(
      dataFolder: URL(fileURLWithPath: folder, isDirectory: true), socketPath: socketPath, listen: address,
      appVersion: appVersion, machineName: name ?? this?.name ?? localHostName(), tailnet: tailnet,
      runtimes: standardRuntimes(dataFolder: URL(fileURLWithPath: folder, isDirectory: true)) + (standIn ? [StandInRuntime()] : []),
      foldersRoot: foldersRoot))
    print("woven-server: machine \(server.machineID) on \(socketPath ?? "no socket")"
          + (address.map { ", \($0.host):\(server.port ?? $0.port)" } ?? ""))
    fflush(stdout)

    let removed = await withTaskGroup(of: Bool.self) { group in
      group.addTask { await signalled([SIGINT, SIGTERM]); return false }
      group.addTask { await server.waitUntilRemoved(); return true }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
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
