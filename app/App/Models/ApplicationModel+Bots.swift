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
        let host = BotsHostController(directory: directory, engine: BotEngineHostFactory.make(directory),
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
            installBots: { [weak self] hostName, userName in
                guard let self else { throw CancellationError() }
                try await self.remoteWorkspaces.installBotsHost(hostName: hostName, userName: userName)
            },
            updateLinuxHost: { [weak self] machineID in
                guard let self, let id = directory.linux[machineID], let configuration = self.remoteWorkspaces.configuration(id: id) else {
                    throw BotsError.unavailable("That Linux host is unavailable.")
                }
                self.remoteWorkspaces.updateContainer(configuration)
            },
            syncErrors: { [weak self] in self.map { Array($0.companionHost.peerSync.errors.values) + Self.libraryUpdateNotices($0.companionHost.peerSync.syncStatus) } ?? [] })
    }

    // MARK: Other machines

    /// Every other machine whose Woven server answers `/v1/bots/status`. Linux hosts are
    /// reached through their SSH tunnel; other Macs through their companion endpoint.
    fileprivate func remoteBotMachines(thisMacVersion: String?, directory: BotsRemoteDirectory) async -> [BotMachine] {
        let linux = remoteWorkspaces.workspaces.filter { $0.kind == .host }.map { configuration in
            Task { await self.linuxBotMachine(configuration, thisMacVersion: thisMacVersion, directory: directory) }
        }
        let macs = await otherMacWorkspaces().map { workspace in
            Task { await self.macBotMachine(workspace, thisMacVersion: thisMacVersion, directory: directory) }
        }
        var machines: [BotMachine] = []
        for task in linux + macs { machines.append(await task.value) }
        return machines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func linuxBotMachine(_ configuration: RemoteWorkspaceConfiguration, thisMacVersion: String?,
                                 directory: BotsRemoteDirectory) async -> BotMachine {
        do {
            let client = try await remoteWorkspaces.botsService(for: configuration)
            let status = try await botsTimeout { try await client.botsStatus() }
            directory.linux[status.machine.deviceID.lowercased()] = configuration.id
            return status.machine(kind: .linux, socket: client.botsSocket, thisMacVersion: thisMacVersion)
        } catch {
            return BotMachine(id: "linux:" + configuration.id.uuidString.lowercased(), name: configuration.name, kind: .linux,
                              state: .unreachable, message: Self.botsUnavailableText(error))
        }
    }

    private func macBotMachine(_ workspace: CompanionExecutionWorkspace, thisMacVersion: String?,
                               directory: BotsRemoteDirectory) async -> BotMachine {
        do {
            let access = try await botsAccess(for: workspace)
            let status: BotsRemoteStatus = try await botsTimeout {
                try await BotsRemoteHTTP.request(access.endpoint, path: "v1/bots/status", bearer: access.token)
            }
            directory.macs[status.machine.deviceID.lowercased()] = workspace.id
            let socket = BotSocketEndpoint(url: access.endpoint.appending(path: "v1/bots/ws"), bearer: access.token)
            return status.machine(kind: .mac, socket: socket, thisMacVersion: thisMacVersion)
        } catch {
            return BotMachine(id: workspace.executionDeviceID ?? workspace.ownerDeviceID, name: workspace.name, kind: .mac,
                              state: .unreachable, message: Self.botsUnavailableText(error))
        }
    }

    private static func botsUnavailableText(_ error: any Error) -> String {
        let text = error.localizedDescription
        return text.contains("404") ? "Its Woven server doesn't run bots yet. Update it to use bots there." : text
    }

    private func otherMacWorkspaces() async -> [CompanionExecutionWorkspace] {
        guard let database = dashboardStore?.database,
              let own = try? await database.companionLibraryIdentity().hostDeviceID,
              let workspaces = try? await database.companionExecutionWorkspaces() else { return [] }
        return workspaces.filter {
            $0.kind == .mac && $0.isVisibleInConnections && $0.endpoint != nil && ($0.executionDeviceID ?? $0.ownerDeviceID) != own
        }
    }

    /// How this Mac authenticates to another member's `/v1/bots/*`. Today: the
    /// execution grant it already holds for that Mac. Member auth replaces this one function.
    func botsAccess(for workspace: CompanionExecutionWorkspace) async throws -> (endpoint: URL, token: String) {
        let credential = try await centralExecutionClient().directCredential(for: workspace)
        return (credential.endpoint, credential.token)
    }

    fileprivate func setRemoteBotResources(machineID: String, _ resources: BotResourceSettings, directory: BotsRemoteDirectory) async throws {
        let id = machineID.lowercased()
        if let configurationID = directory.linux[id], let configuration = remoteWorkspaces.configuration(id: configurationID) {
            _ = try await remoteWorkspaces.botsService(for: configuration).setBotsResources(resources)
            return
        }
        if let workspaceID = directory.macs[id], let workspace = await otherMacWorkspaces().first(where: { $0.id == workspaceID }) {
            let access = try await botsAccess(for: workspace)
            struct Body: Encodable { let resources: BotResourceSettings }
            let _: BotsRemoteStatus = try await BotsRemoteHTTP.request(access.endpoint, path: "v1/bots/resources", bearer: access.token,
                                                                      body: JSONEncoder().encode(Body(resources: resources)))
            return
        }
        throw BotsError.unavailable("That machine is unavailable.")
    }

    /// Online Linux and macOS tailnet peers and what each needs before it can run bots.
    func discoverBotDevices() async throws -> [BotDiscoveredDevice] {
        let peers = try await Task.detached { try RemoteMachineDiscovery.tailnetMachines(includeMacs: true) }.value
        let linuxHosts = Set(remoteWorkspaces.workspaces.filter { $0.kind == .host }.map { $0.hostName.lowercased() })
        let macs = await otherMacWorkspaces()
        let macHosts = Set(macs.compactMap { $0.endpoint?.host?.lowercased() })
        let macNames = Set(macs.map { $0.name.lowercased() })
        return peers.map { peer in
            let short = (peer.dnsName ?? peer.hostName).split(separator: ".").first.map { String($0).lowercased() } ?? peer.hostName.lowercased()
            if peer.system == "macOS" {
                let connected = macHosts.contains { $0 == peer.dnsName?.lowercased() || $0.hasPrefix(short + ".") } || macNames.contains(peer.displayName.lowercased())
                return BotDiscoveredDevice(hostName: peer.hostName, displayName: peer.displayName, dnsName: peer.dnsName,
                                           system: .macOS, state: connected ? .ready : .installApp)
            }
            let installed = linuxHosts.contains(peer.hostName.lowercased()) || linuxHosts.contains(short)
            return BotDiscoveredDevice(hostName: peer.hostName, displayName: peer.displayName, dnsName: peer.dnsName,
                                       system: .linux, state: installed ? .ready : .installBots)
        }
    }
}

/// Which local record reaches each remote machine, learned from its status reply.
@MainActor
final class BotsRemoteDirectory {
    var linux: [String: UUID] = [:]
    var macs: [String: String] = [:]
}

/// `/v1/bots/*` on another Mac's companion endpoint, with this Mac's grant.
enum BotsRemoteHTTP {
    static func request<T: Decodable>(_ endpoint: URL, path: String, bearer: String, body: Data? = nil) async throws -> T {
        var request = URLRequest(url: endpoint.appending(path: path), timeoutInterval: 10)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(CompanionAPIError.self, from: data))?.message
            throw BotsError.unavailable(message ?? "That Mac answered \(status).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
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
