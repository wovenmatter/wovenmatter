import Foundation
import WovenLibrary
import WovenProtocol

/// Find Devices, installing and updating the Linux server over SSH, and
/// Remove, which uninstalls a Linux machine's server before deleting the
/// machine from every library. `install` is nil where this server carries no
/// Linux release (on Linux, and in tests); those requests are then refused.
func registerDevices(_ router: inout Router, library: Library, peers: PeerSync, tailnet: any Tailnet, install: LinuxInstall?) {
  router.on(FindDevices.self) { _, _ in
    let devices = try await tailnet.devices()
    var linked: Set<String> = []
    for machine in try await library.machines() {
      if let address = await peers.address(of: machine.id) { linked.insert(address.host) }
    }
    return devices.filter { !linked.contains($0.address) }
  }

  router.on(InspectHost.self) { request, _ in
    guard let install else { throw ProtocolError(.failed, "This machine cannot install the Woven server elsewhere.") }
    do {
      return try await install.inspect(on: LinuxInstall.target(request.host, user: request.user, on: tailnet))
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
  }

  router.on(InstallServer.self) { request, _ in
    guard let install else { throw ProtocolError(.failed, "This machine cannot install the Woven server elsewhere.") }
    let target = await LinuxInstall.target(request.host, user: request.user, on: tailnet)
    do {
      try await install.install(on: target)
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
    guard await peers.waitForServer(at: target.address ?? request.host, timeout: .seconds(120)) else {
      throw ProtocolError(.failed, "The server was installed on \(request.host) but has not answered yet.")
    }
    return Done()
  }

  router.on(UpdateServer.self) { request, _ in
    let (install, target) = try await linuxTarget(request.machineID, library: library, peers: peers, tailnet: tailnet, install: install)
    do {
      try await install.install(on: target)
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
    return Done()
  }

  router.on(RemoveMachine.self) { request, _ in
    guard let machine = try await library.machine(request.machineID) else { return Done() }
    // A Linux machine's server is stopped and uninstalled there first, its
    // server running or not; a Mac's server learns of its removal by sync and
    // stops itself.
    if machine.platform == .linux, let install, let target = await sshTarget(of: machine, peers: peers, tailnet: tailnet) {
      do {
        try await install.uninstall(on: target)
      } catch let failure as LinuxInstall.Failure {
        throw ProtocolError(.failed, failure.description)
      }
    }
    try await library.removeMachine(machine.id)
    return Done()
  }
}
