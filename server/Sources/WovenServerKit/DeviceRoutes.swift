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

  router.on(InstallServer.self) { request, _ in
    guard let install else { throw ProtocolError(.failed, "This machine cannot install the Woven server elsewhere.") }
    do {
      try await install.install(host: request.host, user: request.user)
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
    let device = try await tailnet.devices().first { $0.name == request.host || $0.address == request.host }
    guard await peers.waitForServer(at: device?.address ?? request.host, timeout: .seconds(120)) else {
      throw ProtocolError(.failed, "The server was installed on \(request.host) but has not answered yet.")
    }
    return Done()
  }

  router.on(UpdateServer.self) { request, _ in
    guard let install else { throw ProtocolError(.failed, "This machine cannot update the Woven server elsewhere.") }
    guard let machine = try await library.machine(request.machineID), machine.platform == .linux else {
      throw ProtocolError(.notFound, "No Linux machine \(request.machineID).")
    }
    guard let address = await peers.address(of: machine.id) else {
      throw ProtocolError(.ownerUnreachable, "\(machine.name) has not been reached on the tailnet.", machineID: machine.id)
    }
    do {
      try await install.install(host: address.name, user: nil)
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
    return Done()
  }

  router.on(RemoveMachine.self) { request, _ in
    guard let machine = try await library.machine(request.machineID) else { return Done() }
    // A Linux machine's server is stopped and uninstalled there first; a Mac's
    // server learns of its removal by sync and stops itself.
    if machine.platform == .linux, let install, let address = await peers.address(of: machine.id) {
      do {
        try await install.uninstall(host: address.name, user: nil)
      } catch let failure as LinuxInstall.Failure {
        throw ProtocolError(.failed, failure.description)
      }
    }
    try await library.removeMachine(machine.id)
    return Done()
  }
}
