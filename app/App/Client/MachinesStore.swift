import Foundation
import Observation
import WovenProtocol

/// Every Woven machine on the tailnet, this Mac first: whether it is online,
/// what it can run, its harness inventory and sign-ins, its Mac permission
/// status and its server. Commands rename and remove machines, find Linux
/// machines and install the server over SSH, and install or update harnesses.
///
/// Per-machine state is keyed by machine id. Harness and sign-in members are in
/// `MachinesStore+Harnesses.swift`.
@MainActor
@Observable
final class MachinesStore {
    /// Every machine in the library as this Mac's server reports it.
    private var statuses: [MachineStatus] = []
    /// Each machine's runtimes, by machine id, as its own server last reported them.
    var machineRuntimes: [String: [RuntimeStatus]] = [:]
    /// This Mac's runtimes.
    var runtimes: [RuntimeStatus] { thisMachine.flatMap { machineRuntimes[$0.id] } ?? [] }
    /// This Mac's connection and the direct connections to the other machines.
    @ObservationIgnored private(set) weak var connections: MachineConnections?
    /// The connection to this Mac's server.
    var server: ServerConnection? { connections?.local }
    /// Machines whose connection was connected when last looked at.
    @ObservationIgnored private var connectedMachineIDs: Set<String> = []

    /// This machine first, then the others by name, each with its connection state.
    var machines: [Machine] {
        statuses.map { status in
            let connection = status.isThisMachine ? server : connections?.remotes[status.machine.id]
            let runtimes = machineRuntimes[status.machine.id] ?? []
            return Machine(id: status.machine.id, name: status.machine.name,
                           platform: status.machine.platform == .linux ? .linux : .mac,
                           isThisMachine: status.isThisMachine,
                           connection: connectionState(status, connected: connection?.isConnected == true), syncs: status.syncs,
                           appVersion: (status.isThisMachine ? nil : connection?.remote?.appVersion) ?? status.appVersion,
                           runtimes: runtimes.filter(\.installed).compactMap { AgentRuntimeKind(runtime: $0.runtime) })
        }.sorted { ($0.isThisMachine ? 0 : 1, $0.name.localizedLowercase, $0.id)
            < ($1.isThisMachine ? 0 : 1, $1.name.localizedLowercase, $1.id) }
    }

    /// Online while the UI is connected to its server. Starting while this UI
    /// starts, restarts or updates it, while this Mac's server reaches it and the
    /// UI is not connected yet, and for a while after it joined in an install.
    /// Stopped for this Mac otherwise, and for a machine this UI stopped.
    private func connectionState(_ status: MachineStatus, connected: Bool) -> MachineConnectionState {
        let id = status.machine.id
        if connected { return .online }
        if startingMachineIDs.contains(id) { return .starting }
        if status.isThisMachine || stoppedMachineIDs.contains(id) { return .stopped }
        if status.online || joiningMachineIDs[id] != nil { return .starting }
        return .offline
    }

    /// Each machine's runtimes with a CLI installed, as the sidebar lists them under
    /// its Agents; the status says whether one can run there now.
    var agents: [WorkspaceAgent] {
        machines.flatMap { machine in
            machine.runtimes.map { kind in
                WorkspaceAgent(id: WorkspaceAgent.id(machineID: machine.id, runtime: kind), displayName: kind.displayName,
                               iconKey: kind.rawValue, runtimeKind: kind, machineID: machine.id,
                               status: agentStatus(kind, on: machine))
            }
        }
    }

    private func agentStatus(_ kind: AgentRuntimeKind, on machine: Machine) -> WorkspaceAgent.Status {
        switch machine.connection {
        case .starting: return .starting
        case .stopped, .offline: return .offline
        case .online: break
        }
        switch harnessInstallations[machine.id]?[kind]?.state {
        case .settingUp: return .settingUp
        case .adapterRequired: return .adapterRequired
        default: break
        }
        let signedIn = machineRuntimes[machine.id]?.first { AgentRuntimeKind(runtime: $0.runtime) == kind }?.signedIn
        return signedIn == false ? .needsAuthentication : .ready
    }

    func attach(_ connections: MachineConnections) {
        self.connections = connections
        connections.whenChanged { [weak self] in self?.connectionsChanged() }
        following?.cancel()
        let local = connections.local
        following = Task { [weak self] in
            await local.follow(SubscribeMachines(), reply: { [weak self] in self?.setStatuses($0) },
                               event: { [weak self] in self?.setStatuses($0) })
        }
    }

    /// Follows this Mac's server's machine list, so a machine its server
    /// links after the list was first read still gets a direct connection.
    @ObservationIgnored private var following: Task<Void, Never>?

    /// A machine that joins while an install runs reads as starting until it connects.
    private func setStatuses(_ new: [MachineStatus]) {
        if let host = installingHostnames.first, !statuses.isEmpty {
            let known = Set(statuses.map(\.machine.id))
            for status in new where !status.isThisMachine && !known.contains(status.machine.id) {
                markJoining(status.machine.id, host: host)
            }
        }
        statuses = new
        connections?.update(new)
    }

    /// Reads as starting until it connects, its install fails, or two minutes pass.
    private func markJoining(_ machineID: String, host: String) {
        let joining = Joining(host: host)
        joiningMachineIDs[machineID] = joining
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            if self?.joiningMachineIDs[machineID] == joining { self?.joiningMachineIDs[machineID] = nil }
        }
    }

    /// The connection to `machineID`'s server, when the UI is connected to it now.
    func connection(for machineID: String?) -> ServerConnection? {
        guard let connection = connections?.connection(for: machineID), connection.isConnected else { return nil }
        return connection
    }

    /// Reads a machine's runtimes, Pi Durable's sign-ins and its storage each time
    /// the UI connects to its server, this Mac's too (after its server restarts,
    /// for one). Pages show these and read them again only when they are old.
    private func connectionsChanged() {
        guard let connections else { return }
        var connected = Set(connections.remotes.filter { $0.value.isConnected }.map(\.key))
        if connections.local.isConnected, let thisID = connections.thisMachineID { connected.insert(thisID) }
        for machineID in connected.subtracting(connectedMachineIDs) {
            joiningMachineIDs[machineID] = nil
            Task { await readRuntimes(on: machineID, checkForUpdates: false) }
            Task { await refreshProviderSignIns(on: machineID) }
            Task { await readStorage(on: machineID) }
        }
        connectedMachineIDs = connected
    }

    /// Reads the machines and this Mac's runtimes again.
    func reload() async {
        guard let server else { return }
        do {
            setStatuses(try await server.call(ListMachines()))
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
        // Each runtime's status runs its CLI, so library changes do not read
        // them again; Settings and installs do (`refreshHarnesses`). That
        // takes seconds, so nothing waits for it: the folders and chats a
        // reload brings next are this Mac's library, read in milliseconds.
        if !hasReadRuntimes, let thisID = thisMachine?.id {
            Task { await readRuntimes(on: thisID, checkForUpdates: false) }
        }
    }

    // MARK: Server on each machine

    /// Machines whose server this UI stopped, until it starts again.
    private var stoppedMachineIDs: Set<String> = []
    /// Machines whose server is starting, stopping, updating or being removed.
    private(set) var busyMachineIDs: Set<String> = []
    /// Machines whose server this UI is starting, restarting or updating.
    private var startingMachineIDs: Set<String> = []
    /// Machines that joined in an install, by id, until they connect.
    private var joiningMachineIDs: [String: Joining] = [:]
    private struct Joining: Equatable {
        var host: String
        var token = UUID()
    }
    private(set) var serverLogs: [String: String] = [:]
    /// Each machine's disk, as its own server last reported it.
    private(set) var machineStorage: [String: MachineStorage] = [:]
    /// Why the machine list could not be read, for the Workspaces list.
    private(set) var listError: String?
    /// The last failed action on each machine, by machine id, for its own page;
    /// cleared when its next action starts.
    var serverErrors: [String: String] = [:]

    // MARK: Linux machines to add

    /// Tailnet machines without a Woven server.
    private(set) var tailnetMachines: [MachineToAdd] = []
    private(set) var isFindingMachines = false
    private(set) var hasSearchedMachines = false
    private(set) var findMachinesError: String?
    private(set) var machinePreflights: [String: MachinePreflight] = [:]
    private(set) var inspectingHostnames: Set<String> = []
    private(set) var installingHostnames: Set<String> = []
    /// Where each running install has got to, by host.
    private(set) var installStages: [String: InstallStage] = [:]
    /// Installs that finished, by host, with the new machine's id, until the page that started one takes it.
    var finishedInstalls: [String: String] = [:]
    var machineErrors: [String: String] = [:]

    // MARK: This Mac's power policy

    private(set) var idleSleepPolicy = IdleSleepPolicy()
    private(set) var isChangingIdleSleepPolicy = false
    var idleSleepError: String?

    // MARK: Harnesses (see MachinesStore+Harnesses.swift)

    var harnessInstallations: [String: [AgentRuntimeKind: HarnessInstallation]] = [:]
    var checkingHarnesses: [String: Set<AgentRuntimeKind>] = [:]
    var harnessOperations: [String: [AgentRuntimeKind: HarnessOperation]] = [:]
    var harnessErrors: [String: [AgentRuntimeKind: String]] = [:]
    /// Machines whose harness inventory could not be read.
    var harnessInventoryUnavailable: Set<String> = []
    /// Machines whose server was just installed, waiting for harness setup.
    var pendingHarnessSetupMachineIDs: Set<String> = []

    /// The newest release of each harness on each machine, once checked (nil: the check found none).
    var latestVersions: [String: [AgentRuntimeKind: String?]] = [:]
    /// Install or update attempts that failed in a row, per machine and harness.
    var harnessFailures: [String: [AgentRuntimeKind: Int]] = [:]
    /// Machines whose runtimes have been read.
    var runtimesRead: Set<String> = []
    /// When each machine's runtimes were last read.
    @ObservationIgnored var runtimesReadAt: [String: Date] = [:]
    /// This Mac's runtimes have been read.
    var hasReadRuntimes: Bool { thisMachine.map { runtimesRead.contains($0.id) } ?? false }
    @ObservationIgnored var runtimeReads: [String: Task<Void, Never>] = [:]

    var signInStatuses: [String: [AgentRuntimeKind: AgentSignInStatus]] = [:]
    /// Pi Durable's provider accounts on each machine.
    var providerSignInStatuses: [String: [AgentSignInStatus]] = [:]
    var checkingSignIns: [String: Set<AgentRuntimeKind>] = [:]
    var openingSignIns: [String: Set<AgentRuntimeKind>] = [:]
    var removingSignIns: [String: Set<AgentRuntimeKind>] = [:]
    var signInMessages: [String: [AgentRuntimeKind: String]] = [:]
    var signInSessions: [String: [AgentRuntimeKind: HarnessSignInSession]] = [:]
    /// Each running harness sign-in's subscription and the server's flow id.
    @ObservationIgnored var signInTasks: [String: [AgentRuntimeKind: Task<Void, Never>]] = [:]
    @ObservationIgnored var signInFlowIDs: [String: [AgentRuntimeKind: String]] = [:]
    /// Machines whose runtimes are read again while an adapter installs.
    @ObservationIgnored var adapterWatches: Set<String> = []

    init() {}

    // MARK: Machines

    var thisMachine: Machine? { machines.first(where: \.isThisMachine) }
    var otherMachines: [Machine] { machines.filter { !$0.isThisMachine } }
    var onlineMachines: [Machine] { machines.filter(\.isOnline) }

    func machine(id: String) -> Machine? { machines.first { $0.id == id } }

    /// Whether a session with this runtime can start on that machine now.
    func isRuntimeReady(_ runtime: AgentRuntimeKind, on machineID: String) -> Bool {
        guard let machine = machine(id: machineID) else { return false }
        return machine.isOnline && machine.canRun(runtime) && harness(runtime, on: machineID)?.needsAdapter != true
    }

    /// The machines a settings scope covers: every machine for "global", else the one
    /// with that id ("local" is this Mac).
    func machines(inScope scope: String) -> [Machine] {
        switch scope {
        case "global": machines
        case "local": machines.filter(\.isThisMachine)
        default: machines.filter { $0.id == scope }
        }
    }

    /// Any machine can be renamed through this Mac's server; the name syncs.
    func rename(_ machineID: String, to name: String) async throws {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        _ = try await server.call(RenameMachine(name: name, machineID: machineID))
        await reload()
    }

    /// Stops and uninstalls the server there, then deletes the machine, its sessions
    /// and its folders from every library.
    func remove(_ machineID: String) {
        serverErrors[machineID] = nil
        guard let server else { return serverErrors[machineID] = ClientError.notConnected.localizedDescription }
        Task {
            do {
                _ = try await server.call(RemoveMachine(machineID: machineID))
                await reload()
            } catch {
                serverErrors[machineID] = error.localizedDescription
            }
        }
    }

    // MARK: Server

    /// Where its server listens on the tailnet, once this Mac's server has reached it.
    func address(of machineID: String) -> String? {
        statuses.first { $0.machine.id == machineID }?.address
    }
    func isBusy(_ machineID: String) -> Bool { busyMachineIDs.contains(machineID) }

    /// Reads the machine's disk from its own server.
    func readStorage(on machineID: String) async {
        guard let connection = connection(for: machineID),
              let storage = try? await connection.call(ReadStorage()) else { return }
        machineStorage[machineID] = storage
    }

    /// This Mac's server through launchd; a Linux machine's over SSH, through
    /// this Mac's server. Returns once the UI is connected to it.
    func startServer(on machineID: String) async throws {
        busyMachineIDs.insert(machineID)
        startingMachineIDs.insert(machineID)
        defer {
            busyMachineIDs.remove(machineID)
            startingMachineIDs.remove(machineID)
        }
        if machineID == thisMachine?.id {
            try await ThisMachineServer.start()
        } else {
            guard let server, server.isConnected else { throw ClientError.notConnected }
            _ = try await server.call(ControlServer(machineID: machineID, action: .start))
        }
        stoppedMachineIDs.remove(machineID)
        for _ in 0..<60 where machine(id: machineID)?.isOnline != true {
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Stopping a server with a turn running asks first, unless `confirmed`.
    func stopServer(on machineID: String, confirmed: Bool) async throws -> ServerStopResult {
        try await control(.stop, on: machineID, confirmed: confirmed)
    }

    func restartServer(on machineID: String, confirmed: Bool) async throws -> ServerStopResult {
        try await control(.restart, on: machineID, confirmed: confirmed)
    }

    /// Through the machine's own server while the UI is connected to it, else
    /// over SSH through this Mac's server.
    private func control(_ action: ServerAction, on machineID: String, confirmed: Bool) async throws -> ServerStopResult {
        guard let connection = connection(for: machineID) ?? server.flatMap({ $0.isConnected ? $0 : nil }) else {
            throw ClientError.notConnected
        }
        busyMachineIDs.insert(machineID)
        defer { busyMachineIDs.remove(machineID) }
        let result = try await connection.call(ControlServer(machineID: machineID, action: action, confirmed: confirmed))
        guard !result.confirmationRequired else { return ServerStopResult(confirmationRequired: true) }
        if action != .stop { startingMachineIDs.insert(machineID) }
        defer { startingMachineIDs.remove(machineID) }
        if action == .stop {
            stoppedMachineIDs.insert(machineID)
            for _ in 0..<60 where machine(id: machineID)?.isOnline == true {
                try await Task.sleep(for: .milliseconds(500))
            }
        } else {
            // The server goes down, then answers again.
            try await Task.sleep(for: .seconds(2))
            for _ in 0..<60 where machine(id: machineID)?.isOnline != true {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        return ServerStopResult(confirmationRequired: false)
    }

    /// Replaces a Linux machine's server with the release this Mac carries.
    func updateServer(on machineID: String) {
        Task { _ = await sendUpdateServer(machineID) }
    }

    /// Sends `UpdateServer` to this Mac's server; returns an error's text, or nil once it is done.
    func sendUpdateServer(_ machineID: String) async -> String? {
        serverErrors[machineID] = nil
        guard let server else { return ClientError.notConnected.localizedDescription }
        busyMachineIDs.insert(machineID)
        startingMachineIDs.insert(machineID)
        defer {
            busyMachineIDs.remove(machineID)
            startingMachineIDs.remove(machineID)
        }
        do {
            _ = try await server.call(UpdateServer(machineID: machineID))
            await reload()
            return nil
        } catch {
            serverErrors[machineID] = error.localizedDescription
            return error.localizedDescription
        }
    }

    /// Has another Mac update its Woven Matter, sent straight to that Mac's
    /// server; returns an error's text, or nil once its download has started.
    /// It shows as updating until it reports another release.
    func sendUpdateApp(_ machineID: String) async -> String? {
        let name = machine(id: machineID)?.name ?? "That Mac"
        guard let connection = connection(for: machineID) else {
            return ClientError.machineNotConnected(name).localizedDescription
        }
        busyMachineIDs.insert(machineID)
        defer { busyMachineIDs.remove(machineID) }
        do {
            _ = try await connection.call(UpdateApp())
            appUpdatesSent[machineID] = (machine(id: machineID)?.appVersion, Date())
            return nil
        } catch let error as ProtocolError where error.code == .unknownMethod {
            return "Update Woven Matter on \(name) itself this once. After that, it can be updated from here."
        } catch {
            return error.localizedDescription
        }
    }

    /// Another Mac told to update, with the release it ran then, until it reports another.
    @ObservationIgnored private var appUpdatesSent: [String: (version: String?, at: Date)] = [:]

    /// Whether another Mac is updating its Woven Matter at this Mac's request.
    func isUpdatingApp(_ machineID: String) -> Bool {
        if isBusy(machineID) { return true }
        guard let sent = appUpdatesSent[machineID] else { return false }
        if machine(id: machineID)?.appVersion != sent.version || Date().timeIntervalSince(sent.at) > 15 * 60 {
            appUpdatesSent[machineID] = nil
            return false
        }
        return true
    }

    /// Reads the end of the server's log, from its own server while the UI is
    /// connected to it, else over SSH through this Mac's server.
    func loadLogs(on machineID: String) {
        serverErrors[machineID] = nil
        guard let connection = connection(for: machineID) ?? server.flatMap({ $0.isConnected ? $0 : nil }) else {
            return serverErrors[machineID] = ClientError.notConnected.localizedDescription
        }
        Task {
            do {
                serverLogs[machineID] = try await connection.call(ServerLog(machineID: machineID))
            } catch {
                serverErrors[machineID] = error.localizedDescription
            }
        }
    }

    // MARK: Linux machines to add

    /// Lists the tailnet's Linux machines without a Woven server, through this Mac's server.
    func findMachines() {
        guard !isFindingMachines else { return }
        guard let server else { return findMachinesError = ClientError.notConnected.localizedDescription }
        isFindingMachines = true
        Task {
            defer {
                isFindingMachines = false
                hasSearchedMachines = true
            }
            do {
                tailnetMachines = try await server.call(FindMachines()).filter { $0.platform == .linux }.map { machine in
                    MachineToAdd(id: machine.name, name: machine.name, hostName: machine.name, address: machine.address)
                }
                findMachinesError = nil
            } catch {
                findMachinesError = error.localizedDescription
            }
        }
    }

    /// Looks at a Linux machine over SSH, through this Mac's server. Changes nothing.
    func inspectMachine(hostName: String, userName: String?) {
        guard let server else { return machineErrors[hostName] = ClientError.notConnected.localizedDescription }
        guard !inspectingHostnames.contains(hostName) else { return }
        inspectingHostnames.insert(hostName)
        machineErrors[hostName] = nil
        Task {
            defer { inspectingHostnames.remove(hostName) }
            do {
                let facts = try await server.call(InspectMachine(host: hostName, user: userName))
                machinePreflights[hostName] = MachinePreflight(hostName: hostName, ready: facts.problems.isEmpty,
                                                        architecture: facts.architecture, limitations: facts.problems,
                                                        storageCapacityBytes: facts.storageCapacityBytes,
                                                        storageAvailableBytes: facts.storageAvailableBytes)
            } catch {
                machinePreflights[hostName] = nil
                machineErrors[hostName] = error.localizedDescription
            }
        }
    }

    /// Installs and starts the server there over SSH, through this Mac's server,
    /// following its stages. It is opened once: opening it again after a reconnect
    /// would start a second install. If the connection drops first, the install
    /// goes on there and the machine joins on its own.
    func installServer(hostName: String, userName: String?) {
        guard let server else { return machineErrors[hostName] = ClientError.notConnected.localizedDescription }
        guard !installingHostnames.contains(hostName) else { return }
        installingHostnames.insert(hostName)
        installStages[hostName] = nil
        machineErrors[hostName] = nil
        Task {
            var machineID: String?
            var failure: String?
            do {
                try await server.once(InstallServer(host: hostName, user: userName)) { event in
                    switch event {
                    case .stage(let stage): installStages[hostName] = stage
                    case .finished(let id): machineID = id
                    case .failed(let message): failure = message
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            if let machineID {
                // The page keeps its progress until the new machine is listed, then opens it.
                await reload()
                tailnetMachines.removeAll { $0.hostName == hostName }
                machinePreflights[hostName] = nil
                if connection(for: machineID) == nil { markJoining(machineID, host: hostName) }
                pendingHarnessSetupMachineIDs.insert(machineID)
                finishedInstalls[hostName] = machineID
            } else if let failure {
                joiningMachineIDs = joiningMachineIDs.filter { $0.value.host != hostName }
                machineErrors[hostName] = failure
            } else {
                machineErrors[hostName] = "The connection to this Mac's server was lost. The install continues on \(hostName)."
                await reload()
            }
            installingHostnames.remove(hostName)
            installStages[hostName] = nil
        }
    }

    // MARK: Power

    /// This Mac's idle-sleep policy, a setting its server carries out.
    func loadIdleSleepPolicy() async {
        guard let server, server.isConnected, let thisID = thisMachine?.id else { return }
        let key = IdleSleepPolicy.settingKey(machineID: thisID)
        do {
            let value = try await server.call(ListSettings()).first { $0.key == key }?.value
            idleSleepPolicy = (try? value?.decode(IdleSleepPolicy.self)) ?? IdleSleepPolicy()
        } catch {
            idleSleepError = error.localizedDescription
        }
    }

    func setIdleSleepPolicy(_ policy: IdleSleepPolicy) async {
        guard let server, server.isConnected, let thisID = thisMachine?.id else {
            return idleSleepError = ClientError.notConnected.localizedDescription
        }
        isChangingIdleSleepPolicy = true
        defer { isChangingIdleSleepPolicy = false }
        do {
            _ = try await server.call(SetSetting(key: IdleSleepPolicy.settingKey(machineID: thisID), value: WovenProtocol.JSONValue(encoding: policy)))
            idleSleepPolicy = policy
            idleSleepError = nil
        } catch {
            idleSleepError = error.localizedDescription
        }
    }
}
