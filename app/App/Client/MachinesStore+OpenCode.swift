import Foundation

/// OpenCode's own background server on each machine: connection, lifecycle, which of
/// its models Woven shows, and its sessions that can be added to Woven's chats.
extension MachinesStore {
    func openCodeServer(on machineID: String) -> OpenCodeServer? { openCodeServers[machineID] }

    func connectOpenCode(on machineID: String) { setOpenCodeError(on: machineID) }
    func installOpenCode(on machineID: String) { setOpenCodeError(on: machineID) }
    func restartOpenCode(on machineID: String) { setOpenCodeError(on: machineID) }
    func stopOpenCode(on machineID: String) { setOpenCodeError(on: machineID) }

    func setOpenCodeStartsWithApp(_ starts: Bool, on machineID: String) { setOpenCodeError(on: machineID) }

    func refreshOpenCodeModels(on machineID: String) async throws {
        throw ClientError.notConnected
    }

    func setOpenCodeModelVisible(_ modelID: String, visible: Bool, on machineID: String) {
        setOpenCodeError(on: machineID)
    }

    /// The address of OpenCode's web interface on this Mac.
    func openCodeBrowserURL(on machineID: String) async throws -> URL {
        throw ClientError.notConnected
    }

    func openCodeImportableSessions(on machineID: String, cursor: String?) async throws -> OpenCodeSessionPage {
        throw ClientError.notConnected
    }

    func importOpenCodeSession(_ sessionID: String, on machineID: String) async throws {
        throw ClientError.notConnected
    }

    /// Renames OpenCode's agent on that machine.
    func renameOpenCode(on machineID: String, to name: String) async throws {
        throw ClientError.notConnected
    }

    private func setOpenCodeError(on machineID: String) {
        openCodeErrors[machineID] = ClientError.notConnected.localizedDescription
    }
}
