import CompanionClient
import Foundation
import WovenMatterClient
import WovenMatterCompanion
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    /// Routes the window's commands to the process that owns execution.
    func controlBots(_ command: BotsCommand) async throws -> BotsCommandResult {
        if isBackendFrontend {
            guard let result = try await sendBackendCommand(.bots(command)).bots else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            return result
        }
        guard let botsHost else { throw BotsError.unavailable("Bots are still starting.") }
        return try await botsHost.perform(command)
    }

    func startBotsClient() {
        // The background server has no window to project into.
        guard LocalExecutionRole.current != .backend else { return }
        bots.perform = { [weak self] command in
            guard let self else { throw CancellationError() }
            return try await self.controlBots(command)
        }
        bots.startRefreshing()
    }

    /// Called once agent tools exist, since bot keys and deliveries live there.
    func configureBotsRuntime() {
        guard LocalExecutionRole.current.ownsExecution else { return }
        if let botsHost { attachBotDeliveries(botsHost); return }
        guard let support = try? Self.dashboardSupportDirectory() else { return }
        let directory = support.appending(path: "Bots")
        // The VM lives beside Bots in the support directory (`<support>/WovenVM`).
        let host = BotsHostController(directory: directory, engine: BotEngineHostFactory.make(support),
                                      dependencies: makeBotsHostDependencies())
        botsHost = host
        host.onChange = { [weak self] in
            guard let self else { return }
            Task {
                if !self.isBackendFrontend { await self.bots.refresh() }
                await self.backendApplicationService?.invalidations.publish(scopes: [.bots])
            }
        }
        attachBotDeliveries(host)
        host.start()
    }

    /// Agent tools can be rebuilt; each new instance delivers to the same host.
    private func attachBotDeliveries(_ host: BotsHostController) {
        agentTools?.botNotificationSink = { [weak host] notification in
            guard let host else { throw CancellationError() }
            try await host.deliver(notification)
        }
    }

    private func makeBotsHostDependencies() -> BotsHostDependencies {
        let directory = BotsRemoteDirectory()
        return BotsHostDependencies(
            identity: { [weak self] in
                guard let database = self?.dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
                return (try await database.companionLibraryIdentity().hostDeviceID, DevelopmentLaunch.deviceName())
            },
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            issueKey: { [weak self] machineID, botID, name in
                guard let tools = self?.agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
                return try await tools.issueBotKey(machineID: machineID, botID: botID, botName: name)
            },
            revokeKey: { [weak self] callerID, sticky in
                guard let tools = self?.agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
                try tools.revokeBotKey(callerID: callerID, sticky: sticky)
            },
            reinstate: { [weak self] callerID in try await self?.agentTools?.reinstateBot(callerID: callerID) },
            setPaused: { [weak self] machineID, paused in
                guard let tools = self?.agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
                try await tools.setBotsPaused(machineID: machineID, paused: paused)
            },
            callers: { [weak self] in try await self?.agentTools?.botCallers() ?? [] },
            isPaused: { [weak self] machineID in (try? await self?.dashboardStore?.database.isBotMachinePaused(machineID)) ?? false },
            botMCP: { [weak self] in try? await self?.agentTools?.database.toolSettings().botMCP },
            recordConversation: { [weak self] machineID, batch in
                guard let database = self?.dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
                try await database.recordBotConversation(machineID: machineID, batch)
            },
            deleteConversations: { [weak self] machineID, botID in
                try await self?.dashboardStore?.database.deleteBotConversations(machineID: machineID, botID: botID)
            },
            inferenceCredential: { provider in try await BotsHostAPI.storedCredential(provider: provider) },
            remoteMachines: { [weak self] version in await self?.remoteBotMachines(thisMacVersion: version, directory: directory) ?? [] },
            setRemoteResources: { [weak self] machineID, resources in
                guard let self else { throw CancellationError() }
                try await self.setRemoteBotResources(machineID: machineID, resources, directory: directory)
            },
            discover: { [weak self] in try await self?.discoverBotDevices() ?? [] },
            installBots: { [weak self] hostName, userName, progress in
                guard let self else { throw CancellationError() }
                try await self.remoteWorkspaces.installBotsHost(hostName: hostName, userName: userName, progress: progress)
            },
            updateLinuxHost: { [weak self] machineID, progress in
                guard let self else { throw CancellationError() }
                try await self.updateLinuxBotHost(machineID: machineID, directory: directory, progress: progress)
            },
            updateRemoteEngine: { [weak self] machineID in
                guard let self, let workspaceID = directory.members[machineID.lowercased()],
                      let workspace = await self.otherMacWorkspaces().first(where: { $0.id == workspaceID }) else {
                    throw BotsError.unavailable("That Mac is unavailable.")
                }
                let _: BotsRemoteStatus = try await self.botsClient(for: workspace).request("v1/bots/engine/update", method: "POST",
                                                                                            body: Data("{}".utf8))
            },
            syncErrors: { [weak self] in self.map { Array($0.companionHost.peerSync.errors.values) + Self.libraryUpdateNotices($0.companionHost.peerSync.syncStatus) } ?? [] },
            signSocket: { [weak self] url, audience in
                guard let self else { throw CancellationError() }
                return try await self.signBotSocket(url: url, audience: audience)
            })
    }

    // MARK: Other machines

    /// Every other machine whose Woven server answers `/v1/bots/status`: every Mac and
    /// Linux workspace in the synced registry, reached with this Mac's member signature
    /// whichever Mac added it. A Linux host this Mac added that is not in the registry
    /// (a bots-only server) is still reached through its SSH tunnel.
    func remoteBotMachines(thisMacVersion: String?, directory: BotsRemoteDirectory) async -> [BotMachine] {
        let members = await memberBotWorkspaces()
        // A machine whose library schema differs cannot sync with this Mac: it needs Update everything.
        let schema = try? await dashboardStore?.database.pairedLibrarySchema()
        let signedIDs = Set(members.map(\.id))
        let tunnelled = remoteWorkspaces.workspaces.filter { $0.kind == .host && !signedIDs.contains($0.id.uuidString.lowercased()) }
        let linux = tunnelled.map { configuration in
            Task { await self.linuxBotMachine(configuration, thisMacVersion: thisMacVersion, schema: schema, directory: directory) }
        }
        let signed = members.map { workspace in
            Task { await self.memberBotMachine(workspace, thisMacVersion: thisMacVersion, schema: schema, directory: directory) }
        }
        var machines: [BotMachine] = []
        for task in linux + signed { machines.append(await task.value) }
        return machines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A Linux host this Mac added, over its SSH tunnel with the installer's bearer.
    private func linuxBotMachine(_ configuration: RemoteWorkspaceConfiguration, thisMacVersion: String?, schema: String?,
                                 directory: BotsRemoteDirectory) async -> BotMachine {
        do {
            let client = try await remoteWorkspaces.botsService(for: configuration)
            let status = try await botsTimeout { try await client.botsStatus() }
            directory.linux[status.machine.deviceID.lowercased()] = configuration.id
            return status.machine(kind: .linux, socket: client.botsSocket, thisMacVersion: thisMacVersion,
                                  expectedHostFingerprint: await RemoteWorkspaceSSHClient.bundledHostFingerprint(),
                                  thisMacLibrarySchema: schema)
        } catch {
            return BotMachine(id: "linux:" + configuration.id.uuidString.lowercased(), name: configuration.name, kind: .linux,
                              state: .unreachable, message: Self.botsUnavailableText(error))
        }
    }

    /// Another Mac or a Linux host from the registry, with signed requests and a signed socket.
    private func memberBotMachine(_ workspace: CompanionExecutionWorkspace, thisMacVersion: String?, schema: String?,
                                  directory: BotsRemoteDirectory) async -> BotMachine {
        let kind: BotMachine.Kind = workspace.kind == .linux ? .linux : .mac
        do {
            let client = try await botsClient(for: workspace)
            let status: BotsRemoteStatus = try await botsTimeout { try await client.request("v1/bots/status", timeout: 10) }
            // A server that answers for another device is not this workspace's.
            guard status.machine.deviceID.lowercased() == client.audience else { throw BotsError.unavailable("It answered as another device.") }
            directory.members[client.audience] = workspace.id
            let socket = BotSocketEndpoint.signed(client.endpoint.appending(path: "v1/bots/ws"), audience: client.audience)
            return status.machine(kind: kind, socket: socket, thisMacVersion: thisMacVersion,
                                  expectedHostFingerprint: kind == .linux ? await RemoteWorkspaceSSHClient.bundledHostFingerprint() : nil,
                                  thisMacLibrarySchema: schema)
        } catch {
            return BotMachine(id: "member:" + workspace.id, name: workspace.name, kind: kind,
                              state: .unreachable, message: Self.botsUnavailableText(error))
        }
    }

    private static func botsUnavailableText(_ error: any Error) -> String {
        if case MemberSignedHTTPError.http(404, _, _)? = error as? MemberSignedHTTPError {
            return "Its Woven server doesn't run bots yet. Update it to use bots there."
        }
        let text = error.localizedDescription
        return text.contains("404") ? "Its Woven server doesn't run bots yet. Update it to use bots there." : text
    }

    /// Every other Mac and Linux workspace in the registry that can be addressed:
    /// an endpoint and the member that serves it, one workspace per member.
    func memberBotTargets() async -> [(workspace: CompanionExecutionWorkspace, audience: String)] {
        guard let database = dashboardStore?.database, let directory = try? await companionHost.peerSync.members(),
              let workspaces = try? await database.companionExecutionWorkspaces() else { return [] }
        var seen: Set<String> = [directory.identity.deviceID], targets: [(workspace: CompanionExecutionWorkspace, audience: String)] = []
        for workspace in workspaces where (workspace.kind == .mac || workspace.kind == .linux) && workspace.isVisibleInConnections && workspace.endpoint != nil {
            guard let audience = await directory.audience(for: workspace), seen.insert(audience).inserted else { continue }
            targets.append((workspace, audience))
        }
        return targets
    }
    func memberBotWorkspaces() async -> [CompanionExecutionWorkspace] { await memberBotTargets().map(\.workspace) }

    private func otherMacWorkspaces() async -> [CompanionExecutionWorkspace] {
        await memberBotWorkspaces().filter { $0.kind == .mac }
    }

    /// How this Mac reaches another member's `/v1/bots/*`: its own member signature,
    /// addressed to the workspace's execution device. Nothing is issued or stored.
    func botsClient(for workspace: CompanionExecutionWorkspace) async throws -> MemberSignedHTTPClient {
        let directory = try await companionHost.peerSync.members()
        guard let endpoint = workspace.endpoint, let audience = await directory.audience(for: workspace) else {
            throw BotsError.unavailable("\(workspace.name)'s address or member identity has not reached this Mac yet.")
        }
        return try MemberSignedHTTPClient(endpoint: endpoint, signer: directory.identity.signer, audience: audience,
                                          send: companionHost.remoteHostSend)
    }

    /// Headers for one signed bots socket upgrade. Only `/v1/bots/ws` on a member's
    /// private tailnet address is signed, and only for a member in the registry.
    func signBotSocket(url: URL, audience: String) async throws -> [String: String] {
        guard ["wss", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased().hasSuffix(".ts.net") == true,
              url.user == nil, url.password == nil, url.path.hasSuffix("/v1/bots/ws"),
              await memberBotTargets().contains(where: { $0.audience == audience.lowercased() }),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BotsError.unavailable("That bots connection is not a member's.")
        }
        let target = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        return try await companionHost.memberSigner().headers(method: "GET", target: target, audience: audience)
    }

    fileprivate func setRemoteBotResources(machineID: String, _ resources: BotResourceSettings, directory: BotsRemoteDirectory) async throws {
        let id = machineID.lowercased()
        if let workspaceID = directory.members[id], let workspace = await memberBotWorkspaces().first(where: { $0.id == workspaceID }) {
            struct Body: Encodable { let resources: BotResourceSettings }
            let _: BotsRemoteStatus = try await botsClient(for: workspace).request("v1/bots/resources", method: "POST",
                body: JSONEncoder().encode(Body(resources: resources)))
            return
        }
        if let configurationID = directory.linux[id], let configuration = remoteWorkspaces.configuration(id: configurationID) {
            _ = try await remoteWorkspaces.botsService(for: configuration).setBotsResources(resources)
            return
        }
        throw BotsError.unavailable("That machine is unavailable.")
    }

    /// "Update everything" for one Linux host: the signed `/v1/host/update` from any
    /// Mac. SSH is only the fallback for a host this Mac added itself. Returns once the
    /// update has finished.
    fileprivate func updateLinuxBotHost(machineID: String, directory: BotsRemoteDirectory,
                                        progress: @escaping @MainActor (String) -> Void) async throws {
        let id = machineID.lowercased()
        if let workspaceID = directory.members[id] {
            do {
                progress("Updating…")
                try await remoteWorkspaces.runSharedHost(workspaceID, .update)
                return
            } catch {
                guard let configuration = UUID(uuidString: workspaceID).flatMap(remoteWorkspaces.configuration(id:)) else { throw error }
                try await remoteWorkspaces.updateHost(configuration, progress: progress)
                return
            }
        }
        guard let configurationID = directory.linux[id], let configuration = remoteWorkspaces.configuration(id: configurationID) else {
            throw BotsError.unavailable("That Linux host is unavailable.")
        }
        try await remoteWorkspaces.updateHost(configuration, progress: progress)
    }

    /// Online Linux and macOS tailnet peers and what each needs before it can run bots.
    func discoverBotDevices() async throws -> [BotDiscoveredDevice] {
        let peers = try await Task.detached { try RemoteMachineDiscovery.tailnetMachines(includeMacs: true) }.value
        let members = await memberBotWorkspaces()
        let configured = remoteWorkspaces.workspaces.filter { $0.kind == .host }
        let linuxMembers = members.filter { $0.kind == .linux }
        let macs = members.filter { $0.kind == .mac }
        let macHosts = Set(macs.compactMap { $0.endpoint?.host?.lowercased() })
        let macNames = Set(macs.map { $0.name.lowercased() })
        // Every check starts at once and each is bounded, so the whole list answers in one round trip.
        var checks: [(device: BotDiscoveredDevice, state: Task<BotDiscoveredDevice.State, Never>?)] = []
        for peer in peers {
            let short = Self.shortName(peer.dnsName ?? peer.hostName)
            let matches = { (host: String) in host.lowercased() == peer.hostName.lowercased() || Self.shortName(host) == short }
            var device = BotDiscoveredDevice(hostName: peer.hostName, displayName: peer.displayName, dnsName: peer.dnsName,
                                             system: peer.system == "macOS" ? .macOS : .linux, state: .installBots)
            var state: Task<BotDiscoveredDevice.State, Never>?
            if peer.system == "macOS" {
                let connected = macHosts.contains { $0 == peer.dnsName?.lowercased() || $0.hasPrefix(short + ".") } || macNames.contains(peer.displayName.lowercased())
                device.state = connected ? .ready : .installApp
            } else if let configuration = configured.first(where: { matches($0.hostName) }) {
                // A Woven server hosts bots only once it says so: a workspace host has none
                // until they are added.
                state = Task { await self.linuxBotsState(hostName: configuration.hostName, userName: configuration.userName) }
            } else if let workspace = linuxMembers.first(where: { $0.endpoint?.host.map(matches) == true }) {
                // Another Mac added this server; it answers for itself.
                state = Task { await self.memberBotsState(workspace) }
            }
            checks.append((device, state))
        }
        var devices: [BotDiscoveredDevice] = []
        for (device, state) in checks {
            var checked = device
            if let state { checked.state = await state.value }
            devices.append(checked)
        }
        return devices
    }

    private static func shortName(_ host: String) -> String {
        host.split(separator: ".").first.map { String($0).lowercased() } ?? host.lowercased()
    }

    /// `remote-host.sh inspect`'s `bots.state` for a host this Mac added.
    private func linuxBotsState(hostName: String, userName: String?) async -> BotDiscoveredDevice.State {
        do {
            let inspected = try await botsTimeout(seconds: 15) { try await self.remoteWorkspaces.inspectHost(hostName: hostName, userName: userName) }
            return inspected.bots?.isReady == true ? .ready : .installBots
        } catch {
            return .failed("Couldn't check it over Tailscale SSH: " + error.localizedDescription)
        }
    }

    /// The `GET /v1/bots/status` of a host another Mac added: bots are on when it says so.
    private func memberBotsState(_ workspace: CompanionExecutionWorkspace) async -> BotDiscoveredDevice.State {
        do {
            let client = try await botsClient(for: workspace)
            let status: BotsRemoteStatus = try await botsTimeout { try await client.request("v1/bots/status", timeout: 10) }
            return status.enabled ? .ready : .installBots
        } catch {
            let text = Self.botsUnavailableText(error)
            // A server too old to answer has no bots yet.
            return text.contains("doesn't run bots") ? .installBots : .failed(text)
        }
    }
}

/// Which local record reaches each remote machine, learned from its status reply.
@MainActor
final class BotsRemoteDirectory {
    /// Linux hosts reached through this Mac's SSH tunnel, by machine ID.
    var linux: [String: UUID] = [:]
    /// Members reached with signed requests: machine ID to registry workspace ID.
    var members: [String: String] = [:]
}

/// A status probe must not hold the whole list: a silent machine is reported unavailable.
@MainActor
private func botsTimeout<T: Sendable>(seconds: Double = 8, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
    let task = Task { @MainActor in try await work() }
    let timer = Task {
        try await Task.sleep(for: .seconds(seconds))
        task.cancel()
    }
    defer { timer.cancel() }
    do { return try await task.value }
    catch is CancellationError { throw BotsError.unavailable("It did not answer in time.") }
}
