import WovenMatterCore

extension DashboardStore {
  public func companionWorkspaceID() async throws -> String { try await database.companionWorkspaceID() }
  public func companionSnapshot() async throws -> CompanionSnapshot { try await database.companionSnapshot() }
  public func companionNote(id: String) async throws -> CompanionNote? { try await database.companionNote(id: id) }
  public func companionChanges(after cursor: Int64, limit: Int = 200) async throws -> CompanionChangePage {
    try await database.companionChanges(after: cursor, limit: limit)
  }
  public func applyCompanionMutation(_ request: CompanionMutation) async throws -> CompanionMutationResult {
    try await database.applyCompanionMutation(request)
  }
  public func reserveCompanionCommand(_ request: CompanionCommand) async throws -> CompanionCommandReservation {
    try await database.reserveCompanionCommand(request)
  }
  public func finishCompanionCommand(_ receipt: CompanionCommandReceipt) async throws { try await database.finishCompanionCommand(receipt) }
  public func companionCommandReceipt(deviceID: String, commandID: String) async throws -> CompanionCommandReceipt? {
    try await database.companionCommandReceipt(deviceID: deviceID, commandID: commandID)
  }
}
