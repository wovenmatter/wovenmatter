import XCTest
@testable import CompanionInference

private actor CountingCredentials: InferenceCredentialReading {
  var reads = 0
  func read(connectionID: String) async throws -> String? { reads += 1; return "fixture-secret" }
}
private actor RecordingTransport: InferenceHTTPTransport {
  var requests = [URLRequest]()
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    requests.append(request)
    let lines = request.url?.path.hasSuffix("/v1/inference/stream") == true
      ? ["{\"type\":\"done\",\"reason\":\"stop\",\"message\":{\"content\":[]}}"]
      : []
    return AsyncThrowingStream { output in output.yield(.response(200)); lines.forEach { output.yield(.line($0)) }; output.finish() }
  }
}
/// A mutable decision so tests can revoke between requests, as Settings does.
private final class Decisions: @unchecked Sendable {
  private let lock = NSLock()
  private var value = DataSharingPermissions()
  var permissions: DataSharingPermissions {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
  var policy: DataSharingPolicy { DataSharingPolicy { [self] in permissions.permits($0) } }
}

final class DataSharingPermissionTests: XCTestCase {
  let model = InferenceModel(id: "gpt-4", name: "GPT", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1")
  let request = "{\"model\":{\"id\":\"gpt-4\",\"provider\":\"openai\"},\"context\":{\"messages\":[{\"role\":\"user\",\"content\":\"Summarize my private note\"}]}}"
  var connection: InferenceConnection { .init(id: "key", name: "API", provider: "openai", route: .direct, modelID: "gpt-4", selectedModel: model) }

  func testExistingAccountWithoutDecisionSendsNothingAndReadsNoCredential() async throws {
    let transport = RecordingTransport(), credentials = CountingCredentials()
    // An account saved by an earlier build has no grant; the service default also denies.
    for sharing in [DataSharingPolicy.denied, DataSharingPolicy.granted(.init())] {
      let service = CompanionInferenceService(connection: connection, credentials: credentials, transport: transport, model: model, sharing: sharing)
      do { try await service.stream(requestJSON: request, emit: { _ in }); XCTFail("Sent without permission") }
      catch DataSharingError.permissionRequired(let destination) {
        XCTAssertEqual(destination, .init(service: .inference, provider: "openai", origin: "https://api.openai.com"))
      }
    }
    let sent = await transport.requests.count, reads = await credentials.reads
    XCTAssertEqual(sent, 0); XCTAssertEqual(reads, 0)
  }

  func testGrantAllowsOnlyThatEndpointAndRevocationStopsTheNextRequest() async throws {
    let transport = RecordingTransport(), decisions = Decisions()
    let destination = try XCTUnwrap(DataSharingDestination.inference(connection, model: model))
    decisions.permissions.grant(destination)
    let service = CompanionInferenceService(connection: connection, credentials: CountingCredentials(), transport: transport, model: model, sharing: decisions.policy)
    // The fixture stream's decoding outcome is irrelevant; only the transmitted request matters.
    _ = try? await service.stream(requestJSON: request, emit: { _ in })
    var sent = await transport.requests
    XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent.first?.url?.host, "api.openai.com")

    decisions.permissions.revoke(destination)
    do { try await service.stream(requestJSON: request, emit: { _ in }); XCTFail("Sent after revocation") }
    catch DataSharingError.permissionRequired {}
    sent = await transport.requests
    XCTAssertEqual(sent.count, 1)
  }

  func testChangedEndpointNeedsANewDecision() async throws {
    let first = InferenceConnection(id: "host", name: "Host", provider: "openai-codex", accountID: "a", route: .adapter, baseURL: "https://first.example.ts.net", modelID: "m")
    var moved = first; moved.baseURL = "https://second.example.ts.net"
    let decisions = Decisions(), transport = RecordingTransport()
    decisions.permissions.grant(try XCTUnwrap(DataSharingDestination.inference(first, model: nil)))
    let adapterRequest = "{\"model\":{\"id\":\"m\",\"provider\":\"openai-codex\"},\"context\":{\"messages\":[]}}"
    try await CompanionInferenceService(connection: first, credentials: CountingCredentials(), transport: transport, sharing: decisions.policy)
      .stream(requestJSON: adapterRequest, emit: { _ in })
    do {
      try await CompanionInferenceService(connection: moved, credentials: CountingCredentials(), transport: transport, sharing: decisions.policy)
        .stream(requestJSON: adapterRequest, emit: { _ in })
      XCTFail("A different endpoint reused permission")
    } catch DataSharingError.permissionRequired(let destination) { XCTAssertEqual(destination.origin, "https://second.example.ts.net") }
    let hosts = await transport.requests.map(\.url?.host)
    XCTAssertEqual(hosts, ["first.example.ts.net"])

    // Account or model edits on the same endpoint keep the decision; another provider does not.
    var otherAccount = first; otherAccount.accountID = "b"; otherAccount.modelID = "n"
    XCTAssertTrue(decisions.permissions.permits(try XCTUnwrap(DataSharingDestination.inference(otherAccount, model: nil))))
    var otherProvider = first; otherProvider.provider = "claude-subscription"
    XCTAssertFalse(decisions.permissions.permits(try XCTUnwrap(DataSharingDestination.inference(otherProvider, model: nil))))
  }

  func testRequestToAnotherOriginThanPermittedIsRefused() async throws {
    var permissions = DataSharingPermissions()
    let destination = DataSharingDestination(service: .inference, provider: "openai", origin: "https://api.openai.com")
    permissions.grant(destination)
    let elsewhere = URLRequest(url: URL(string: "https://api.openai.com.attacker.example/v1/responses")!)
    do { try await DataSharingPolicy.authorize(elsewhere, as: destination, using: DataSharingPolicy.granted(permissions)); XCTFail() }
    catch DataSharingError.permissionRequired {}
    try await DataSharingPolicy.authorize(URLRequest(url: URL(string: "https://API.openai.com/v1/responses")!), as: destination, using: DataSharingPolicy.granted(permissions))
  }

  func testDecisionsPersistAndADisclosureChangeAsksAgain() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("data-sharing.json")
    XCTAssertEqual(try DataSharingPermissions.load(from: file), .init())
    var permissions = DataSharingPermissions()
    permissions.grant(.exa); permissions.grant(.exa)
    XCTAssertEqual(permissions.grants.count, 1)
    try permissions.save(to: file)
    let reopened = try DataSharingPermissions.load(from: file)
    XCTAssertTrue(reopened.permits(.exa))
    var outdated = reopened; outdated.grants[0].disclosureVersion = DataSharingPermissions.disclosureVersion - 1
    XCTAssertFalse(outdated.permits(.exa)); XCTAssertTrue(outdated.current.isEmpty)
  }

  func testWebSearchAndPageReadsNeedExaPermissionWithoutReadingTheKey() async throws {
    let transport = RecordingTransport(), credentials = CountingCredentials()
    let search = QuickChatWebSearch(credentials: credentials, transport: transport)
    do { _ = try await search.search("private question"); XCTFail() } catch QuickChatSearchError.permissionRequired {}
    do { _ = try await search.read("https://example.org/page"); XCTFail() } catch QuickChatSearchError.permissionRequired {}
    let sent = await transport.requests.count, reads = await credentials.reads
    XCTAssertEqual(sent, 0); XCTAssertEqual(reads, 0)
    // Inference permission for another destination does not cover Exa.
    var permissions = DataSharingPermissions()
    permissions.grant(.init(service: .inference, provider: "openai", origin: "https://api.openai.com"))
    do { _ = try await QuickChatWebSearch(credentials: credentials, transport: transport, sharing: DataSharingPolicy.granted(permissions)).search("q"); XCTFail() }
    catch QuickChatSearchError.permissionRequired {}
    let after = await transport.requests.count
    XCTAssertEqual(after, 0)
  }
}
