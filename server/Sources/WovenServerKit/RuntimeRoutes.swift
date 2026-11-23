import Foundation
import Synchronization
import WovenProtocol

/// Requests about the runtimes on this machine and Pi Durable's sign-ins.
func registerRuntimes(_ router: inout Router, sessions: SessionManager, secrets: Secrets) {
  let flows = SignInFlows()
  let lastStatuses = Mutex<[RuntimeKind: RuntimeStatus]>([:])

  router.on(ListRuntimes.self) { request, _ in
    let runtimes = await sessions.allRuntimes
    return await withTaskGroup(of: RuntimeStatus.self) { group in
      for runtime in runtimes {
        group.addTask {
          // One slow CLI must not hold up the list: it is reported as it last
          // answered, or as not answering when it never has.
          let late = lastStatuses.withLock { $0[runtime.kind] }
            ?? RuntimeStatus(runtime: runtime.kind, name: Harness.named(runtime.kind)?.displayName ?? runtime.kind.rawValue,
                             installed: false, detail: "It did not answer in time.")
          return await firstOf(seconds: statusLimit, or: late) {
            var status = await runtime.status()
            if request.checkForUpdates { status.latestVersion = await latestRelease(runtime.kind) }
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

  router.on(ListSignIns.self) { _, _ in
    guard let pi = await sessions.runtime(.piDurable) as? PiDurableRuntime else { return [] }
    guard let list = await pi.signIns() else { throw ProtocolError(.failed, "Pi Durable could not list its providers.") }
    return list
  }
  router.on(ListProviderModels.self) { request, _ in
    guard let pi = await sessions.runtime(.piDurable) as? PiDurableRuntime else { return [] }
    return try await pi.models(refresh: request.refresh)
  }
  router.on(SetAPIKey.self) { request, _ in
    let key = request.key?.trimmingCharacters(in: .whitespacesAndNewlines)
    try await secrets.setAPIKey(request.provider, key?.isEmpty == false ? key : nil)
    return Done()
  }
  router.on(SignOut.self) { request, _ in
    if let runtime = request.runtime {
      try await harnessSignOut(runtime, credential: request.credential)
      return Done()
    }
    // The Claude subscription is Claude Code's own sign-in: signing out signs Claude Code out.
    if request.provider == PiDurableRuntime.claude { try await harnessSignOut(.claudeCode, credential: nil) }
    try await secrets.setSubscription(request.provider, nil)
    return Done()
  }
  router.on(AnswerSignIn.self) { request, _ in
    guard flows.answer(request.flowID, promptID: request.promptID, with: request.answer) else {
      throw ProtocolError(.notFound, "That sign-in is not waiting for an answer.")
    }
    return Done()
  }
  /// The Claude subscription's sign-in: Claude Code's own, the one its harness row runs, so
  /// signing in again switches the account. The Settings row asks for the code the sign-in
  /// page shows; the marker is saved when Claude Code finishes.
  @Sendable func claudeSignIn(_ pi: PiDurableRuntime) throws -> (String, AsyncThrowingStream<SignInEvent, any Error>) {
    let flowID = UUID().uuidString.lowercased()
    let events = try harnessSignIn(StartSignIn(runtime: .claudeCode, signInMethod: "claude-account"), answers: flows.open(flowID))
    let (relayed, continuation) = AsyncThrowingStream<SignInEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
    let relay = Task {
      defer { flows.close(flowID) }
      var asked = false
      do {
        for try await event in events {
          switch event {
          case .open:
            continuation.yield(event)
            if !asked {
              asked = true
              continuation.yield(.prompt(id: "code", message: "Paste the code from the Claude sign-in page."))
            }
          case .finished:
            try await secrets.setSubscription(PiDurableRuntime.claude, .object(["type": .string("native")]))
            let signIn = await pi.signIns()?.first { $0.provider == PiDurableRuntime.claude }
            continuation.yield(.finished(signIn ?? SignIn(provider: PiDurableRuntime.claude, name: "Claude", kind: .subscription, connected: true)))
          default:
            continuation.yield(event)
          }
        }
      } catch {
        if !Task.isCancelled { continuation.yield(.failed(message: "\(error)")) }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in relay.cancel() }
    return (flowID, relayed)
  }
  router.subscription(StartSignIn.self) { request, _ in
    if request.runtime != nil {
      let flowID = UUID().uuidString.lowercased()
      let events = try harnessSignIn(request, answers: flows.open(flowID))
      let (relayed, continuation) = AsyncThrowingStream<SignInEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
      let relay = Task {
        defer { flows.close(flowID) }
        do { for try await event in events { continuation.yield(event) } } catch {}
        continuation.finish()
      }
      continuation.onTermination = { _ in relay.cancel() }
      return (flowID, relayed)
    }
    guard let pi = await sessions.runtime(.piDurable) as? PiDurableRuntime else {
      throw ProtocolError(.badRequest, "This machine has no Pi Durable runtime.")
    }
    if request.provider == PiDurableRuntime.claude { return try claudeSignIn(pi) }
    guard PiDurableRuntime.subscriptions.contains(request.provider) else {
      throw ProtocolError(.badRequest, "\(request.provider) does not sign in with a subscription.")
    }
    let flowID = UUID().uuidString.lowercased()
    let answers = flows.open(flowID)
    let (events, continuation) = AsyncThrowingStream<SignInEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
    let provider = request.provider
    let task = Task {
      defer { flows.close(flowID) }
      do {
        let result = try await pi.control(.object(["action": .string("login"), "provider": .string(provider)]), events: { event in
          if let prompt = event["prompt"], let id = prompt["id"]?.string {
            continuation.yield(.prompt(id: id, message: prompt["message"]?.string ?? ""))
          } else if let url = event["url"]?.string {
            continuation.yield(.open(url: url, code: event["code"]?.string, instructions: event["instructions"]?.string))
          }
        }, answers: answers)
        guard let credential = result["credential"] else { throw RuntimeError.failed("The sign-in returned nothing.") }
        try await secrets.setSubscription(provider, credential)
        let signIn = await pi.signIns()?.first { $0.provider == provider }
          ?? SignIn(provider: provider, name: provider, kind: .subscription, connected: true)
        continuation.yield(.finished(signIn))
      } catch {
        if !Task.isCancelled { continuation.yield(.failed(message: "\(error)")) }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return (flowID, events)
  }
}

/// Sign-in flows in progress, each with where its answers go.
private final class SignInFlows: Sendable {
  private let flows = Mutex<[String: AsyncStream<(id: String, answer: String)>.Continuation]>([:])

  func open(_ id: String) -> AsyncStream<(id: String, answer: String)> {
    let (stream, continuation) = AsyncStream<(id: String, answer: String)>.makeStream()
    flows.withLock { $0[id] = continuation }
    return stream
  }

  func answer(_ id: String, promptID: String, with answer: String) -> Bool {
    guard let continuation = flows.withLock({ $0[id] }) else { return false }
    continuation.yield((promptID, answer))
    return true
  }

  func close(_ id: String) {
    flows.withLock { $0.removeValue(forKey: id) }?.finish()
  }
}

/// How long one runtime's status may take in a list.
private let statusLimit = 20.0

/// The value `body` returns, or `fallback` when it takes longer than `seconds`.
/// `body` is cancelled then, and not waited for.
func firstOf<T: Sendable>(seconds: Double, or fallback: T, _ body: @escaping @Sendable () async -> T) async -> T {
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
