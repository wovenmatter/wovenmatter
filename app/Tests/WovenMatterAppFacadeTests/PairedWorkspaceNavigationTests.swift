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
