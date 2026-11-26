import Foundation
import Testing
@testable import WovenServerKit

/// SSH reaches an installed Linux machine with exactly the host and user given
/// at install, overriding none of the person's SSH settings, and every command
/// there first checks that the server there is that machine: a host that now
/// names another machine, or one without the server, is refused unchanged.
@Test
func sshUsesTheInstalledRouteAndRefusesAnotherMachine() async throws {
  let install = LinuxInstall(bundle: URL(fileURLWithPath: "/"), instance: "check", port: 0, appVersion: "0", standIn: false)
  let target = LinuxInstall.Target(host: "linux-machine.example.ts.net", user: "person", machineID: "machine-a")
  let arguments = try install.sshArguments(target, script: "echo changed")
  #expect(Array(arguments.suffix(2).prefix(1)) == ["linux-machine.example.ts.net"])
  #expect(arguments.contains("person"))
  #expect(!arguments.contains { $0.hasPrefix("HostName") })

  // Runs the remote command here, with HOME standing in for the other machine.
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("woven-ssh-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: home) }
  let data = home.appendingPathComponent(".local/share/woven-server-check/data")
  try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
  func run(_ machineID: String?) async throws -> (status: Int32, output: String, errors: String) {
    if let machineID { try Data((machineID + "\n").utf8).write(to: data.appendingPathComponent("machine-id")) }
    let command = try #require(arguments.last)
    return await ChildProcess.run("/bin/sh", ["-c", command], environment: ["HOME": home.path], mergeErrors: false)
  }
  #expect(try await run("machine-a").output == "changed\n")
  #expect(try await run("machine-b").status == 97)
  try FileManager.default.removeItem(at: data.appendingPathComponent("machine-id"))
  #expect(try await run(nil).status == 97)

  // The install script's stage lines come before the machine id it ends with.
  let output = "\(LinuxInstall.marker)node\n\(LinuxInstall.marker)starting\nmachine-a\n"
  #expect(output.split(separator: "\n").compactMap { LinuxInstall.stage(marked: String($0)) } == [.node, .starting])
  #expect(LinuxInstall.machineID(output) == "machine-a")
}

/// A server a Mac installed keeps how that Mac reached it on its own row from
/// its first start, so the row never reaches another machine without it.
@Test(.timeLimit(.minutes(1)))
func anInstalledServerKeepsItsSSHRouteOnItsOwnRow() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
  var options = WovenServer.Options(
    dataFolder: folder, socketPath: nil, listen: nil, appVersion: "test", machineName: "Box",
    tailnet: StandInTailnet(), runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  options.sshRoute = ("box.example.ts.net", "person")
  let server = try await WovenServer.start(options)
  defer { server.stopLater() }
  let route = try #require(try await server.library.sshRoute(of: server.machineID))
  #expect(route.host == "box.example.ts.net" && route.user == "person")
}

#if os(macOS)
/// What an install sends (only a Mac installs Linux machines): the server for that architecture and this Mac's
/// resources without its Node, npm, tests or any Claude engine package, while
/// the packages' own lib and .bin folders stay.
@Test
func installSendsTheServerWithThisMacsResources() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-payload-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let bundle = folder.appendingPathComponent("linux-server"), resources = folder.appendingPathComponent("Resources")
  let files = ["woven-server", "default-agent/bin/node", "default-agent/lib/npm/bin/npm-cli.js", "default-agent/test/a.mjs",
               "default-agent/src/main.mjs", "default-agent/node_modules/a/lib/index.js", "default-agent/node_modules/.bin/a",
               "default-agent/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs",
               "default-agent/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude",
               "bots/src/cli.ts", "bots/test/a.ts", "harnesses/catalog.json"]
  for file in files {
    let url = (file == "woven-server" ? folder : resources).appendingPathComponent(file)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(file.utf8).write(to: url)
  }
  let server = bundle.appendingPathComponent("linux-x86_64")
  try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
  #expect(await ChildProcess.run("/usr/bin/tar", ["-cJf", server.appendingPathComponent("woven-server.tar.xz").path,
                                                  "-C", folder.path, "woven-server"]).status == 0)

  let install = LinuxInstall(bundle: bundle, instance: nil, port: 0, appVersion: "0", standIn: false, resources: resources)
  let staging = folder.appendingPathComponent("staging")
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  let upload = try await install.payload(arch: "x86_64", in: staging)
  let listed = await ChildProcess.run("/usr/bin/tar", ["-tzf", upload.path], mergeErrors: false)
  let sent = Set(listed.output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") })
  #expect(sent == ["woven-server", "default-agent/src/main.mjs", "default-agent/node_modules/a/lib/index.js",
                   "default-agent/node_modules/.bin/a", "default-agent/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs",
                   "bots/src/cli.ts", "harnesses/catalog.json"])
}
#endif
