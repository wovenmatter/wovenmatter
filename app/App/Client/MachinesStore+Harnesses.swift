import Foundation

/// Harness installs, updates and sign-ins on each machine. The machine's server runs
/// the harness's own commands; the UI never starts a harness process.
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

    /// Re-reads installed and latest versions there.
    func refreshHarnesses(on machineID: String) {
        harnessInventoryUnavailable.insert(machineID)
    }

    func checkForUpdates(_ kind: AgentRuntimeKind, on machineID: String) {
        setHarnessError(kind, on: machineID)
    }

    func install(_ kind: AgentRuntimeKind, on machineID: String) {
        setHarnessError(kind, on: machineID)
    }

    func update(_ kind: AgentRuntimeKind, on machineID: String) {
        setHarnessError(kind, on: machineID)
    }

    /// Installs each harness in order on that machine's server.
    func installHarnesses(_ kinds: [AgentRuntimeKind], on machineID: String) {
        for kind in kinds { setHarnessError(kind, on: machineID) }
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

    private func setHarnessError(_ kind: AgentRuntimeKind, on machineID: String) {
        harnessErrors[machineID, default: [:]][kind] = ClientError.notConnected.localizedDescription
    }

    // MARK: Sign-in

    func signInStatus(_ kind: AgentRuntimeKind, on machineID: String) -> AgentSignInStatus? {
        signInStatuses[machineID]?[kind]
    }

    func providerSignIns(on machineID: String) -> [AgentSignInStatus] {
        providerSignInStatuses[machineID] ?? []
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

    func refreshSignIn(_ kind: AgentRuntimeKind, on machineID: String) async {}

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

    private func setSignInMessage(_ kind: AgentRuntimeKind, on machineID: String) {
        signInMessages[machineID, default: [:]][kind] = ClientError.notConnected.localizedDescription
    }
}
