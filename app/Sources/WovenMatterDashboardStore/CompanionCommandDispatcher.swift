import Foundation
import WovenMatterCore

/// Durable acceptance precedes execution. Accepted work has a retained task and
/// never inherits cancellation from a phone's HTTP request or reconnect.
@MainActor
public final class CompanionCommandDispatcher {
    public let database: WorkspaceDatabase
    private var commands: [String: Task<CompanionCommandReceipt, any Error>] = [:]

    public init(database: WorkspaceDatabase) { self.database = database }

    public func execute(
        _ command: CompanionCommand,
        perform: @escaping @MainActor (CompanionCommandReceipt) async throws -> CompanionCommandReceipt
    ) async throws -> CompanionCommandReceipt {
        let key = "\(command.deviceID):\(command.commandID)"
        let reservation = try database.reserveCompanionCommand(command)
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
            try database.finishCompanionCommand(receipt)
            return receipt
        }
        commands[key] = work
        defer { commands.removeValue(forKey: key) }
        return try await work.value
    }

    public func receipt(commandID: String, deviceID: String) throws -> CompanionCommandReceipt? {
        guard var receipt = try database.companionCommandReceipt(deviceID: deviceID, commandID: commandID) else { return nil }
        if receipt.status == .accepted && commands["\(deviceID):\(commandID)"] == nil {
            receipt.status = .outcomeUnknown
            receipt.message = "The Mac accepted this command but its result was not recorded. Check the conversation before issuing another command; this command will not run again."
        }
        return receipt
    }
}
