import Foundation
import WovenLibrary
import WovenProtocol

/// Finding Linux computers to add, installing and updating the Linux server over SSH, and
/// Remove, which uninstalls a Linux machine's server before deleting the
/// machine from every library. `install` is nil where this server carries no
/// Linux release (on Linux, and in tests); those requests are then refused.
func registerMachineInstall(_ router: inout Router, library: Library, peers: PeerSync, tailnet: any Tailnet, install: LinuxInstall?) {
  router.on(FindComputers.self) { _, _ in
    let computers = try await tailnet.computers()
    var linked: Set<String> = []
    for machine in try await library.machines() {
      if let address = await peers.address(of: machine.id) { linked.insert(address.host) }
    }
    return computers.filter { !linked.contains($0.address) }
  }

  router.on(InspectMachine.self) { request, _ in
    guard let install else { throw ProtocolError(.failed, "This machine cannot install the Woven server elsewhere.") }
    do {
      return try await install.inspect(on: LinuxInstall.Target(host: request.host, user: request.user))
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
  }

  router.on(InstallServer.self) { request, _ in
    guard let install else { throw ProtocolError(.failed, "This machine cannot install the Woven server elsewhere.") }
    let machineID: String
    do {
      machineID = try await install.install(on: LinuxInstall.Target(host: request.host, user: request.user))
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
    // Once its machine row has arrived, the host and user go with it, so any
    // Mac reaches it the same way later.
    let deadline = ContinuousClock.now + .seconds(120)
    while true {
      let online = await peers.isOnline(machineID)
      if online, try await library.machine(machineID) != nil { break }
      guard ContinuousClock.now < deadline else {
        throw ProtocolError(.failed, "The server was installed on \(request.host) but has not answered yet.")
      }
      await peers.discover()
      try await Task.sleep(for: .seconds(2))
    }
    try await library.setSSHRoute(of: machineID, host: request.host, user: request.user)
    return Done()
  }

  router.on(UpdateServer.self) { request, _ in
    let (install, target) = try await linuxTarget(request.machineID, library: library, install: install)
    do {
      try await install.install(on: target)
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
    // Looks for it at once rather than at the next discovery.
    _ = await peers.waitForServer(of: request.machineID, timeout: .seconds(60))
    return Done()
  }

  router.on(RemoveMachine.self) { request, _ in
    guard let machine = try await library.machine(request.machineID) else { return Done() }
    // A Linux machine's server is stopped and uninstalled there first, its
    // server running or not; a Mac's server learns of its removal by sync and
    // stops itself. One that cannot be reached and is not online is removed
    // anyway: it erases its library if it comes back.
    if machine.platform == .linux, let install, let target = try await sshTarget(of: machine.id, library: library) {
      do {
        try await install.uninstall(on: target)
      } catch let failure as LinuxInstall.Failure {
        if await peers.isOnline(machine.id) { throw ProtocolError(.failed, failure.description) }
      }
    }
    try await library.removeMachine(machine.id)
    return Done()
  }
}
