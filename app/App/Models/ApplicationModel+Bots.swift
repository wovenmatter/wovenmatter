import Foundation
import WovenMatterClient
import WovenMatterCore

extension ApplicationModel {
    /// Routes the window's commands to the process that owns execution.
    func controlBots(_ command: BotsCommand) async throws -> BotsCommandResult {
        if isBackendFrontend {
            guard let result = try await sendBackendCommand(.bots(command)).bots else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            return result
        }
        guard let piBotSupervisor else { throw ApplicationModelError.dashboardStoreUnavailable }
        return try await piBotSupervisor.perform(command)
    }

    func startBotsClient() {
        // The background server has no window to project into.
        guard LocalExecutionRole.current != .backend else { return }
        bots.perform = { [weak self] command in
            guard let self else { throw CancellationError() }
            return try await self.controlBots(command)
        }
        Task { await bots.refreshRuntime() }
    }

    /// Called when agent tools exist, since the MCP grant and notification sink live there.
    func configureBotsRuntime() {
        guard LocalExecutionRole.current.ownsExecution else { return }
        guard let support = try? Self.dashboardSupportDirectory() else { return }
        let supervisor = piBotSupervisor ?? PiBotRuntimeSupervisor(
            supportDirectory: support, instance: DevelopmentLaunch.instance ?? "default")
        piBotSupervisor = supervisor
        supervisor.onChange = { [weak self, weak supervisor] in
            guard let self, let supervisor else { return }
            if !self.isBackendFrontend { self.bots.apply(supervisor.snapshot) }
            Task { await self.backendApplicationService?.invalidations.publish(scopes: [.bots]) }
        }
        supervisor.issueMCPGrant = { [weak self] installation in
            guard let tools = self?.agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
            return try await tools.issueBotGrant(installationID: installation)
        }
        supervisor.revokeMCPGrants = { [weak self] installation in
            self?.agentTools?.revokeBotGrants(installationID: installation)
        }
        supervisor.mcpEnabled = { [weak self] in
            (try? await self?.agentTools?.database.toolSettings())?.botMCP.isEnabled ?? true
        }
        supervisor.mcpLocalPort = { [weak self] in
            guard let endpoint = try? await self?.agentTools?.mcpEndpoint() else { return nil }
            return URL(string: endpoint)?.port
        }
        agentTools?.botNotificationSink = { [weak supervisor] notification in
            guard let supervisor else { throw CancellationError() }
            try await supervisor.deliver(notification)
        }
        supervisor.start()
    }
}
