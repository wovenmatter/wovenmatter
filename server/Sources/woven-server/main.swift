import Foundation
import WovenServerKit

// woven-server DATA-FOLDER [--socket PATH] [--listen HOST:PORT | --listen none]
//                          [--name NAME] [--app-version VERSION] [--stand-in-runtime]
//
// Opens the library in DATA-FOLDER, listens on a Unix socket for the UI on
// this machine (default DATA-FOLDER/server.sock) and on this machine's
// Tailscale address for other machines (default port 7337).

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("woven-server: \(message)\n".utf8))
  exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let folder = arguments.first, !folder.hasPrefix("--") else {
  fail("usage: woven-server DATA-FOLDER [--socket PATH] [--listen HOST:PORT|none] [--name NAME] [--app-version VERSION]")
}
arguments.removeFirst()

var socketPath: String? = URL(fileURLWithPath: folder).appendingPathComponent("server.sock").path
var listen: String?
var name: String?
var appVersion = ProcessInfo.processInfo.environment["WOVEN_APP_VERSION"] ?? "dev"
var standIn = false
while let option = arguments.first {
  arguments.removeFirst()
  func value() -> String {
    guard let value = arguments.first else { fail("\(option) needs a value") }
    arguments.removeFirst()
    return value
  }
  switch option {
  case "--socket": socketPath = value()
  case "--listen": listen = value()
  case "--name": name = value()
  case "--app-version": appVersion = value()
  case "--stand-in-runtime": standIn = true
  default: fail("unknown option \(option)")
  }
}

let tailnet = TailscaleTailnet()
let this = try? await tailnet.thisMachine()
var address: (host: String, port: Int)?
switch listen {
case "none":
  address = nil
case let text?:
  guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else {
    fail("--listen takes HOST:PORT")
  }
  address = (String(text[..<colon]), port)
case nil:
  guard let this else { fail("Tailscale is not connected; pass --listen HOST:PORT or --listen none") }
  address = (this.host, wovenPort)
}

let server: WovenServer
do {
  server = try await WovenServer.start(WovenServer.Options(
    dataFolder: URL(fileURLWithPath: folder, isDirectory: true), socketPath: socketPath, listen: address,
    appVersion: appVersion, machineName: name ?? this?.name ?? ProcessInfo.processInfo.hostName, tailnet: tailnet,
    runtimes: standIn ? [StandInRuntime()] : []))
} catch {
  fail("could not start: \(error)")
}
print("woven-server: machine \(server.library.machineID) on \(socketPath ?? "no socket")"
      + (address.map { ", \($0.host):\(server.port ?? $0.port)" } ?? ""))

let stopped = AsyncStream<Void>.makeStream()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sources = [SIGINT, SIGTERM].map { number in
  let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
  source.setEventHandler { stopped.continuation.finish() }
  source.resume()
  return source
}
for await _ in stopped.stream {}
await server.stop()
withExtendedLifetime(sources) {}
