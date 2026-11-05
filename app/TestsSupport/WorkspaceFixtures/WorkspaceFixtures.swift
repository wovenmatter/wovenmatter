import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

/// A unique temporary directory that owns one workspace database file.
public struct PersistenceFixture: Sendable {
  public let directory: URL
  public var databaseURL: URL { directory.appending(path: "workspace.sqlite") }

  public init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "persistence-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public func openDatabase(readOnlyProjection: Bool = false) async throws -> WorkspaceDatabase {
    try await WorkspaceDatabase(url: databaseURL, readOnlyProjection: readOnlyProjection)
  }

  public func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Checks `condition` up to `attempts` times, sleeping `interval` between
/// checks. Returns false when every attempt was exhausted.
public nonisolated(nonsending) func pollUntil(attempts: Int, interval: Duration,
    _ condition: () async throws -> Bool) async throws -> Bool {
  for _ in 0..<attempts {
    if try await condition() { return true }
    try await Task.sleep(for: interval)
  }
  return false
}

public func rows(_ value: GatewayJSONValue) -> [GatewayJSONValue] {
  value.objectValue?["rows"]?.arrayValue ?? []
}

/// A fake `tailscale serve` whose probe replies describe the one child it
/// launched and any ports already in use.
@MainActor public final class FixtureTailscaleServe {
  public let dnsName: String
  public var failProbes = false
  public var existingPorts: Set<Int> = []
  public private(set) var child: FixtureServingChild?
  public init(dnsName: String) { self.dnsName = dnsName }
  public func exposure() -> CompanionTailscaleServe {
    CompanionTailscaleServe(executable: URL(fileURLWithPath: "/fixture/tailscale"),
      probe: { [self] _, arguments in try await probe(arguments) },
      launch: { [self] _, arguments in
        let value = FixtureServingChild(port: Int(arguments[1].dropFirst("--https=".count))!, target: arguments[3])
        child = value; return value
      })
  }
  public func probe(_ arguments: [String]) throws -> Data {
    if failProbes { throw URLError(.notConnectedToInternet) }
    if arguments == ["status", "--json"] {
      return Data(#"{"BackendState":"Running","Self":{"DNSName":"\#(dnsName)."}}"#.utf8)
    }
    let tcp = Dictionary(uniqueKeysWithValues: existingPorts.map { (String($0), ["HTTPS": true]) })
    guard let child, child.isRunning else { return try JSONSerialization.data(withJSONObject: ["TCP": tcp]) }
    return try JSONSerialization.data(withJSONObject: ["TCP": tcp, "Foreground": ["fixture": [
      "TCP": [String(child.port): ["HTTPS": true]],
      "Web": ["\(dnsName):\(child.port)": ["Handlers": ["/wovenmatter": ["Proxy": child.target]]]]]]])
  }
}

@MainActor public final class FixtureServingChild: CompanionServingProcess {
  public let port: Int
  public let target: String
  public var isRunning = true
  public init(port: Int, target: String) { self.port = port; self.target = target }
  public func terminate() { isRunning = false }
}

// Existing suites create provider-free records with explicit fixture locations.
// These helpers are test-target dependencies only; production requires a root.
extension WorkspaceDatabase {
  public func createFixtureLocalACPSession(runtimeKind: AgentRuntimeKind, title: String,
      ownerDeviceID: UUID, createdAt: Date = Date(),
      openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
      importedOpenCodeSnapshot: OpenCodeSessionSnapshot? = nil,
      requestedConversationID: UUID? = nil, allowMissingCalendarFolder: Bool = false, fixtureLocation: WorkspaceFolderLocation? = nil) async throws -> String {
    let root = try await fixtureCreationRoot(requestedConversationID, workspaceID: "device:" + ownerDeviceID.uuidString.lowercased(), explicit: fixtureLocation)
    return try await createLocalACPSession(runtimeKind: runtimeKind, title: title, ownerDeviceID: ownerDeviceID,
      createdAt: createdAt, openCodeAssociation: openCodeAssociation, importedOpenCodeSnapshot: importedOpenCodeSnapshot,
      requestedConversationID: requestedConversationID, allowMissingCalendarFolder: allowMissingCalendarFolder, executionRoot: root)
  }

  public func createFixtureRemoteACPSession(runtimeKind: AgentRuntimeKind, remoteWorkspaceID: UUID,
      remoteWorkspaceName: String, title: String, ownerDeviceID: UUID, createdAt: Date = Date(),
      openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
      requestedConversationID: UUID? = nil, allowMissingCalendarFolder: Bool = false, fixtureLocation: WorkspaceFolderLocation? = nil) async throws -> String {
    let root = try await fixtureCreationRoot(requestedConversationID, workspaceID: "remote:" + remoteWorkspaceID.uuidString.lowercased(), explicit: fixtureLocation)
    return try await createRemoteACPSession(runtimeKind: runtimeKind, remoteWorkspaceID: remoteWorkspaceID,
      remoteWorkspaceName: remoteWorkspaceName, title: title, ownerDeviceID: ownerDeviceID, createdAt: createdAt,
      openCodeAssociation: openCodeAssociation, requestedConversationID: requestedConversationID,
      allowMissingCalendarFolder: allowMissingCalendarFolder, executionRoot: root)
  }

  public func createFixtureFolder(id: UUID = UUID(), name: String, createdAt: Date = Date()) async throws -> String {
    try await createFolder(id: id, name: name, location: .init(workspaceID: "device:test",
      rootPath: FileManager.default.temporaryDirectory.appending(path: id.uuidString).path, managed: false), createdAt: createdAt)
  }

  /// Managed access the way the sessions tool acquires it: the request is
  /// approved when the coordinator lacks transcript access to the target.
  public func coordinateFixtureSession(sourceID: String, targetID: String, purpose: String,
      notifications: Bool = true) async throws {
    var request = try await requestCoordinationAccess(sourceID: sourceID, targetID: targetID, purpose: purpose,
      notifications: notifications, requestID: UUID().uuidString)
    if request.state == "pending" { request = try await resolveCoordinationAccess(requestID: request.id, allowed: true) }
    guard request.state == "accepted" else {
      throw WorkspaceToolError.invalid(request.error ?? "The fixture could not acquire coordination.")
    }
  }

  private func fixtureCreationRoot(_ id: UUID?, workspaceID: String, explicit: WorkspaceFolderLocation?) async throws -> SessionCreationRoot {
    let configuration: WorkspaceSessionCreationConfiguration?
    if let id { configuration = try await toolSessionCreationConfiguration(targetID: id.uuidString.lowercased()) }
    else { configuration = nil }
    if let explicit { return .init(folderID: configuration?.folderID, location: explicit, defaultPath: explicit.rootPath) }
    if let id, let existing = try await sessionExecutionRoot(id: id.uuidString.lowercased()) {
      return .init(folderID: configuration?.folderID, location: existing, defaultPath: existing.rootPath)
    }
    let path = configuration?.nativeWorkingDirectory ?? FileManager.default.temporaryDirectory.path
    let location: WorkspaceFolderLocation
    if let folderID = configuration?.folderID,
       let folder = try await workspaceOverview().folders.first(where: { $0.id == folderID }),
       let owner = folder.executionWorkspaceID, let root = folder.rootPath {
      location = .init(workspaceID: owner, rootPath: root, managed: false)
    } else { location = .init(workspaceID: workspaceID, rootPath: path, managed: false) }
    return .init(folderID: configuration?.folderID, location: location, defaultPath: path)
  }
}
