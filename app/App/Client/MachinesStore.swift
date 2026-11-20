import Foundation
import Observation
import WovenProtocol

/// Every Woven machine on the tailnet, this Mac first: whether it is online,
/// what it can run, its harness inventory and sign-ins, its Mac permission
/// status and its server. Commands rename and remove machines, find devices
/// and install the server over SSH, and install or update harnesses.
///
/// Per-machine state is keyed by machine id. Harness and sign-in members are in
/// `MachinesStore+Harnesses.swift`, OpenCode's in `MachinesStore+OpenCode.swift`.
@MainActor
@Observable
final class MachinesStore {
    /// Every machine in the library as this Mac's server reports it.
    private var statuses: [MachineStatus] = []
    /// The runtimes this Mac's server has, as it last reported them.
    var runtimes: [RuntimeStatus] = []
    @ObservationIgnored weak var server: ServerConnection?

    /// This machine first, then the others by name. This Mac is online while
    /// the UI is connected to its server.
    var machines: [Machine] {
        let connected = server?.isConnected == true
        return statuses.map { status in
            Machine(id: status.machine.id, name: status.machine.name,
                    platform: status.machine.platform == .linux ? .linux : .mac,
                    isThisMachine: status.isThisMachine,
                    isOnline: status.isThisMachine ? connected : connected && status.online,
                    appVersion: status.appVersion,
                    runtimes: status.isThisMachine
                        ? runtimes.filter(\.installed).compactMap { AgentRuntimeKind(runtime: $0.runtime) } : [])
        }.sorted { ($0.isThisMachine ? 0 : 1, $0.name.localizedLowercase, $0.id)
            < ($1.isThisMachine ? 0 : 1, $1.name.localizedLowercase, $1.id) }
    }

    /// Each machine's runtimes, as the sidebar lists them under its Agents.
    var agents: [WorkspaceAgent] {
        machines.flatMap { machine in
            machine.runtimes.map { kind in
                let signedIn = runtimes.first { AgentRuntimeKind(runtime: $0.runtime) == kind }?.signedIn
                return WorkspaceAgent(id: WorkspaceAgent.id(machineID: machine.id, runtime: kind), displayName: kind.displayName,
                                      iconKey: kind.rawValue, runtimeKind: kind, machineID: machine.id,
                                      status: !machine.isOnline ? .offline : signedIn == false ? .needsAuthentication : .ready)
            }
        }
    }

    func attach(_ server: ServerConnection) {
        self.server = server
    }

    /// Reads the machines and this Mac's runtimes again.
    func reload() async {
        guard let server else { return }
        do {
            statuses = try await server.call(ListMachines())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        // Each runtime's status runs its CLI, so library changes do not read
        // them again; Settings and installs do (`refreshHarnesses`).
        if !hasReadRuntimes { await readRuntimes(checkForUpdates: false) }
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
    var hasReadRuntimes = false
    @ObservationIgnored var runtimeRead: Task<Void, Never>?

    var signInStatuses: [String: [AgentRuntimeKind: AgentSignInStatus]] = [:]
    /// Pi Durable's provider accounts on each machine.
    var providerSignInStatuses: [String: [AgentSignInStatus]] = [:]
    var checkingSignIns: [String: Set<AgentRuntimeKind>] = [:]
    var openingSignIns: [String: Set<AgentRuntimeKind>] = [:]
    var removingSignIns: [String: Set<AgentRuntimeKind>] = [:]
    var signInMessages: [String: [AgentRuntimeKind: String]] = [:]
    var signInSessions: [String: [AgentRuntimeKind: HarnessSignInSession]] = [:]

    // MARK: OpenCode (see MachinesStore+OpenCode.swift)

    var openCodeServers: [String: OpenCodeServer] = [:]
    var openCodeErrors: [String: String] = [:]

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

    /// A machine is renamed by its own server.
    func rename(_ machineID: String, to name: String) async throws {
        guard let server, machineID == thisMachine?.id else { throw ClientError.notConnected }
        _ = try await server.call(RenameMachine(name: name))
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

    func serverStatus(on machineID: String) -> MachineServerStatus? { serverStatuses[machineID] }
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

    func updateServer(on machineID: String) {
        errorMessage = ClientError.notConnected.localizedDescription
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

    func findDevices() {
        hasSearchedDevices = true
        findDevicesError = ClientError.notConnected.localizedDescription
    }

    /// Inspects a tailnet computer over SSH: for a Mac, whether Woven Matter is
    /// installed; for Linux, whether the server can be installed there.
    func inspectHost(hostName: String, userName: String?, accessMode: LinuxAccessMode?) {
        hostErrors[hostName] = ClientError.notConnected.localizedDescription
    }

    func prepareHost(hostName: String, userName: String?, accessMode: LinuxAccessMode) {
        hostErrors[hostName] = ClientError.notConnected.localizedDescription
    }

    func authorizeHostPreparation() {
        pendingHostPreparation = nil
    }

    func cancelHostPreparation() {
        pendingHostPreparation = nil
    }

    /// Installs and starts the server there over SSH. The machine then joins on its own.
    func installServer(hostName: String, userName: String?, accessMode: LinuxAccessMode?) {
        hostErrors[hostName] = ClientError.notConnected.localizedDescription
    }

    // MARK: Power

    func setIdleSleepPolicy(_ policy: WorkPowerPolicy) async {
        idleSleepError = ClientError.notConnected.localizedDescription
    }

    func setClosedLidPolicy(_ policy: WorkPowerPolicy) async {
        closedLidError = ClientError.notConnected.localizedDescription
    }
}
