import Foundation
import Testing
@testable import WovenServerKit

/// SSH reaches an installed Linux machine with exactly the host and user given
/// at install, overriding none of the person's SSH settings, and every command
/// there first checks that the server there is that machine: a host that now
/// names another computer, or one without the server, is refused unchanged.
@Test
func sshUsesTheInstalledRouteAndRefusesAnotherMachine() async throws {
  let install = LinuxInstall(bundle: URL(fileURLWithPath: "/"), instance: "check", port: 0, appVersion: "0", standIn: false)
  let target = LinuxInstall.Target(host: "workstation.example.ts.net", user: "person", machineID: "machine-a")
  let arguments = try install.sshArguments(target, script: "echo changed")
  #expect(Array(arguments.suffix(2).prefix(1)) == ["workstation.example.ts.net"])
  #expect(arguments.contains("person"))
  #expect(!arguments.contains { $0.hasPrefix("HostName") })

  // Runs the remote command here, with HOME standing in for the other computer.
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
}
