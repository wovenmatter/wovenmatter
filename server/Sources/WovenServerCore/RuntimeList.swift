import Foundation
import Synchronization
import WovenProtocol

/// The runtimes on this host, as their adapters report them, and the options
/// each last reported. A machine registers the list again with its harness
/// catalog's names and the latest releases; that one replaces this.
package func registerRuntimeList(_ router: inout Router, sessions: SessionManager,
                                 name: @escaping @Sendable (RuntimeKind) -> String = { $0.rawValue },
                                 latestRelease: (@Sendable (RuntimeKind) async -> String?)? = nil) {
  let lastStatuses = Mutex<[RuntimeKind: RuntimeStatus]>([:])

  router.on(ListRuntimes.self) { request, _ in
    let runtimes = await sessions.allRuntimes
    return await withTaskGroup(of: RuntimeStatus.self) { group in
      for runtime in runtimes {
        group.addTask {
          // One slow CLI must not hold up the list: it is reported as it last
          // answered, or as not answering when it never has.
          let late = lastStatuses.withLock { $0[runtime.kind] }
            ?? RuntimeStatus(runtime: runtime.kind, name: name(runtime.kind),
                             installed: false, detail: "It did not answer in time.")
          return await firstOf(seconds: statusLimit, or: late) {
            var status = await runtime.status()
            if request.checkForUpdates, let latestRelease { status.latestVersion = await latestRelease(runtime.kind) }
            lastStatuses.withLock { $0[runtime.kind] = status }
            return status
          }
        }
      }
      var statuses: [RuntimeStatus] = []
      for await status in group { statuses.append(status) }
      return statuses.sorted { $0.name < $1.name }
    }
  }
  router.on(GetRuntimeConfiguration.self) { request, _ in
    sessions.configurations.configuration(request.runtime)
  }
  router.on(InstallRuntime.self) { request, _ in
    guard let runtime = await sessions.runtime(request.runtime) else {
      throw ProtocolError(.badRequest, "This machine has no \(request.runtime.rawValue) runtime.")
    }
    try await runtime.install()
    return await runtime.status()
  }
}

/// How long one runtime's status may take in a list.
private let statusLimit = 20.0

/// The value `body` returns, or `fallback` when it takes longer than `seconds`.
/// `body` is cancelled then, and not waited for.
package func firstOf<T: Sendable>(seconds: Double, or fallback: T, _ body: @escaping @Sendable () async -> T) async -> T {
  let (results, deliver) = AsyncStream<T>.makeStream()
  let work = Task { deliver.yield(await body()) }
  let timer = Task {
    try await Task.sleep(for: .seconds(seconds))
    deliver.yield(fallback)
  }
  var result = fallback
  for await value in results {
    result = value
    break
  }
  work.cancel()
  timer.cancel()
  return result
}
