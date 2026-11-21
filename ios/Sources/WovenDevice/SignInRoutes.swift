import Foundation
import MobileInference
import Synchronization
import WovenProtocol
import WovenServerCore

/// The sign-in and model server requests, answered by the device about its
/// own sign-ins, in the shapes a machine answers them, so the shared settings
/// store works against the device as against a Mac. Keys and subscriptions go
/// to the device's Keychain only; nothing is sealed or synced.
func signInRoutes(_ providers: Providers, oauth: @escaping @Sendable () -> InferenceOAuthSession) -> Router {
  var router = Router()
  let flows = SignInFlows()

  router.on(ListSignIns.self) { _, _ in
    await providers.signIns()
  }
  router.on(ListProviderModels.self) { request, _ in
    await providers.models(refresh: request.refresh).map {
      ProviderModel(id: $0.reference, name: $0.name, provider: $0.provider,
                    providerName: $0.provider.hasPrefix(ModelServers.prefix) ? URL(string: $0.baseUrl)?.host ?? $0.provider
                      : Providers.name(of: $0.provider))
    }
  }
  router.on(SetAPIKey.self) { request, _ in
    try await providers.setKey(request.provider, request.key?.trimmingCharacters(in: .whitespacesAndNewlines))
    return Done()
  }
  router.on(SignOut.self) { request, _ in
    guard request.runtime == nil else { throw ProtocolError(.badRequest, "An iPhone or iPad has no agent CLIs to sign out of.") }
    try await providers.signOut(request.provider)
    return Done()
  }
  router.on(AnswerSignIn.self) { request, _ in
    guard flows.answer(request.flowID, promptID: request.promptID, with: request.answer) else {
      throw ProtocolError(.notFound, "That sign-in is not waiting for an answer.")
    }
    return Done()
  }
  router.subscription(StartSignIn.self) { request, _ in
    guard request.runtime == nil else { throw ProtocolError(.badRequest, "An iPhone or iPad has no agent CLIs to sign in to.") }
    let provider = request.provider
    guard InferenceOAuthSession.supports(provider) else {
      throw ProtocolError(.badRequest, "\(provider) does not sign in with a subscription.")
    }
    let flowID = UUID().uuidString.lowercased()
    let answers = flows.open(flowID)
    let (events, continuation) = AsyncThrowingStream<SignInEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
    let session = oauth()
    let task = Task {
      defer { flows.close(flowID) }
      do {
        let challenge = try await session.start(provider: provider)
        continuation.yield(.open(url: challenge.verificationURL.absoluteString, code: challenge.userCode, instructions: nil))
        let credential: InferenceOAuthCredential
        switch challenge.kind {
        case .deviceCode:
          credential = try await session.poll()
        case .authorizationCode:
          let promptID = "code"
          continuation.yield(.prompt(id: promptID, message: "Paste the code the sign-in page shows."))
          var code: String?
          for await answer in answers where answer.id == promptID {
            code = answer.answer
            break
          }
          guard let code else { throw CancellationError() }
          credential = try await session.complete(code: code)
        }
        try await providers.credentials.save(try credential.serialized(), connectionID: provider)
        continuation.yield(.finished(SignIn(provider: provider, name: Providers.name(of: provider), kind: .subscription,
                                            connected: true)))
      } catch {
        if !Task.isCancelled { continuation.yield(.failed(message: error.localizedDescription)) }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in
      task.cancel()
      Task { await session.cancel() }
    }
    return (flowID, events)
  }

  router.on(ListLocalModelServers.self) { _, _ in
    await providers.servers.list()
  }
  router.on(ConnectLocalModelServer.self) { request, _ in
    try await providers.servers.connect(url: request.url, key: request.key, replacing: request.replacing,
                                        credentials: providers.credentials, transport: providers.transport)
  }
  router.on(RemoveLocalModelServer.self) { request, _ in
    try await providers.servers.remove(request.id, credentials: providers.credentials)
    return Done()
  }
  return router
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
