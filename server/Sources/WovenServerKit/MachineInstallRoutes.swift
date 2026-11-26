import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

/// Finding Linux machines to add, installing and updating the Linux server over SSH, and
/// Remove, which uninstalls a Linux machine's server before deleting the
/// machine from every library. `install` is nil where this server carries no
/// Linux release (on Linux, and in tests); those requests are then refused.
func registerMachineInstall(_ router: inout Router, library: Library, peers: PeerSync, tailnet: any Tailnet, install: LinuxInstall?) {
  router.on(FindMachines.self) { _, _ in
    let machinesToAdd = try await tailnet.machinesToAdd()
    var linked: Set<String> = []
    for machine in try await library.machines() {
      if let address = await peers.address(of: machine.id) { linked.insert(address.host) }
    }
    return machinesToAdd.filter { !linked.contains($0.address) }
  }

  router.on(InspectMachine.self) { request, _ in
    guard let install else { throw ProtocolError(.failed, "This machine cannot install the Woven server elsewhere.") }
    do {
      return try await install.inspect(on: LinuxInstall.Target(host: request.host, user: request.user))
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
  }

  // The hosts an install is running on: a second one there would unpack over the first.
  let installing = Mutex(Set<String>())
  router.subscription(InstallServer.self) { request, _ in
    guard let install else { throw ProtocolError(.failed, "This machine cannot install the Woven server elsewhere.") }
    guard installing.withLock({ $0.insert(request.host).inserted }) else {
      throw ProtocolError(.failed, "The server is already being installed on \(request.host).")
    }
    let (events, continuation) = AsyncThrowingStream<InstallEvent, any Error>.makeStream()
    // Stages only go forward, whatever order the lines arrive in.
    let reached = Mutex(-1)
    @Sendable func stage(_ stage: InstallStage) {
      let index = InstallStage.allCases.firstIndex(of: stage)!
      let forward = reached.withLock { last in
        guard index > last else { return false }
        last = index
        return true
      }
      if forward { continuation.yield(.stage(stage)) }
    }
    let host = request.host
    let target = LinuxInstall.Target(host: request.host, user: request.user)
    // Not the subscription's task: an install goes on to the end when its
    // subscriber leaves, which only stops the events.
    Task {
      defer { installing.withLock { _ = $0.remove(host) } }
      let end: InstallEvent
      do {
        let machineID = try await install.install(on: target, progress: stage)
        stage(.connecting)
        // The new server writes its SSH route onto its own row at start, so
        // the row arrives with it.
        let deadline = ContinuousClock.now + .seconds(120)
        var joined = false
        while true {
          if await peers.isOnline(machineID), try await library.sshRoute(of: machineID) != nil {
            joined = true
            break
          }
          guard ContinuousClock.now < deadline else { break }
          await peers.retryNow()
          try await Task.sleep(for: .seconds(1))
        }
        end = joined ? .finished(machineID: machineID)
          : .failed(message: "The server was installed on \(host) but has not answered yet.")
      } catch let failure as LinuxInstall.Failure {
        end = .failed(message: failure.description)
      } catch {
        end = .failed(message: "\(error)")
      }
      continuation.yield(end)
      continuation.finish()
    }
    return (Done(), events)
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
