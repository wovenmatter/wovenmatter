import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

extension ApplicationModel {
    /// One Linux machine this Mac reads usage from, under one identity whichever Mac
    /// added it, so the same host is never two devices.
    struct UsageLinuxDevice {
        let identity: UsageDeviceIdentity
        /// IDs its usage was stored under before it was read by its member ID.
        let formerIDs: [String]
        let fetch: @Sendable (UsageDeviceExportRequest) async throws -> UsageDeviceExportPage
    }

    /// Every Linux machine in the synced registry (workspace hosts and bots-only
    /// machines), read with this Mac's member signature by the host's member ID. A host
    /// this Mac added that has no member identity yet is read with its installer bearer
    /// under its workspace ID, as before.
    func usageLinuxDevices() async -> [UsageLinuxDevice] {
        var devices: [UsageLinuxDevice] = []
        var signedWorkspaceIDs: Set<String> = []
        for target in await memberBotTargets() where target.workspace.kind == .linux {
            guard let client = try? await botsClient(for: target.workspace) else { continue }
            signedWorkspaceIDs.insert(target.workspace.id)
            let local = remoteWorkspaces.workspaces.first { $0.id.uuidString.lowercased() == target.workspace.id }
            devices.append(.init(
                identity: .init(id: target.audience, name: local?.name ?? target.workspace.name, kind: .linux),
                formerIDs: [target.workspace.id]
            ) { request in
                try await client.request("v1/usage/export", query: [
                    URLQueryItem(name: "since", value: String(request.since)),
                    URLQueryItem(name: "offset", value: String(request.offset)),
                ], timeout: 60)
            })
        }
        let workspaces = remoteWorkspaces
        for configuration in remoteWorkspaces.workspaces where !signedWorkspaceIDs.contains(configuration.id.uuidString.lowercased()) {
            devices.append(.init(
                identity: .init(id: configuration.id.uuidString.lowercased(), name: configuration.name, kind: .linux),
                formerIDs: []
            ) { request in
                try await workspaces.usageExport(request, for: configuration)
            })
        }
        return devices
    }

    /// What this Mac passes on to its paired Macs: the Linux machines it reads. A Mac
    /// that reads one of them itself ignores the relayed copy.
    func relayedUsageDevices() async -> [UsageDeviceIdentity] {
        await usageLinuxDevices().map(\.identity)
    }

    /// Every device this Mac can read usage from right now: paired Macs, every Linux
    /// machine in the library, and iPhones and iPads whose records have synced here.
    func usageDeviceEndpoints() async -> [UsageDeviceEndpoint] {
        let linux = await usageLinuxDevices()
        let direct = Set(linux.flatMap { [$0.identity.id] + $0.formerIDs })
        let peerSync = libraryHost.peerSync
        // The route list is shared across the library, so it includes this Mac too.
        let ownDeviceID = try? await libraryStore?.database.libraryIdentity().hostDeviceID
        var endpoints = peerSync.routes.filter { $0.deviceID != ownDeviceID }.map { route in
            UsageDeviceEndpoint(
                identity: .init(id: route.deviceID, name: route.name, kind: .mac),
                keepsLastingHistory: true,
                excludedRelays: direct
            ) { request in
                try await peerSync.requestUsage(route: route, request: request)
            }
        }
        endpoints += linux.map { device in
            UsageDeviceEndpoint(identity: device.identity, formerIDs: device.formerIDs, fetch: device.fetch)
        }
        if let database = libraryStore?.database,
           let replicated = try? await database.libraryExecutionWorkspaces() {
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
