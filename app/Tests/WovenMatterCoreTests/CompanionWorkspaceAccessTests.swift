import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Central device execution policy", .serialized)
struct CompanionWorkspaceAccessTests {
  @Test func denialSurvivesRestartAndRegistrationWithoutChangingPublicationOwner() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let database = try await WorkspaceDatabase(url: url)
    let identity = try await database.companionLibraryIdentity()
    let device = UUID().uuidString.lowercased()
    let other = UUID().uuidString.lowercased()
    var workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .linux, name: "Linux", executionDeviceID: UUID().uuidString.lowercased())
    workspace = try await database.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    #expect(try await database.companionWorkspaceAccessAllowed(deviceID: device, workspaceID: workspace.id))
    await #expect(throws: CompanionAPIError.self) {
      try await database.setCompanionWorkspaceAccess(deviceID: device, workspaceID: workspace.id, enabled: false, authorizedBy: other)
    }
    try await database.setCompanionWorkspaceAccess(deviceID: device, workspaceID: workspace.id, enabled: false, authorizedBy: identity.hostDeviceID)
    let restarted = try await WorkspaceDatabase(url: url)
    #expect(try await !restarted.companionWorkspaceAccessAllowed(deviceID: device, workspaceID: workspace.id))
    #expect(try await restarted.companionWorkspaceAccessAllowed(deviceID: other, workspaceID: workspace.id))
    workspace.name = "Renamed Linux"
    workspace = try await restarted.registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: workspace.revision), deviceID: identity.hostDeviceID)
    #expect(try await !restarted.companionWorkspaceAccessAllowed(deviceID: device, workspaceID: workspace.id))
    #expect(try await restarted.companionWorkspaceAccessPolicies() == [.init(deviceID: device, workspaceID: workspace.id, enabled: false)])
    try await restarted.setCompanionWorkspaceAccess(deviceID: device, workspaceID: workspace.id, enabled: true, authorizedBy: identity.hostDeviceID)
    #expect(try await restarted.companionWorkspaceAccessAllowed(deviceID: device, workspaceID: workspace.id))
    #expect(try await !restarted.companionWorkspaceAccessAllowed(deviceID: device, workspaceID: UUID().uuidString.lowercased()))
    #expect(try await restarted.companionExecutionWorkspaces().first?.executionDeviceID == workspace.executionDeviceID)
    workspace.deleted = true
    _ = try await restarted.registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: workspace.revision), deviceID: identity.hostDeviceID)
    #expect(try await !restarted.companionWorkspaceAccessAllowed(deviceID: device, workspaceID: workspace.id))
  }
}
