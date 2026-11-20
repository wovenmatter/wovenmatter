import Foundation
import Observation
import WovenProtocol

/// Every Woven machine on the tailnet, this Mac first: whether it is online,
/// what it can run, its harness inventory and sign-ins, its Mac permission
/// status and its server. Commands rename and remove machines, find devices
/// and install the server over SSH, and install or update harnesses.
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

    /// Reads a machine's runtimes each time the UI connects to its server.
    private func connectionsChanged() {
        guard let connections else { return }
        let connected = Set(connections.remotes.filter { $0.value.isConnected }.map(\.key))
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

    private(set) var serverStatuses: [String: MachineServerStatus] = [:]
    /// Machines whose server is starting, stopping, updating or being removed.
    private(set) var busyMachineIDs: Set<String> = []
    private(set) var serverLogs: [String: String] = [:]
    private(set) var browserChecks: [String: BrowserSandboxCheck] = [:]
    private(set) var inspections: [String: RuntimeInspection] = [:]
    private(set) var inspectionErrors: [String: String] = [:]
    /// Progress of the current install or server change, for the page that started it.
    private(set) var progress: String?
    var errorMessage: String?

    // MARK: Find Devices

    /// Tailnet computers without a Woven server.
    private(set) var tailnetDevices: [TailnetDevice] = []
    private(set) var isFindingDevices = false
    private(set) var hasSearchedDevices = false
    private(set) var findDevicesError: String?
    private(set) var hostPreflights: [String: HostPreflight] = [:]
    private(set) var inspectingHosts: Set<String> = []
    private(set) var installingHosts: Set<String> = []
    private(set) var hostMessages: [String: String] = [:]
    var hostErrors: [String: String] = [:]
    /// Preparation that downloads packages waits for the person to authorize it.
    private(set) var pendingHostPreparation: HostPreflight?

    // MARK: This Mac's power policy

    private(set) var power = MachinePower()
    private(set) var isChangingIdleSleepPolicy = false
    private(set) var isChangingClosedLidPolicy = false
    var idleSleepError: String?
    var closedLidError: String?

    // MARK: Harnesses (see MachinesStore+Harnesses.swift)

    var harnessInstallations: [String: [AgentRuntimeKind: HarnessInstallation]] = [:]
    var checkingHarnesses: [String: Set<AgentRuntimeKind>] = [:]
    var harnessOperations: [String: [AgentRuntimeKind: HarnessOperation]] = [:]
    var harnessErrors: [String: [AgentRuntimeKind: String]] = [:]
    /// Machines whose harness inventory could not be read.
    var harnessInventoryUnavailable: Set<String> = []
    /// Machines where running chats hold harness installs and updates.
    var machinesWithActiveChats: Set<String> = []
    var pendingHarnessInstall: PendingHarnessInstall?
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

    // MARK: Used by settings

    /// Each Mac's permission status, as its server reports it.
    private(set) var macAccessStatuses: [String: MacAccessStatus] = [:]

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

    /// Its server is running while the UI is connected to it.
    func serverStatus(on machineID: String) -> MachineServerStatus? {
        if let status = serverStatuses[machineID] { return status }
        guard let machine = machine(id: machineID) else { return nil }
        return MachineServerStatus(state: machine.isOnline ? .running : .unavailable,
                                   hostName: statuses.first { $0.machine.id == machineID }?.address)
    }
    func isBusy(_ machineID: String) -> Bool { busyMachineIDs.contains(machineID) }

    func startServer(on machineID: String) async throws {
        throw ClientError.notConnected
    }

    func stopServer(on machineID: String, confirmed: Bool) async throws -> ServerStopResult {
        throw ClientError.notConnected
    }

    func restartServer(on machineID: String) {
        errorMessage = ClientError.notConnected.localizedDescription
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

    func loadLogs(on machineID: String) {
        errorMessage = ClientError.notConnected.localizedDescription
    }

    func checkBrowserSandbox(on machineID: String) {
        errorMessage = ClientError.notConnected.localizedDescription
    }

    /// Asks the machine's server to report its processes; `inspections` updates.
    func refreshInspection(on machineID: String) {
        inspectionErrors[machineID] = ClientError.notConnected.localizedDescription
    }

    // MARK: Find Devices

    /// Lists tailnet computers without a Woven server, through this Mac's server.
    func findDevices() {
        guard !isFindingDevices else { return }
        guard let server else { return findDevicesError = ClientError.notConnected.localizedDescription }
        isFindingDevices = true
        Task {
            defer {
                isFindingDevices = false
                hasSearchedDevices = true
            }
            do {
                tailnetDevices = try await server.call(FindDevices()).compactMap { device in
                    guard let platform = device.platform else { return nil }
                    return TailnetDevice(id: device.name, name: device.name, hostName: device.name, address: device.address,
                                         platform: platform == .linux ? .linux : .mac, isOnline: true)
                }
                findDevicesError = nil
            } catch {
                findDevicesError = error.localizedDescription
            }
        }
    }

    /// Before installing on a Linux computer Find Devices listed, it is taken as
    /// ready; installing checks it over SSH.
    func inspectHost(hostName: String, userName: String?, accessMode: LinuxAccessMode?) {
        let platform = tailnetDevices.first { $0.hostName == hostName }?.platform ?? .linux
        guard platform == .linux else {
            return hostErrors[hostName] = ClientError.notOffered("Checking another Mac").localizedDescription
        }
        hostErrors[hostName] = nil
        hostPreflights[hostName] = HostPreflight(hostName: hostName, ready: true, architecture: platform.displayName,
                                                 canPrepare: false)
    }

    func prepareHost(hostName: String, userName: String?, accessMode: LinuxAccessMode) {
        hostErrors[hostName] = ClientError.notOffered("Preparing a host").localizedDescription
    }

    func authorizeHostPreparation() {
        pendingHostPreparation = nil
    }

    func cancelHostPreparation() {
        pendingHostPreparation = nil
    }

    /// Installs and starts the server there over SSH, through this Mac's server,
    /// which replies once the new server answers. The machine then joins on its own.
    func installServer(hostName: String, userName: String?, accessMode: LinuxAccessMode?) {
        guard let server else { return hostErrors[hostName] = ClientError.notConnected.localizedDescription }
        guard !installingHosts.contains(hostName) else { return }
        installingHosts.insert(hostName)
        hostErrors[hostName] = nil
        let known = Set(machines.map(\.id))
        Task {
            defer { installingHosts.remove(hostName) }
            do {
                _ = try await server.call(InstallServer(host: hostName, user: userName))
                tailnetDevices.removeAll { $0.hostName == hostName }
                hostPreflights[hostName] = nil
                await reload()
                pendingHarnessSetupMachineIDs.formUnion(Set(machines.map(\.id)).subtracting(known))
            } catch {
                hostErrors[hostName] = error.localizedDescription
            }
        }
    }

    // MARK: Power

    func setIdleSleepPolicy(_ policy: WorkPowerPolicy) async {
        idleSleepError = ClientError.notConnected.localizedDescription
    }

    func setClosedLidPolicy(_ policy: WorkPowerPolicy) async {
        closedLidError = ClientError.notConnected.localizedDescription
    }
}
