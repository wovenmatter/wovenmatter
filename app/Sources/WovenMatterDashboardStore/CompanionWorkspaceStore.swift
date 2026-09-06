import WovenMatterCore

extension DashboardStore {
  public func companionWorkspaceID() throws -> String { try database.companionWorkspaceID() }
  public func companionSnapshot() throws -> CompanionSnapshot { try database.companionSnapshot() }
  public func companionNote(id: String) throws -> CompanionNote? { try database.companionNote(id: id) }
  public func companionChanges(after cursor: Int64, limit: Int = 200) throws -> CompanionChangePage {
    try database.companionChanges(after: cursor, limit: limit)
  }
  public func applyCompanionMutation(_ request: CompanionMutation) throws -> CompanionMutationResult {
    try database.applyCompanionMutation(request)
  }
  public func reserveCompanionCommand(_ request: CompanionCommand) throws -> CompanionCommandReservation {
    try database.reserveCompanionCommand(request)
  }
  public func finishCompanionCommand(_ receipt: CompanionCommandReceipt) throws { try database.finishCompanionCommand(receipt) }
  public func companionCommandReceipt(deviceID: String, commandID: String) throws -> CompanionCommandReceipt? {
    try database.companionCommandReceipt(deviceID: deviceID, commandID: commandID)
  }
}
