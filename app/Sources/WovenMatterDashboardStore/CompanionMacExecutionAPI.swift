import Foundation
import WovenMatterCore

/// The local Mac execution surface shares native command receipts with the
/// desktop and central-library route. It cannot launch or control other hosts.
@MainActor
public final class CompanionMacExecutionAPI {
  private let database: WorkspaceDatabase
  private let commands: any CompanionCommandServing
  private let authentication: CompanionExecutionAuthentication
  private let descriptor: CompanionExecutionWorkspace
  private let events: (@MainActor @Sendable (Int64) async throws -> CompanionJournalPage)?
  private let isActive: @MainActor @Sendable () -> Bool
  public init(database: WorkspaceDatabase, commands: any CompanionCommandServing,
              authentication: CompanionExecutionAuthentication, descriptor: CompanionExecutionWorkspace,
              isActive: @escaping @MainActor @Sendable () -> Bool,
              events: (@MainActor @Sendable (Int64) async throws -> CompanionJournalPage)? = nil) {
    self.database = database; self.commands = commands; self.authentication = authentication
    self.descriptor = descriptor; self.isActive = isActive; self.events = events
  }
  public func provision(device: CompanionPairedDevice) async throws -> CompanionExecutionCredential {
    try await provision(deviceID: device.id)
  }
  /// App-internal enrollment entry point. HTTP management wrappers must first
  /// authenticate their central-host grant; this method is never a public route.
  public func provision(deviceID: String) async throws -> CompanionExecutionCredential {
    let token = try await authentication.provision(deviceID: deviceID, libraryID: descriptor.libraryID, workspaceID: descriptor.id)
    return CompanionExecutionCredential(workspace: descriptor, deviceID: deviceID, token: token)
  }
  public func revoke(deviceID: String) async throws { try await authentication.revoke(deviceID: deviceID) }

  public func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
    guard isActive() else { return .error("unavailable", "This Mac execution workspace is stopped.", status: 503) }
    do {
      guard let url = URLComponents(string: "http://localhost" + request.target) else { return .error("invalid_request", "Invalid execution path.", status: 400) }
      var path = url.path
      if path.hasPrefix("/wovenmatter/") { path = String(path.dropFirst("/wovenmatter".count)) }
      guard path == "/v1/execution" || path.hasPrefix("/v1/execution/") else { return .error("not_found", "Unknown execution endpoint.", status: 404) }
      guard request.headers["x-woven-protocol"] == String(CompanionProtocol.version) else { return .error("version_mismatch", "Update both clients to compatible versions.", status: 426) }
      guard let bearer = request.bearer else { return .error("unauthorized", "Missing execution credential.", status: 401) }
      let scope = try await authentication.authenticate(bearer: bearer)
      guard scope.libraryID == descriptor.libraryID, scope.workspaceID == descriptor.id,
            request.headers["x-woven-library"] == scope.libraryID, request.headers["x-woven-workspace"] == scope.workspaceID,
            request.headers["x-woven-device"] == scope.deviceID else { return .error("wrong_workspace", "This execution credential is scoped to another device or workspace.", status: 403) }
      guard isActive() else { return .error("unavailable", "This Mac execution workspace stopped.", status: 503) }
      let parts = path.split(separator: "/").map(String.init)
      func query(_ key: String) -> String? { url.queryItems?.first(where: { $0.name == key })?.value }
      if request.method == "GET" {
        switch path {
        case "/v1/execution": return try .json(descriptor)
        case "/v1/execution/providers": return try .json(commands.providers().filter { $0.id.hasPrefix("local:") })
        case "/v1/execution/conversations":
          let values = try await database.companionSnapshot(bodyByteBudget: 0).conversations.filter(isLocal)
          return try .json(values.map { value in
            var copy = value; copy.workspaceID = descriptor.id; copy.libraryID = descriptor.libraryID; return copy
          })
        case "/v1/execution/interactions":
          let local = Set(try await database.companionSnapshot(bodyByteBudget: 0).conversations.filter(isLocal).map(\.id))
          return try .json(await commands.pendingInteractions().filter { local.contains($0.conversationID) })
        case "/v1/execution/events":
          if let events {
            guard let cursor = Int64(query("after") ?? "0"), cursor >= 0 else { return .error("invalid_cursor", "Invalid execution history cursor.", status: 400) }
            return try .json(try await events(cursor))
          }
          // This host's canonical DB already owns these records. Advertise
          // history.central.v1 and fetch its normal library change feed instead.
          guard query("after") == nil || query("after") == "0" else { return .error("invalid_cursor", "Central Mac history uses the library change cursor.", status: 400) }
          return try .json(CompanionJournalPage(libraryID: descriptor.libraryID, cursor: 0))
        default: break
        }
        if parts.count == 4, parts[2] == "commands" {
          guard let receipt = try await commands.receipt(commandID: parts[3], deviceID: scope.deviceID) else { return .error("not_found", "No receipt exists for this command.", status: 404) }
          if let id = receipt.conversationID { try await requireLocal(id) }
          return try .json(scoped(receipt))
        }
        if parts.count == 5, parts[2] == "conversations" {
          try await requireLocal(parts[3])
          if parts[4] == "transcript" { return try .json(try await commands.transcript(conversationID: parts[3], before: query("before"))) }
          if parts[4] == "capabilities" { return try .json(try await commands.sessionCapabilities(conversationID: parts[3])) }
        }
      } else if request.method == "POST" {
        if path == "/v1/execution/commands" {
          let command = try JSONDecoder().decode(CompanionCommand.self, from: request.body)
          guard command.deviceID == scope.deviceID, command.libraryID == scope.libraryID, command.workspaceID == scope.workspaceID else { return .error("wrong_workspace", "Command identity does not match its authenticated execution scope.", status: 403) }
          if let route = command.routeID, !route.hasPrefix("local:") { throw notLocal }
          if let provider = command.providerID, !provider.hasPrefix("local:") { throw notLocal }
          if command.kind == .createSession {
            guard let route = command.providerID ?? command.routeID, route.hasPrefix("local:"),
                  commands.providers().contains(where: { $0.id == route }) else { throw notLocal }
          } else if command.kind == .workspace {
            guard let action = command.workspaceAction else { throw notLocal }
            switch action {
            case .conversation(let id, _, _, _), .configureSession(let id, _, _, _), .sessionTools(let id, _, _): try await requireLocal(id)
            default: throw CompanionAPIError(code: "unsupported", message: "Use central library synchronization for this app-data operation.")
            }
          } else {
            guard let id = command.conversationID else { throw notLocal }
            try await requireLocal(id)
          }
          return try .json(scoped(try await commands.execute(command, deviceID: scope.deviceID)))
        }
        if path == "/v1/execution/workspace-read" {
          let read = try JSONDecoder().decode(CompanionWorkspaceRead.self, from: request.body)
          switch read {
          case .session(let id), .exportConversation(let id, _): try await requireLocal(id)
          default: throw CompanionAPIError(code: "unsupported", message: "Use the central library for shared app data.")
          }
          return try .json(try await commands.readWorkspace(read))
        }
      }
      return .error("not_found", "Unknown execution endpoint.", status: 404)
    } catch let error as CompanionAPIError {
      let status = error.code == "unauthorized" ? 401 : error.code == "wrong_workspace" ? 403 : 400
      return .error(error.code, error.message, status: status)
    } catch is DecodingError { return .error("invalid_request", "Invalid execution request.", status: 400) }
    catch { return .error("execution_error", "The Mac could not complete this execution request. Check its receipt before retrying.", status: 500) }
  }
  private var notLocal: CompanionAPIError { .init(code: "wrong_workspace", message: "This endpoint can only control agents executing on this Mac.") }
  private func isLocal(_ value: CompanionConversation) -> Bool {
    value.workspaceID == nil && (value.routeID ?? value.providerID)?.hasPrefix("local:") == true
  }
  private func requireLocal(_ id: String) async throws {
    guard let value = try await database.companionSnapshot(bodyByteBudget: 0).conversations.first(where: { $0.id == id }), isLocal(value) else { throw notLocal }
  }
  private func scoped(_ receipt: CompanionCommandReceipt) -> CompanionCommandReceipt {
    var value = receipt; value.libraryID = descriptor.libraryID; value.workspaceID = descriptor.id; return value
  }
}
