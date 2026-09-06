import WovenMatterCore

/// Provider boundary injected by facade tests; all UI routing, binding and command
/// receipt code remains the real implementation. No adapter is installed by the app.
struct DashboardRunControlAdapters: Sendable {
  enum Route: Sendable { case localACP, gateway }
  let accept: @Sendable (Route, String, AgentMessageInput, String?, AgentNoteContext?) async throws -> LocalACPRunIdentifiers
  let steer: @Sendable (Route, String, AgentMessageInput, String?, String?) async throws -> LocalACPSteeringIdentifiers
  let cancel: @Sendable (Route, String, String?) async throws -> Void
  var beforeSessionCreation: @Sendable () async -> Void = {}
}
