import Foundation
import Observation
import WovenMatterClient

struct DefaultAgentSDKCommand: Codable {
    let workspaceID: UUID?
    let request: DefaultAgentSDKRequest
    var key: String { workspaceID?.uuidString.lowercased() ?? "local" }
}

struct DefaultAgentSDKWorkspaceState: Codable, Equatable {
    var status: DefaultAgentSDKStatus?
    var operation: DefaultAgentSDKRequest?
    var error: String?
    var completedAction: DefaultAgentSDKRequest.Action?
    var busy: Bool { operation != nil }
}

/// Execution belongs to the background service; UI state survives disclosure and scope changes.
@MainActor @Observable
final class DefaultAgentSDKSettingsModel {
    private(set) var workspaces: [String: DefaultAgentSDKWorkspaceState] = [:]
    @ObservationIgnored private var operations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var polling: [String: Task<Void, Never>] = [:]
    var isBusy: Bool { workspaces.values.contains(where: \.busy) }

    func state(for key: String) -> DefaultAgentSDKWorkspaceState { workspaces[key] ?? .init() }

    func request(_ command: DefaultAgentSDKCommand, connections: DefaultAgentSettingsModel,
                 remoteWorkspaces: RemoteWorkspacesModel) {
        if let backendRequest = connections.backendRequest {
            guard !state(for: command.key).busy else { return }
            workspaces[command.key, default: .init()].operation = command.request
            workspaces[command.key]?.error = nil
            polling[command.key]?.cancel()
            polling[command.key] = Task { [weak self] in
                do {
                    var data = try await backendRequest("connections.sdks.command", JSONEncoder().encode(command))
                    while let self {
                        let state = try JSONDecoder().decode(DefaultAgentSDKWorkspaceState.self, from: data)
                        // Dictionary subscript mutation notifies observers even for an identical poll result.
                        if self.workspaces[command.key] != state { self.workspaces[command.key] = state }
                        if !state.busy {
                            if command.request.action == .update && state.error == nil {
                                self.refreshModels(after: command, connections: connections, remoteWorkspaces: remoteWorkspaces)
                            }
                            return
                        }
                        try await Task.sleep(for: .milliseconds(500))
                        data = try await backendRequest("connections.sdks.snapshot", JSONEncoder().encode(command))
                        try Task.checkCancellation()
                    }
                } catch is CancellationError { return }
                catch {
                    self?.workspaces[command.key]?.operation = nil
                    self?.workspaces[command.key]?.error = error.localizedDescription
                }
            }
        } else if LocalExecutionRole.current == .frontend {
            workspaces[command.key, default: .init()].error = "The background service is not connected."
        } else {
            start(command, remoteWorkspaces: remoteWorkspaces) { [weak self, weak connections] in
                guard let self, let connections else { return }
                self.refreshModels(after: command, connections: connections, remoteWorkspaces: remoteWorkspaces)
            }
        }
    }

    private func refreshModels(after command: DefaultAgentSDKCommand, connections: DefaultAgentSettingsModel,
                               remoteWorkspaces: RemoteWorkspacesModel) {
        guard command.request.action == .update else { return }
        // The invalidator refreshes only the backend projection and enabled labels.
        // Do not start full helper discovery merely because an SDK was replaced.
        connections.invalidateSDKCatalog(scopeKey: command.key)
    }

    func start(_ command: DefaultAgentSDKCommand, remoteWorkspaces: RemoteWorkspacesModel,
               onUpdate: (@MainActor () -> Void)? = nil) {
        guard !state(for: command.key).busy else { return }
        workspaces[command.key, default: .init()].operation = command.request
        workspaces[command.key]?.error = nil
        // Capture the destination before scheduling work; a later configuration
        // edit must fail the existing request identity instead of retargeting it.
        let remote = command.workspaceID.flatMap { remoteWorkspaces.configuration(id: $0) }
        operations[command.key] = Task { [weak self] in
            do {
                let status: DefaultAgentSDKStatus
                if command.workspaceID != nil {
                    guard let configuration = remote else {
                        throw BackendRPCError.remote("This workspace is no longer configured.")
                    }
                    status = try await remoteWorkspaces.defaultAgentSDKs(command.request, configuration: configuration)
                } else {
                    status = try await DefaultAgentSDKControl.run(command.request)
                }
                guard let self else { return }
                self.workspaces[command.key] = .init(status: status, completedAction: command.request.action)
                if command.request.action == .update { onUpdate?() }
            } catch {
                self?.workspaces[command.key]?.error = error.localizedDescription
                self?.workspaces[command.key]?.operation = nil
            }
            self?.operations[command.key] = nil
        }
    }
}
