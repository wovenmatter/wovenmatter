import Foundation
import WovenProtocol

/// Harness installs, updates and sign-ins on each machine. The machine's server runs
/// the harness's own commands; the UI never starts a harness process. Only this Mac's
/// server is connected, so other machines report nothing here yet.
extension MachinesStore {
    // MARK: Inventory

    func harness(_ kind: AgentRuntimeKind, on machineID: String) -> HarnessInstallation? {
        harnessInstallations[machineID]?[kind]
    }

    /// Every harness the machine reported, in presentation order.
    func harnesses(on machineID: String) -> [HarnessInstallation] {
        (harnessInstallations[machineID] ?? [:]).values.sorted {
            $0.runtimeKind.presentationRank < $1.runtimeKind.presentationRank
        }
    }

    func isCheckingHarness(_ kind: AgentRuntimeKind, on machineID: String) -> Bool {
        checkingHarnesses[machineID]?.contains(kind) == true
    }

    func isCheckingHarnesses(on machineID: String) -> Bool {
        checkingHarnesses[machineID]?.isEmpty == false
    }

    func operation(_ kind: AgentRuntimeKind, on machineID: String) -> HarnessOperation? {
        harnessOperations[machineID]?[kind]
    }

    func isMaintaining(_ kind: AgentRuntimeKind, on machineID: String) -> Bool {
        operation(kind, on: machineID) != nil || pendingHarnessInstall?.machineID == machineID
            && pendingHarnessInstall?.runtimeKind == kind
    }

    /// Installs or updates run there; server changes wait for them.
    func isMaintainingHarnesses(on machineID: String) -> Bool {
        harnessOperations[machineID]?.isEmpty == false
    }

    func harnessError(_ kind: AgentRuntimeKind, on machineID: String) -> String? {
        harnessErrors[machineID]?[kind]
    }

    func hasActiveChats(on machineID: String) -> Bool { machinesWithActiveChats.contains(machineID) }

    /// Re-reads what is installed and signed in there, Pi Durable's providers included.
    func refreshHarnesses(on machineID: String) {
        guard isThisMachine(machineID) else { return markUnavailable(machineID) }
        Task { await readRuntimes(checkForUpdates: false) }
        Task { await refreshProviderSignIns(on: machineID) }
    }

    /// Looks up the newest release of every harness there.
    func checkForUpdates(_ kind: AgentRuntimeKind, on machineID: String) {
        guard isThisMachine(machineID) else { return markUnavailable(machineID) }
        Task { await checkAllHarnesses(on: machineID, showing: [kind]) }
    }

    /// Looks up the newest release of every harness there; `showing` are the ones marked as checking.
    func checkAllHarnesses(on machineID: String, showing kinds: [AgentRuntimeKind]? = nil) async {
        guard isThisMachine(machineID) else { return markUnavailable(machineID) }
        let marked = Set(kinds ?? AgentRuntimeKind.allCases)
        checkingHarnesses[machineID, default: []].formUnion(marked)
        await readRuntimes(checkForUpdates: true)
        checkingHarnesses[machineID]?.subtract(marked)
    }

    func install(_ kind: AgentRuntimeKind, on machineID: String) {
        Task { await maintain(kind, .install, on: machineID) }
    }

    func update(_ kind: AgentRuntimeKind, on machineID: String) {
        Task { await maintain(kind, .update, on: machineID) }
    }

    /// Installs each harness in order on that machine's server.
    func installHarnesses(_ kinds: [AgentRuntimeKind], on machineID: String) {
        Task {
            for kind in kinds where harness(kind, on: machineID)?.isInstalled != true {
                await maintain(kind, .install, on: machineID)
            }
        }
    }

    func confirmPendingHarnessInstall() {
        pendingHarnessInstall = nil
    }

    func cancelPendingHarnessInstall() {
        pendingHarnessInstall = nil
    }

    func dismissHarnessSetup(_ machineID: String) {
        pendingHarnessSetupMachineIDs.remove(machineID)
    }

    /// Installs or updates a harness to its latest release with the server's `InstallRuntime`.
    func maintain(_ kind: AgentRuntimeKind, _ operation: HarnessOperation, on machineID: String) async {
        guard let server, isThisMachine(machineID) else {
            harnessErrors[machineID, default: [:]][kind] = ClientError.machineNotConnected(machine(id: machineID)?.name ?? "That machine")
                .localizedDescription
            return
        }
        guard harnessOperations[machineID]?[kind] == nil else { return }
        harnessOperations[machineID, default: [:]][kind] = operation
        harnessErrors[machineID]?[kind] = nil
        defer { harnessOperations[machineID]?[kind] = nil }
        do {
            let status = try await server.call(InstallRuntime(runtime: kind.runtime))
            harnessFailures[machineID]?[kind] = nil
            // The installed release is the newest one now.
            if let version = status.version { latestVersions[machineID, default: [:]][kind] = .some(version) }
            runtimes.removeAll { $0.runtime == status.runtime }
            runtimes.append(status)
            applyRuntimes(on: machineID)
        } catch {
            harnessFailures[machineID, default: [:]][kind, default: 0] += 1
            harnessErrors[machineID, default: [:]][kind] = error.localizedDescription
            applyRuntimes(on: machineID)
        }
    }

    /// Reads this Mac's runtimes; one read at a time, and callers during one wait for it.
    func readRuntimes(checkForUpdates: Bool) async {
        if let running = runtimeRead, !checkForUpdates { return await running.value }
        let previous = runtimeRead
        let read = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let server = self.server else { return }
            do {
                let statuses = try await server.call(ListRuntimes(checkForUpdates: checkForUpdates))
                self.runtimes = statuses
                self.hasReadRuntimes = true
                guard let thisID = self.thisMachine?.id else { return }
                self.harnessInventoryUnavailable.remove(thisID)
                if checkForUpdates {
                    for status in statuses {
                        guard let kind = AgentRuntimeKind(runtime: status.runtime) else { continue }
                        self.latestVersions[thisID, default: [:]][kind] = .some(status.latestVersion)
                    }
                }
                self.applyRuntimes(on: thisID)
            } catch {
                if let thisID = self.thisMachine?.id { self.harnessInventoryUnavailable.insert(thisID) }
            }
        }
        runtimeRead = read
        await read.value
        if runtimeRead == read { runtimeRead = nil }
    }

    /// Projects the server's runtime statuses into the harness and sign-in rows of this Mac.
    func applyRuntimes(on machineID: String) {
        var installations: [AgentRuntimeKind: HarnessInstallation] = [:]
        var signIns: [AgentRuntimeKind: AgentSignInStatus] = [:]
        for status in runtimes {
            guard let kind = AgentRuntimeKind(runtime: status.runtime) else { continue }
            let checked = latestVersions[machineID]?[kind]
            var withLatest = status
            withLatest.latestVersion = checked ?? nil
            let failures = harnessFailures[machineID]?[kind] ?? 0
            let component = HarnessComponent(
                id: kind.rawValue,
                displayName: kind == .defaultAgent ? "Pi Durable SDK" : "\(status.name) CLI",
                installedVersion: status.version,
                updateVersion: withLatest.updateAvailable ? withLatest.latestVersion : nil,
                isInstalled: status.installed,
                isSystemInstall: false)
            let state: HarnessInstallation.State = !status.installed ? (status.version == nil ? .notInstalled : .unavailable)
                : status.signedIn == false && kind != .defaultAgent ? .signInRequired : .ready
            installations[kind] = HarnessInstallation(
                runtimeKind: kind, state: state, components: [component], isInstalled: status.installed,
                isSystemInstall: false, path: nil,
                versionCheckAvailable: checked.map { $0 != nil } ?? true,
                failureCount: failures,
                diagnostic: failures > 0 ? harnessErrors[machineID]?[kind] : nil)
            guard kind != .defaultAgent else { continue }
            let signInState: AgentSignInStatus.State = !status.installed ? .notInstalled
                : status.signedIn == true ? .verified : status.signedIn == false ? .signInRequired : .notChecked
            signIns[kind] = AgentSignInStatus(id: kind.rawValue, name: status.name, state: signInState,
                                              detail: status.detail ?? "")
            signInMessages[machineID]?[kind] = nil
        }
        harnessInstallations[machineID] = installations
        signInStatuses[machineID] = signIns
    }

    private func isThisMachine(_ machineID: String) -> Bool { machineID == thisMachine?.id }

    /// Another machine's server is not connected, so its inventory cannot be read.
    private func markUnavailable(_ machineID: String) {
        harnessInventoryUnavailable.insert(machineID)
    }

    // MARK: Sign-in

    func signInStatus(_ kind: AgentRuntimeKind, on machineID: String) -> AgentSignInStatus? {
        signInStatuses[machineID]?[kind]
    }

    func providerSignIns(on machineID: String) -> [AgentSignInStatus] {
        providerSignInStatuses[machineID] ?? []
    }

    /// Re-reads Pi Durable's providers on this Mac, for the Agents page's summary.
    func refreshProviderSignIns(on machineID: String) async {
        guard let server, isThisMachine(machineID), let list = try? await server.call(ListSignIns()) else { return }
        providerSignInStatuses[machineID] = list.map {
            AgentSignInStatus(id: $0.provider, name: $0.name, state: $0.connected ? .credentialsPresent : .signInRequired, detail: "")
        }
    }

    func signInSession(_ kind: AgentRuntimeKind, on machineID: String) -> HarnessSignInSession? {
        signInSessions[machineID]?[kind]
    }

    func signInMessage(_ kind: AgentRuntimeKind, on machineID: String) -> String? {
        signInMessages[machineID]?[kind]
    }

    func isCheckingSignIn(_ kind: AgentRuntimeKind, on machineID: String) -> Bool {
        checkingSignIns[machineID]?.contains(kind) == true
    }

    func isOpeningSignIn(_ kind: AgentRuntimeKind, on machineID: String) -> Bool {
        openingSignIns[machineID]?.contains(kind) == true
    }

    func isRemovingSignIn(_ kind: AgentRuntimeKind, on machineID: String) -> Bool {
        removingSignIns[machineID]?.contains(kind) == true
    }

    /// Sign-in, sign-out or an install holds the account controls.
    func isSignInBusy(_ kind: AgentRuntimeKind, on machineID: String) -> Bool {
        isMaintaining(kind, on: machineID) || isOpeningSignIn(kind, on: machineID)
            || isRemovingSignIn(kind, on: machineID) || signInSession(kind, on: machineID)?.isActive == true
    }

    /// Re-reads whether the harness's CLI reports a sign-in there.
    func refreshSignIn(_ kind: AgentRuntimeKind, on machineID: String) async {
        guard isThisMachine(machineID) else { return markUnavailable(machineID) }
        checkingSignIns[machineID, default: []].insert(kind)
        await readRuntimes(checkForUpdates: false)
        checkingSignIns[machineID]?.remove(kind)
    }

    /// Starts the harness's own sign-in there. A key method passes `key`.
    func startSignIn(_ kind: AgentRuntimeKind, method: HarnessSignInMethod, key: String? = nil, on machineID: String) {
        setSignInMessage(kind, on: machineID)
    }

    /// Sends a code from the sign-in page to the waiting sign-in.
    func submitSignInCode(_ kind: AgentRuntimeKind, code: String, on machineID: String) {
        setSignInMessage(kind, on: machineID)
    }

    func cancelSignIn(_ kind: AgentRuntimeKind, on machineID: String) {
        signInSessions[machineID]?[kind] = nil
    }

    func dismissSignIn(_ kind: AgentRuntimeKind, on machineID: String) {
        if signInSession(kind, on: machineID)?.isActive == false { signInSessions[machineID]?[kind] = nil }
    }

    /// Signs the harness out there with its own logout command.
    func signOut(_ kind: AgentRuntimeKind, on machineID: String) async {
        setSignInMessage(kind, on: machineID)
    }

    /// Removes one saved OpenCode key.
    func removeCredential(_ account: AgentSignInStatus.Account, _ kind: AgentRuntimeKind, on machineID: String) async {
        setSignInMessage(kind, on: machineID)
    }

    /// OpenCode only: its own interactive sign-in, in Terminal on that Mac.
    func openTerminalSignIn(_ kind: AgentRuntimeKind, on machineID: String) {
        setSignInMessage(kind, on: machineID)
    }

    /// The server runs no harness sign-in or sign-out commands yet.
    private func setSignInMessage(_ kind: AgentRuntimeKind, on machineID: String) {
        signInMessages[machineID, default: [:]][kind] = ClientError.notOffered("Signing in to \(kind.displayName) from Woven Matter")
            .localizedDescription
    }
}
