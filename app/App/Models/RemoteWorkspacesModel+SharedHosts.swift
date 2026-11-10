import Foundation
import WovenMatterClient
import WovenMatterCore

/// What one Mac knows about a Linux host it manages without SSH.
struct SharedHostState: Codable, Equatable, Sendable {
    var status: GatewayJSONValue?
    var logs: String?
    var error: String?
    var progress: String?
    var busy = false
    var updatedAt: Date?

    var serviceState: String? { status?.objectValue?["state"]?.stringValue ?? status?.objectValue?["status"]?.stringValue }
    var version: String? { status?.objectValue?["version"]?.stringValue ?? status?.objectValue?["fingerprint"]?.stringValue }
}

enum SharedHostAction: Codable, Equatable, Sendable {
    case refresh, logs, restart, update
    case configureBots(poolBytes: Int64?, diskBytes: Int64?)
}

extension RemoteWorkspacesModel {
    /// Status, logs, restart, update and bot resources for any Linux host in
    /// the registry, over its signed `/v1/host/*` routes. The Mac that added a
    /// host keeps SSH for first install and as the update fallback.
    func manageSharedHost(_ workspaceID: String, _ action: SharedHostAction) {
        if isBackendProjection {
            Task {
                do { _ = try await requestSharedHostBackend(.sharedHost(workspaceID, action)) }
                catch { sharedHosts[workspaceID, default: .init()].error = error.localizedDescription }
            }
            return
        }
        Task { await performSharedHost(workspaceID, action) }
    }

    func performSharedHost(_ workspaceID: String, _ action: SharedHostAction,
                           pollInterval: Duration = .seconds(3), updateTimeout: Duration = .seconds(900)) async {
        guard sharedHosts[workspaceID]?.busy != true else { return }
        // A failure is recorded in `sharedHosts` for the settings row.
        try? await runSharedHost(workspaceID, action, pollInterval: pollInterval, updateTimeout: updateTimeout)
    }

    /// The same, reporting failure to the caller ("Update everything" falls
    /// back to SSH for a host this Mac added). The outcome is also recorded.
    func runSharedHost(_ workspaceID: String, _ action: SharedHostAction,
                       pollInterval: Duration = .seconds(3), updateTimeout: Duration = .seconds(900)) async throws {
        guard sharedHosts[workspaceID]?.busy != true else {
            throw RemoteWorkspaceClientError.invalidResponse("This host is already busy with another change.")
        }
        sharedHosts[workspaceID, default: .init()].busy = true
        sharedHosts[workspaceID]?.error = nil
        defer { sharedHosts[workspaceID]?.busy = false; sharedHosts[workspaceID]?.progress = nil }
        do {
            guard let make = sharedHostAdministration else {
                throw RemoteWorkspaceClientError.invalidResponse("Host administration is unavailable until this Mac finishes starting.")
            }
            let client = try await make(workspaceID)
            switch action {
            case .refresh: sharedHosts[workspaceID]?.status = try await client.status()
            case .logs: sharedHosts[workspaceID]?.logs = try await client.logs(lines: 500)
            case .restart:
                sharedHosts[workspaceID]?.progress = "Restarting…"
                try await client.restart()
            case .configureBots(let pool, let disk):
                _ = try await client.configureBots(poolBytes: pool, diskBytes: disk)
                sharedHosts[workspaceID]?.status = try await client.status()
            case .update:
                sharedHosts[workspaceID]?.progress = "Preparing the host service bundle…"
                let bundle = sharedHostBundle
                let prepared = try await Task.detached { try bundle() }.value
                sharedHosts[workspaceID]?.progress = "Uploading the host service…"
                try await client.update(bundle: prepared.bundle, fingerprint: prepared.fingerprint)
                sharedHosts[workspaceID]?.progress = "Updating…"
                let clock = ContinuousClock(), deadline = clock.now.advanced(by: updateTimeout)
                while clock.now < deadline {
                    try await Task.sleep(for: pollInterval)
                    // The host restarts during an update; unanswered polls retry.
                    guard let state = try? await client.updateState().objectValue else { continue }
                    switch state["state"]?.stringValue {
                    case "succeeded":
                        sharedHosts[workspaceID]?.status = (try? await client.status()) ?? state["result"]
                        sharedHosts[workspaceID]?.updatedAt = Date()
                        return
                    case "failed":
                        let detail = state["error"]?.objectValue?["error"]?.stringValue ?? "The host update failed and was rolled back."
                        throw RemoteWorkspaceClientError.invalidResponse(detail)
                    default: continue
                    }
                }
                throw RemoteWorkspaceClientError.invalidResponse("The host update has not finished yet. Check its status again shortly.")
            }
            sharedHosts[workspaceID]?.updatedAt = Date()
        } catch {
            sharedHosts[workspaceID]?.error = error.localizedDescription
            throw error
        }
    }
}
