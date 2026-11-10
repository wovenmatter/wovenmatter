#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import WovenMatterCore
import WovenMatterDashboardStore

/// `wovenmatter-library` command line. Every path is explicit or derived from
/// `--data-root`; nothing reads a default production location.
public struct LibraryHostOptions: Equatable, Sendable {
  public var dataRoot: URL
  public var port: UInt16 = 0
  public var socket: URL?
  public var tokenFile: URL?
  public var harnessCatalog: URL?
  public var migrateOnly = false
  /// This machine's advertised name and base URLs (its own member entry).
  public var name: String?
  public var endpoints: [URL] = []
  /// Print `{"deviceID","kind","name","publicKey"}` and exit.
  public var printIdentity = false
  /// Read a `LibraryMemberAdoption` from this file (`-` for stdin), apply it, print the member list and exit.
  public var adoptMembers: String?

  public static let usage = """
    usage: wovenmatter-library --data-root DIR [--port N] [--socket PATH] [--token-file PATH]
                               [--harness-catalog PATH] [--name NAME] [--endpoint URL]... [--migrate-only]
           wovenmatter-library --data-root DIR --identity
           wovenmatter-library --data-root DIR --adopt-members FILE|-
           wovenmatter-library --version

      --data-root DIR    Library host data root (created 0700). Holds library/, secrets/ and run/.
      --port N           Loopback TCP port for /v1/health and mounted peer/mobile routes (default 0: any free port).
      --socket PATH      Unix socket for the local API (default DIR/run/library.sock).
      --token-file PATH  Local API bearer token, 0600 (default DIR/run/library-api.token; created if missing).
      --harness-catalog PATH  harnesses/catalog.json (default: the host release's copy beside this binary).
      --name NAME        This machine's member name (default: the host name).
      --endpoint URL     A base URL where peers reach this host, e.g. https://host.tailnet.ts.net/wovenmatter/ (repeatable).
      --migrate-only     Open and migrate the library database, then exit.
      --identity         Print this machine's member identity (device ID and public key), then exit.
      --adopt-members F  Apply the member records a Mac signed for this machine (JSON file, - for stdin), then exit.
    """

  public static func parse(_ arguments: [String]) throws -> LibraryHostOptions? {
    var root: URL?, port: UInt16 = 0, socket: URL?, token: URL?, catalog: URL?, migrate = false
    var name: String?, endpoints: [URL] = [], identity = false, adopt: String?
    var index = arguments.startIndex
    func value(_ flag: String) throws -> String {
      index += 1
      guard index < arguments.endIndex, !arguments[index].hasPrefix("--") else { throw LibraryHostError.usage("\(flag) requires a value.\n\n\(usage)") }
      return arguments[index]
    }
    func path(_ raw: String) -> URL {
      URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL
    }
    while index < arguments.endIndex {
      switch arguments[index] {
      case "--version": return nil
      case "--data-root": root = path(try value("--data-root"))
      case "--port":
        guard let parsed = UInt16(try value("--port")) else { throw LibraryHostError.usage("--port must be 0 to 65535.") }
        port = parsed
      case "--socket": socket = path(try value("--socket"))
      case "--token-file": token = path(try value("--token-file"))
      case "--harness-catalog": catalog = path(try value("--harness-catalog"))
      case "--migrate-only": migrate = true
      case "--identity": identity = true
      case "--adopt-members":
        index += 1
        guard index < arguments.endIndex else { throw LibraryHostError.usage("--adopt-members requires a file or -.") }
        adopt = arguments[index]
      case "--name": name = try value("--name")
      case "--endpoint":
        guard let url = URL(string: try value("--endpoint")), CompanionPairingPayload.isValidEndpoint(url) else {
          throw LibraryHostError.usage("--endpoint must be an HTTPS tailnet URL.")
        }
        endpoints.append(url)
      case "--help", "-h": throw LibraryHostError.usage(usage)
      default: throw LibraryHostError.usage("Unknown argument \(arguments[index]).\n\n\(usage)")
      }
      index += 1
    }
    guard let root else { throw LibraryHostError.usage("--data-root is required.\n\n\(usage)") }
    var options = LibraryHostOptions(dataRoot: root, port: port, socket: socket, tokenFile: token, harnessCatalog: catalog, migrateOnly: migrate)
    options.name = name; options.endpoints = endpoints; options.printIdentity = identity; options.adoptMembers = adopt
    return options
  }
}

public enum LibraryHostCommand {
  /// Runs until SIGTERM or SIGINT. Prints one JSON line when ready, which the
  /// supervising Node server reads, and writes the same object to run/library.json.
  public static func main(_ arguments: [String]) async -> Int32 {
    PortablePOSIX.ignoreBrokenPipes()
    let options: LibraryHostOptions
    do {
      guard let parsed = try LibraryHostOptions.parse(arguments) else {
        FileHandle.standardOutput.write(Data("wovenmatter-library \(LibraryHost.version)\n".utf8)); return 0
      }
      options = parsed
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); return 64
    }
    let layout = LibraryHostLayout(root: options.dataRoot)
    // Sessions are created against the shared harness catalog. A host bundle
    // ships it at <release>/harnesses; this binary is <release>/host/library/<platform>/.
    HarnessCatalog.hostCatalogURL = options.harnessCatalog ?? Bundle.main.executableURL?.resolvingSymlinksInPath()
      .deletingLastPathComponent().appending(path: "../../../harnesses/catalog.json").standardizedFileURL
    do {
      let host = try await LibraryHost(layout: layout, tokenFile: options.tokenFile, name: options.name, endpoints: options.endpoints)
      if options.migrateOnly {
        FileHandle.standardOutput.write(Data(#"{"event":"migrated"}"#.utf8 + [10])); return 0
      }
      let output = JSONEncoder(); output.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      if options.printIdentity {
        FileHandle.standardOutput.write(try output.encode(await host.identityValue()) + Data([10])); return 0
      }
      if let source = options.adoptMembers {
        let data = source == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: source))
        let list = try await host.members.adopt(JSONDecoder().decode(LibraryMemberAdoption.self, from: data))
        FileHandle.standardOutput.write(try output.encode(list) + Data([10])); return 0
      }
      let socket = options.socket ?? layout.defaultSocket
      let port = try host.listen(port: options.port, socket: socket)
      // `schema` is the paired-library schema hash: the Node server reports it as
      // `librarySchema`, so apps can tell a host whose library cannot sync with theirs.
      struct Ready: Encodable { let event = "ready"; let pid: Int32; let port: UInt16; let socket: String; let version: String; let schema: String }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let ready = try encoder.encode(Ready(pid: getpid(), port: port, socket: socket.path, version: LibraryHost.version,
                                           schema: try await host.database.pairedLibrarySchema()))
      try? FileManager.default.removeItem(at: layout.endpointFile)
      guard FileManager.default.createFile(atPath: layout.endpointFile.path, contents: ready + Data([10]), attributes: [.posixPermissions: 0o600]) else {
        throw LibraryHostError.unsafePath(layout.endpointFile.path)
      }
      FileHandle.standardOutput.write(ready + Data([10]))
      await host.startSync()
      await waitForTermination()
      host.stop()
      try? FileManager.default.removeItem(at: layout.endpointFile)
      return 0
    } catch {
      FileHandle.standardError.write(Data(("wovenmatter-library: " + error.localizedDescription + "\n").utf8))
      return 1
    }
  }

  private static func waitForTermination() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let queue = DispatchQueue(label: "com.wovenmatter.library.signals")
      let once = SignalOnce(continuation)
      for number in [SIGTERM, SIGINT] {
        _ = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler { once.fire() }
        source.resume()
        SignalOnce.retain(source)
      }
    }
  }
}

private final class SignalOnce: @unchecked Sendable {
  nonisolated(unsafe) private static var sources: [any DispatchSourceSignal] = []
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
  static func retain(_ source: any DispatchSourceSignal) { sources.append(source) }
  func fire() { lock.withLock { continuation?.resume(); continuation = nil } }
}
