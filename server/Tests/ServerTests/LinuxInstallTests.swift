import Testing
@testable import WovenServerKit

/// However a Linux computer is named (its tailnet name, its MagicDNS name or
/// its address), SSH connects to that tailnet node's address and keeps the
/// person's SSH settings for its tailnet name. By the address or MagicDNS name
/// alone their key and user do not apply and SSH is refused.
@Test
func sshReachesTheTailnetNodeWithTheSettingsForItsName() async throws {
  let tailnet = StandInTailnet()
  tailnet.setMachines([TailnetMachine(name: "workstation", host: "100.64.0.7")])
  for given in ["workstation", "workstation.example.ts.net", "100.64.0.7"] {
    let target = await LinuxInstall.target(given, user: nil, on: tailnet)
    #expect(target == LinuxInstall.Target(name: "workstation", address: "100.64.0.7", user: nil))
    let arguments = try LinuxInstall.sshArguments(target, script: "true")
    #expect(Array(arguments.suffix(3)) == ["--", "workstation", "sh -c 'true'"])
    #expect(arguments.contains("HostName=100.64.0.7"))
  }
}
