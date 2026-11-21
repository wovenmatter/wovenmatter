#if os(macOS)
import AppKit
#endif
import Foundation
import WovenProtocol

/// Harness installs, updates and sign-ins on each machine. The machine's server runs
/// the harness's own commands; the UI never starts a harness process. Each machine's
/// harnesses are read and installed over the UI's connection to its own server.
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
        operation(kind, on: machineID) != nil
    }

    /// Installs or updates run there; server changes wait for them.
    func isMaintainingHarnesses(on machineID: String) -> Bool {
        harnessOperations[machineID]?.isEmpty == false
    }

    func harnessError(_ kind: AgentRuntimeKind, on machineID: String) -> String? {
        harnessErrors[machineID]?[kind]
    }

    /// Re-reads what is installed and signed in there, Pi Durable's providers included.
    func refreshHarnesses(on machineID: String) {
        guard connection(for: machineID) != nil else { return markUnavailable(machineID) }
        Task { await readRuntimes(on: machineID, checkForUpdates: false) }
        Task { await refreshProviderSignIns(on: machineID) }
    }

    /// Looks up the newest release of every harness there.
    func checkForUpdates(_ kind: AgentRuntimeKind, on machineID: String) {
        guard connection(for: machineID) != nil else { return markUnavailable(machineID) }
        Task { await checkAllHarnesses(on: machineID, showing: [kind]) }
    }

    /// Looks up the newest release of every harness there; `showing` are the ones marked as checking.
    func checkAllHarnesses(on machineID: String, showing kinds: [AgentRuntimeKind]? = nil) async {
        guard connection(for: machineID) != nil else { return markUnavailable(machineID) }
        let marked = Set(kinds ?? AgentRuntimeKind.allCases)
        checkingHarnesses[machineID, default: []].formUnion(marked)
        await readRuntimes(on: machineID, checkForUpdates: true)
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

    func dismissHarnessSetup(_ machineID: String) {
        pendingHarnessSetupMachineIDs.remove(machineID)
    }

    /// Installs or updates a harness to its latest release with the server's `InstallRuntime`.
    func maintain(_ kind: AgentRuntimeKind, _ operation: HarnessOperation, on machineID: String) async {
        guard let server = connection(for: machineID) else {
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
            machineRuntimes[machineID, default: []].removeAll { $0.runtime == status.runtime }
            machineRuntimes[machineID, default: []].append(status)
            applyRuntimes(on: machineID)
        } catch {
            harnessFailures[machineID, default: [:]][kind, default: 0] += 1
            harnessErrors[machineID, default: [:]][kind] = error.localizedDescription
            applyRuntimes(on: machineID)
        }
    }

    /// Reads a machine's runtimes from its own server; one read at a time per
    /// machine, and callers during one wait for it.
    func readRuntimes(on machineID: String, checkForUpdates: Bool) async {
        if let running = runtimeReads[machineID], !checkForUpdates { return await running.value }
        let previous = runtimeReads[machineID]
        let read = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard let server = self.connection(for: machineID) else { return self.markUnavailable(machineID) }
            do {
                let statuses = try await server.call(ListRuntimes(checkForUpdates: checkForUpdates))
                self.machineRuntimes[machineID] = statuses
                self.runtimesRead.insert(machineID)
                self.harnessInventoryUnavailable.remove(machineID)
                if checkForUpdates {
                    for status in statuses {
                        guard let kind = AgentRuntimeKind(runtime: status.runtime) else { continue }
                        self.latestVersions[machineID, default: [:]][kind] = .some(status.latestVersion)
                    }
                }
                self.applyRuntimes(on: machineID)
            } catch {
                self.harnessInventoryUnavailable.insert(machineID)
            }
        }
        runtimeReads[machineID] = read
        await read.value
        if runtimeReads[machineID] == read { runtimeReads[machineID] = nil }
    }

    /// Projects a machine's runtime statuses into its harness and sign-in rows.
    func applyRuntimes(on machineID: String) {
        var installations: [AgentRuntimeKind: HarnessInstallation] = [:]
        var signIns: [AgentRuntimeKind: AgentSignInStatus] = [:]
        for status in machineRuntimes[machineID] ?? [] {
            guard let kind = AgentRuntimeKind(runtime: status.runtime) else { continue }
            let checked = latestVersions[machineID]?[kind]
            var withLatest = status
            withLatest.latestVersion = checked ?? nil
            let failures = harnessFailures[machineID]?[kind] ?? 0
            var components = [HarnessComponent(
                id: kind.rawValue,
                displayName: kind == .defaultAgent ? "Pi Durable SDK" : "\(status.name) CLI",
                installedVersion: status.version,
                updateVersion: withLatest.updateAvailable ? withLatest.latestVersion : nil,
                isInstalled: status.installed,
                isSystemInstall: false)]
            if let adapter = status.adapterInstalled {
                components.append(HarnessComponent(id: kind.rawValue + "-adapter", displayName: "\(status.name) ACP adapter",
                                                   installedVersion: status.adapterVersion, isInstalled: adapter, isSystemInstall: false))
            }
            let state: HarnessInstallation.State = !status.installed ? (status.version == nil ? .notInstalled : .unavailable)
                : !status.isReady ? .notInstalled
                : status.signedIn == false && kind != .defaultAgent ? .signInRequired : .ready
            installations[kind] = HarnessInstallation(
                runtimeKind: kind, state: state, components: components, isInstalled: status.isReady,
                isSystemInstall: false, path: nil,
                versionCheckAvailable: checked.map { $0 != nil } ?? true,
                failureCount: failures,
                diagnostic: failures > 0 ? harnessErrors[machineID]?[kind] : nil)
            guard kind != .defaultAgent else { continue }
            let signInState: AgentSignInStatus.State = !status.installed ? .notInstalled
                : status.signedIn == true ? (kind == .opencode ? .credentialsPresent : .verified)
                : status.signedIn == false ? .signInRequired : .notChecked
            signIns[kind] = AgentSignInStatus(
                id: kind.rawValue, name: status.name, state: signInState, detail: status.detail ?? "",
                accounts: status.accounts.map { .init(method: $0.method, name: $0.name, credential: $0.credential) })
            signInMessages[machineID]?[kind] = nil
        }
        harnessInstallations[machineID] = installations
        signInStatuses[machineID] = signIns
        watchAdapterInstalls(on: machineID)
    }

    /// While the server installs an adapter there, reads that machine's runtimes
    /// again every few seconds, so the harness turns ready without a step.
    private func watchAdapterInstalls(on machineID: String) {
        guard machineRuntimes[machineID]?.contains(where: \.installingAdapter) == true,
              !adapterWatches.contains(machineID) else { return }
        adapterWatches.insert(machineID)
        Task {
            try? await Task.sleep(for: .seconds(3))
            adapterWatches.remove(machineID)
            await readRuntimes(on: machineID, checkForUpdates: false)
        }
    }

    /// That machine's server is not connected, so its inventory cannot be read.
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

    /// Re-reads Pi Durable's providers on that machine, for the Agents page's summary.
    func refreshProviderSignIns(on machineID: String) async {
        guard let server = connection(for: machineID), let list = try? await server.call(ListSignIns()) else { return }
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
        guard connection(for: machineID) != nil else { return markUnavailable(machineID) }
        checkingSignIns[machineID, default: []].insert(kind)
        await readRuntimes(on: machineID, checkForUpdates: false)
        checkingSignIns[machineID]?.remove(kind)
    }

    /// Starts the harness's own sign-in on that machine's server. A key method passes `key`.
    func startSignIn(_ kind: AgentRuntimeKind, method: HarnessSignInMethod, key: String? = nil, on machineID: String) {
        guard let server = connection(for: machineID) else {
            signInMessages[machineID, default: [:]][kind] = ClientError.machineNotConnected(machine(id: machineID)?.name ?? "That machine")
                .localizedDescription
            return
        }
        cancelSignIn(kind, on: machineID)
        signInMessages[machineID]?[kind] = nil
        signInSessions[machineID, default: [:]][kind] = HarnessSignInSession(runtimeKind: kind, method: method)
        var openings = 0
        signInTasks[machineID, default: [:]][kind] = Task { [weak self] in
            await server.follow(StartSignIn(runtime: kind.runtime, signInMethod: method.id, key: key), reply: { [weak self] flowID in
                openings += 1
                // A reconnect would start the sign-in again; it ends instead.
                guard openings == 1 else { self?.endSignIn(kind, on: machineID, .failed, error: ClientError.notConnected.localizedDescription); return }
                self?.signInFlowIDs[machineID, default: [:]][kind] = flowID
                self?.signInSessions[machineID]?[kind]?.state = .waiting
            }, event: { [weak self] event in
                switch event {
                case .open(let url, let code, _):
                    self?.signInSessions[machineID]?[kind]?.url = URL(string: url)
                    self?.signInSessions[machineID]?[kind]?.code = code
                case .prompt: break
                case .finished: self?.endSignIn(kind, on: machineID, .succeeded)
                case .failed(let message): self?.endSignIn(kind, on: machineID, .failed, error: message)
                }
            }, failure: { [weak self] failure in
                self?.endSignIn(kind, on: machineID, .failed, error: failure.localizedDescription)
            })
        }
    }

    private func endSignIn(_ kind: AgentRuntimeKind, on machineID: String, _ state: HarnessSignInSession.State, error: String? = nil) {
        guard signInSessions[machineID]?[kind]?.isActive == true else { return }
        signInSessions[machineID]?[kind]?.state = state
        signInSessions[machineID]?[kind]?.error = error
        signInTasks[machineID]?[kind]?.cancel()
        signInTasks[machineID]?[kind] = nil
        signInFlowIDs[machineID]?[kind] = nil
        if state == .succeeded { Task { await readRuntimes(on: machineID, checkForUpdates: false) } }
    }

    /// Sends a code from the sign-in page to the waiting sign-in.
    func submitSignInCode(_ kind: AgentRuntimeKind, code: String, on machineID: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let flowID = signInFlowIDs[machineID]?[kind], let server = connection(for: machineID) else { return }
        signInSessions[machineID]?[kind]?.sentCode = true
        Task {
            do { _ = try await server.call(AnswerSignIn(flowID: flowID, promptID: "code", answer: code)) }
            catch { signInMessages[machineID, default: [:]][kind] = error.localizedDescription }
        }
    }

    /// Stops a sign-in in progress; leaving the flow stops its command on the server.
    func cancelSignIn(_ kind: AgentRuntimeKind, on machineID: String) {
        signInTasks[machineID]?[kind]?.cancel()
        signInTasks[machineID]?[kind] = nil
        signInFlowIDs[machineID]?[kind] = nil
        signInSessions[machineID]?[kind] = nil
    }

    func dismissSignIn(_ kind: AgentRuntimeKind, on machineID: String) {
        if signInSession(kind, on: machineID)?.isActive == false { signInSessions[machineID]?[kind] = nil }
    }

    /// Signs the harness out there with its own logout command.
    func signOut(_ kind: AgentRuntimeKind, on machineID: String) async {
        await sendSignOut(SignOut(runtime: kind.runtime), kind, on: machineID)
    }

    /// Removes one saved OpenCode account.
    func removeCredential(_ account: AgentSignInStatus.Account, _ kind: AgentRuntimeKind, on machineID: String) async {
        guard let credential = account.credential else { return }
        await sendSignOut(SignOut(runtime: kind.runtime, credential: credential), kind, on: machineID)
    }

    private func sendSignOut(_ request: SignOut, _ kind: AgentRuntimeKind, on machineID: String) async {
        guard let server = connection(for: machineID) else {
            signInMessages[machineID, default: [:]][kind] = ClientError.machineNotConnected(machine(id: machineID)?.name ?? "That machine")
                .localizedDescription
            return
        }
        removingSignIns[machineID, default: []].insert(kind)
        defer { removingSignIns[machineID]?.remove(kind) }
        do {
            _ = try await server.call(request)
            signInMessages[machineID]?[kind] = nil
        } catch {
            signInMessages[machineID, default: [:]][kind] = error.localizedDescription
        }
        await readRuntimes(on: machineID, checkForUpdates: false)
    }

    #if os(macOS)
    /// OpenCode only: its own interactive `opencode auth login`, in Terminal on
    /// this Mac. Its saved keys show once the person returns.
    func openTerminalSignIn(_ kind: AgentRuntimeKind, on machineID: String) {
        guard kind == .opencode, machineID == thisMachine?.id else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ["\(home)/.opencode/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .joined(separator: ":")
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-sign-in-\(UUID().uuidString).command")
        do {
            try "#!/bin/zsh\nrm -f \"$0\"\nexport PATH='\(path)':\"$PATH\"\nopencode auth login\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            openingSignIns[machineID, default: []].insert(kind)
            NSWorkspace.shared.open(script)
            Task {
                try? await Task.sleep(for: .seconds(2))
                openingSignIns[machineID]?.remove(kind)
            }
        } catch {
            signInMessages[machineID, default: [:]][kind] = error.localizedDescription
        }
    }
    #endif
}
