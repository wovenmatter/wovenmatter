import Foundation
import Security
import Testing
import WovenMatterCore
@testable import WovenMatterClient
@testable import WovenMatterDashboardStore

struct OpenClawCredentialRecoveryTests {
  @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled])
  func deniedCredentialDoesNotRepeatConnectionAttempts(status: OSStatus) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    _ = try database.createLocalACPSession(runtimeKind: .openclaw, title: "Fixture", ownerDeviceID: UUID())
    let agentID = try #require(database.dashboardAgents().first).id
    let endpoint = OpenClawGatewayEndpoint(url: URL(string: "ws://127.0.0.1:1")!, authorization: .localService)
    try database.saveOpenClawGatewayLink(OpenClawGatewayLink(
      agentID: agentID, location: .localAgentWorkspace, endpoint: endpoint
    ))
    let attempts = CredentialConnectionAttempts()
    let coordinator = OpenClawGatewayCoordinator(database: database, connectClient: { _ in
      await attempts.record()
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    })
    do {
      _ = try await coordinator.reconnect(agentID: agentID, attempts: 3)
      Issue.record("A denied Keychain access must fail the reconnect.")
    } catch {
      #expect((error as NSError).domain == NSOSStatusErrorDomain)
      #expect((error as NSError).code == Int(status))
    }
    #expect(await attempts.count == 1)
    let link = try #require(database.openClawGatewayLinks().first)
    #expect(link.connectionStatus == .unavailable)
    await coordinator.shutdown()
  }

  @Test func explicitAuthorizationAndConnectionsUseTheSameStableCredentialScope() {
    let agentID = UUID()
    let firstEndpoint = OpenClawGatewayEndpoint(url: URL(string: "ws://127.0.0.1:10001/gateway")!, authorization: .remoteWorkspace)
    let secondEndpoint = OpenClawGatewayEndpoint(url: URL(string: "ws://127.0.0.1:10002/gateway")!, authorization: .remoteWorkspace)
    let first = OpenClawGatewayLink(agentID: agentID, location: .remoteWorkspace, endpoint: firstEndpoint)
    let reopened = OpenClawGatewayLink(agentID: agentID, location: .remoteWorkspace, endpoint: secondEndpoint)
    #expect(OpenClawGatewayCoordinator.credentialScope(for: first) == OpenClawGatewayCoordinator.credentialScope(for: reopened))
    let local = OpenClawGatewayLink(agentID: agentID, location: .localAgentWorkspace, endpoint: firstEndpoint)
    #expect(OpenClawGatewayCoordinator.credentialScope(for: local) != OpenClawGatewayCoordinator.credentialScope(for: first))
  }
}

private actor CredentialConnectionAttempts {
  private(set) var count = 0
  func record() { count += 1 }
}
