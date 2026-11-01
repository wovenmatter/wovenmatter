import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

struct PairedWorkspaceNavigationTests {
    @Test func registrationsUseCurrentDevicePerspectiveAndRetainOfflinePhones() {
        let local = UUID().uuidString.lowercased(), phone = UUID().uuidString.lowercased()
        let linux = UUID().uuidString.lowercased(), otherMac = UUID().uuidString.lowercased()
        let values: [CompanionExecutionWorkspace] = [
            .init(id: local, libraryID: "library", ownerDeviceID: local, kind: .mac, name: "This Mac"),
            .init(id: phone, libraryID: "library", ownerDeviceID: phone, kind: .ios, name: "iPhone"),
            .init(id: linux, libraryID: "library", ownerDeviceID: local, kind: .linux, name: "Linux"),
            .init(id: otherMac, libraryID: "library", ownerDeviceID: otherMac, kind: .mac, name: "Other Mac")
        ]
        let result = DashboardPairedWorkspaceSidebarModel.workspaces(values,
            localID: "device:" + local, configuredRemoteIDs: ["remote:" + linux])
        #expect(Set(result.map(\.id)) == [phone, otherMac])
        #expect(result.first(where: { $0.id == phone })?.endpoint == nil)
        let fromOtherMac = DashboardPairedWorkspaceSidebarModel.workspaces(values,
            localID: otherMac, configuredRemoteIDs: [linux])
        #expect(Set(fromOtherMac.map(\.id)) == [phone, local])
    }

    @Test func centralRegistrationUsesItsExplicitContentIdentityRatherThanRoutingOrHostID() throws {
        let routeID = UUID().uuidString.lowercased(), hostID = UUID().uuidString.lowercased()
        let contentID = UUID().uuidString.lowercased(), phoneID = UUID().uuidString.lowercased()
        let central = CompanionExecutionWorkspace(id: routeID, libraryID: "library", ownerDeviceID: hostID,
            kind: .mac, name: "Central Mac", executionDeviceID: hostID, contentWorkspaceID: "device:" + contentID)
        let phone = CompanionExecutionWorkspace(id: phoneID, libraryID: "library", ownerDeviceID: phoneID, kind: .ios, name: "iPhone")
        let registrations = [central, phone]
        let fromCentral = DashboardPairedWorkspaceSidebarModel.workspaces(registrations,
            localID: "device:" + contentID, configuredRemoteIDs: [])
        #expect(fromCentral.map(\.id) == [phoneID])
        let fromPhone = DashboardPairedWorkspaceSidebarModel.workspaces(registrations,
            localID: phoneID, configuredRemoteIDs: [])
        #expect(fromPhone.map(\.id) == [routeID])
        #expect(CompanionWorkspaceIdentity.canonicalID("device:" + contentID, workspaces: registrations)
            == CompanionWorkspaceIdentity.canonicalID(routeID, workspaces: registrations))
        #expect(CompanionWorkspaceIdentity.canonicalID("device:" + hostID, workspaces: registrations)
            == CompanionWorkspaceIdentity.canonicalID(routeID, workspaces: registrations))
    }

    @Test func backendReplicaCarriesNodePerspectiveAndInstalledAgentCatalog() throws {
        let nodeID = UUID().uuidString.lowercased(), otherID = UUID().uuidString.lowercased()
        var replica = DevelopmentReplicaSnapshot()
        replica.localWorkspaceID = nodeID
        replica.workspaces = [
            .init(id: nodeID, libraryID: "library", ownerDeviceID: nodeID, kind: .mac, name: "This Mac"),
            .init(id: otherID, libraryID: "library", ownerDeviceID: otherID, kind: .mac, name: "Other Mac")
        ]
        replica.workspaceProviders = [otherID: [.init(id: "pi-durable", runtimeKind: "pi", displayName: "Pi Durable", available: true)]]
        let received = try JSONDecoder().decode(DevelopmentReplicaSnapshot.self, from: JSONEncoder().encode(replica))
        #expect(received.workspaceProviders?[otherID]?.map(\.displayName) == ["Pi Durable"])
        #expect(DashboardPairedWorkspaceSidebarModel.workspaces(received.workspaces ?? [],
            localID: received.localWorkspaceID, configuredRemoteIDs: []).map(\.id) == [otherID])
    }

    @Test func deletedRegistrationsDisappearAndAliasesDoNotDuplicateDevices() {
        let phone = UUID().uuidString.lowercased()
        let values: [CompanionExecutionWorkspace] = [
            .init(id: phone, libraryID: "library", ownerDeviceID: phone, kind: .ios, name: "iPhone"),
            .init(id: "device:" + phone, libraryID: "library", ownerDeviceID: phone, kind: .ios, name: "Legacy alias"),
            .init(id: UUID().uuidString, libraryID: "library", ownerDeviceID: "removed", kind: .ios, name: "Removed", deleted: true)
        ]
        let result = DashboardPairedWorkspaceSidebarModel.workspaces(values, localID: nil, configuredRemoteIDs: [])
        #expect(result.map(\.id) == [phone])
    }
}
