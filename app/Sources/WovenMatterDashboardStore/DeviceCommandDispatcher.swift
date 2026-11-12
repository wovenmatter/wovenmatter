import Foundation
import WovenMatterCore

/// Durable acceptance precedes execution. Accepted work has a retained task and
/// never inherits cancellation from a phone's HTTP request or reconnect.
@MainActor
public final class DeviceCommandDispatcher {
    public let database: WorkspaceDatabase
    private var commands: [String: Task<LibraryCommandReceipt, any Error>] = [:]

    public init(database: WorkspaceDatabase) { self.database = database }

    public func execute(
        _ command: LibraryCommand,
        perform: @escaping @MainActor (LibraryCommandReceipt) async throws -> LibraryCommandReceipt
    ) async throws -> LibraryCommandReceipt {
        let key = "\(command.deviceID):\(command.commandID)"
        let reservation = try await database.reserveLibraryCommand(command)
        // A different payload must be rejected before joining an in-flight task.
        guard reservation.receipt.status != .rejected else { return reservation.receipt }
        if let task = commands[key] { return try await task.value }
        guard reservation.isNew else { return reservation.receipt }
        let work = Task { [database] in
            var receipt = reservation.receipt
            do {
                receipt = try await perform(receipt)
                receipt.status = .completed
            } catch {
                receipt.status = .rejected
                receipt.message = error.localizedDescription
            }
            // On write failure the acceptance remains on disk. No retry may reexecute it.
            try await database.finishLibraryCommand(receipt)
            return receipt
        }
        commands[key] = work
        defer { commands.removeValue(forKey: key) }
        return try await work.value
    }

    public func receipt(commandID: String, deviceID: String) async throws -> LibraryCommandReceipt? {
        guard var receipt = try await database.libraryCommandReceipt(deviceID: deviceID, commandID: commandID) else { return nil }
        if receipt.status == .accepted && commands["\(deviceID):\(commandID)"] == nil {
            receipt.status = .outcomeUnknown
            receipt.message = "The Mac accepted this command but its result was not recorded. Check the conversation before issuing another command; this command will not run again."
        }
        return receipt
    }
}
