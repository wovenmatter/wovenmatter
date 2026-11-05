import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    /// Remote workspaces this Mac manages. Only this Mac holds their credentials,
    /// so it reads their usage and passes it on to its paired Macs.
    var managedRemoteUsageDevices: [UsageDeviceIdentity] {
        remoteWorkspaces.workspaces.map {
            .init(id: $0.id.uuidString.lowercased(), name: $0.name, kind: .linux)
        }
    }

    /// Every device this Mac can read usage from right now: paired Macs, managed
    /// remote workspaces, and iPhones and iPads whose records have synced here.
    func usageDeviceEndpoints() async -> [UsageDeviceEndpoint] {
        let managed = Set(managedRemoteUsageDevices.map(\.id))
        let peerSync = companionHost.peerSync
        // The route list is shared across the library, so it includes this Mac too.
        let ownDeviceID = try? await dashboardStore?.database.companionLibraryIdentity().hostDeviceID
        var endpoints = peerSync.routes.filter { $0.deviceID != ownDeviceID }.map { route in
            UsageDeviceEndpoint(
                identity: .init(id: route.deviceID, name: route.name, kind: .mac),
                keepsLastingHistory: true,
                excludedRelays: managed
            ) { request in
                try await peerSync.requestUsage(route: route, request: request)
            }
        }
        let workspaces = remoteWorkspaces
        endpoints += remoteWorkspaces.workspaces.map { configuration in
            UsageDeviceEndpoint(
                identity: .init(id: configuration.id.uuidString.lowercased(), name: configuration.name, kind: .linux)
            ) { request in
                try await workspaces.usageExport(request, for: configuration)
            }
        }
        if let database = dashboardStore?.database,
           let replicated = try? await database.companionExecutionWorkspaces() {
            endpoints += replicated.filter { $0.kind == .ios && $0.isVisibleInConnections }.map { workspace in
                UsageDeviceEndpoint.piDurableHistory(
                    identity: .init(id: workspace.id, name: workspace.name, kind: .ios),
                    database: database
                )
            }
        }
        return endpoints
    }
}
