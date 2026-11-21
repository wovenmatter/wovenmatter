import Foundation
import Synchronization
import WovenProtocol

/// Requests about the runtimes on this machine and Pi Durable's sign-ins.
func registerRuntimes(_ router: inout Router, sessions: SessionManager, secrets: Secrets) {
  let flows = SignInFlows()

  registerRuntimeList(&router, sessions: sessions, name: { Harness.named($0)?.displayName ?? $0.rawValue },
                      latestRelease: latestRelease)

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
    try await secrets.setSubscription(request.provider, nil)
    return Done()
  }
  router.on(AnswerSignIn.self) { request, _ in
    guard flows.answer(request.flowID, promptID: request.promptID, with: request.answer) else {
      throw ProtocolError(.notFound, "That sign-in is not waiting for an answer.")
    }
    return Done()
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
