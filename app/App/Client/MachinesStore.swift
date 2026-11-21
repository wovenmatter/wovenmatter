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

    /// This machine first, then the others by name. This Mac is online while
    /// the UI is connected to its server, another machine while the UI's
    /// direct connection to its server is connected.
    var machines: [Machine] {
        statuses.map { status in
            let connection = status.isThisMachine ? server : connections?.remotes[status.machine.id]
            let runtimes = machineRuntimes[status.machine.id] ?? []
            return Machine(id: status.machine.id, name: status.machine.name,
                           platform: status.machine.platform == .linux ? .linux : .mac,
                           isThisMachine: status.isThisMachine,
                           isOnline: connection?.isConnected == true,
                           appVersion: (status.isThisMachine ? nil : connection?.remote?.appVersion) ?? status.appVersion,
                           runtimes: runtimes.filter(\.installed).compactMap { AgentRuntimeKind(runtime: $0.runtime) })
        }.sorted { ($0.isThisMachine ? 0 : 1, $0.name.localizedLowercase, $0.id)
            < ($1.isThisMachine ? 0 : 1, $1.name.localizedLowercase, $1.id) }
    }

    /// Each machine's runtimes, as the sidebar lists them under its Agents.
    var agents: [WorkspaceAgent] {
        machines.flatMap { machine in
            machine.runtimes.map { kind in
                let signedIn = machineRuntimes[machine.id]?.first { AgentRuntimeKind(runtime: $0.runtime) == kind }?.signedIn
                return WorkspaceAgent(id: WorkspaceAgent.id(machineID: machine.id, runtime: kind), displayName: kind.displayName,
                                      iconKey: kind.rawValue, runtimeKind: kind, machineID: machine.id,
                                      status: !machine.isOnline ? .offline : signedIn == false ? .needsAuthentication : .ready)
            }
        }
    }

    func attach(_ connections: MachineConnections) {
        self.connections = connections
        connections.whenChanged { [weak self] in self?.connectionsChanged() }
    }

    /// The connection to `machineID`'s server, when the UI is connected to it now.
    func connection(for machineID: String?) -> ServerConnection? {
        guard let connection = connections?.connection(for: machineID), connection.isConnected else { return nil }
        return connection
    }

    /// Reads a machine's runtimes each time the UI connects to its server,
    /// this Mac's too (after its server restarts, for one).
    private func connectionsChanged() {
        guard let connections else { return }
        var connected = Set(connections.remotes.filter { $0.value.isConnected }.map(\.key))
        if connections.local.isConnected, let thisID = connections.thisMachineID { connected.insert(thisID) }
        for machineID in connected.subtracting(connectedMachineIDs) {
            Task { await readRuntimes(on: machineID, checkForUpdates: false) }
        }
        connectedMachineIDs = connected
    }

    /// Reads the machines and this Mac's runtimes again.
    func reload() async {
        guard let server else { return }
        do {
            statuses = try await server.call(ListMachines())
            connections?.update(statuses)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        // Each runtime's status runs its CLI, so library changes do not read
        // them again; Settings and installs do (`refreshHarnesses`).
        if !hasReadRuntimes, let thisID = thisMachine?.id { await readRuntimes(on: thisID, checkForUpdates: false) }
    }

    // MARK: Server on each machine

    /// Machines whose server this UI stopped, until it starts again.
    private var stoppedMachineIDs: Set<String> = []
    /// Machines whose server is starting, stopping, updating or being removed.
    private(set) var busyMachineIDs: Set<String> = []
    private(set) var serverLogs: [String: String] = [:]
    /// Progress of the current install or server change, for the page that started it.
    private(set) var progress: String?
    var errorMessage: String?

    // MARK: Linux machines to add

    /// Tailnet machines without a Woven server.
    private(set) var tailnetMachines: [MachineToAdd] = []
    private(set) var isFindingMachines = false
    private(set) var hasSearchedMachines = false
    private(set) var findMachinesError: String?
    private(set) var machinePreflights: [String: MachinePreflight] = [:]
    private(set) var inspectingHostnames: Set<String> = []
    private(set) var installingHostnames: Set<String> = []
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
        return machine.isOnline && machine.canRun(runtime)
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
        guard let server else { return errorMessage = ClientError.notConnected.localizedDescription }
        Task {
            do {
                _ = try await server.call(RemoveMachine(machineID: machineID))
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Server

    /// Its server is running while the UI is connected to it. This Mac's is
    /// otherwise stopped; another machine's is stopped once this UI stopped it.
    func serverStatus(on machineID: String) -> MachineServerStatus? {
        guard let machine = machine(id: machineID) else { return nil }
        let state: MachineServerStatus.State = machine.isOnline ? .running
            : machine.isThisMachine || stoppedMachineIDs.contains(machineID) ? .stopped : .unavailable
        return MachineServerStatus(state: state, hostName: statuses.first { $0.machine.id == machineID }?.address)
    }
    func isBusy(_ machineID: String) -> Bool { busyMachineIDs.contains(machineID) }

    /// This Mac's server through launchd; a Linux machine's over SSH, through
    /// this Mac's server. Returns once the UI is connected to it.
    func startServer(on machineID: String) async throws {
        busyMachineIDs.insert(machineID)
        defer { busyMachineIDs.remove(machineID) }
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
        guard let server else { return ClientError.notConnected.localizedDescription }
        busyMachineIDs.insert(machineID)
        defer { busyMachineIDs.remove(machineID) }
        do {
            _ = try await server.call(UpdateServer(machineID: machineID))
            await reload()
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    /// Reads the end of the server's log, from its own server while the UI is
    /// connected to it, else over SSH through this Mac's server.
    func loadLogs(on machineID: String) {
        guard let connection = connection(for: machineID) ?? server.flatMap({ $0.isConnected ? $0 : nil }) else {
            return errorMessage = ClientError.notConnected.localizedDescription
        }
        Task {
            do {
                serverLogs[machineID] = try await connection.call(ServerLog(machineID: machineID))
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
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
    /// which replies once the new server answers. The machine then joins on its own.
    func installServer(hostName: String, userName: String?) {
        guard let server else { return machineErrors[hostName] = ClientError.notConnected.localizedDescription }
        guard !installingHostnames.contains(hostName) else { return }
        installingHostnames.insert(hostName)
        machineErrors[hostName] = nil
        let known = Set(machines.map(\.id))
        Task {
            defer { installingHostnames.remove(hostName) }
            do {
                _ = try await server.call(InstallServer(host: hostName, user: userName))
                tailnetMachines.removeAll { $0.hostName == hostName }
                machinePreflights[hostName] = nil
                await reload()
                pendingHarnessSetupMachineIDs.formUnion(Set(machines.map(\.id)).subtracting(known))
            } catch {
                machineErrors[hostName] = error.localizedDescription
            }
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
