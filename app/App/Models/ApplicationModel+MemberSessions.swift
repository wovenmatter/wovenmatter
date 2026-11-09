import Foundation
import CompanionClient
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

/// Where an agent's `woven_sessions_create` lands. Workspaces are named by ID:
/// this Mac's own, a Linux host it manages over SSH, or another member's
/// workspace (a paired Mac or any Linux host) reached with signed requests.
/// The iPhone is never a destination; it runs only its own Quick Chats.
enum AgentToolDestination: Equatable {
    case thisMac
    case configured(UUID)
    case member(CompanionExecutionWorkspace)
}

extension ApplicationModel {
    /// Every execution workspace agents may target, this Mac's first.
    func agentToolWorkspaces() async throws -> (own: CompanionExecutionWorkspace?, others: [CompanionExecutionWorkspace]) {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let device = try await database.companionLibraryIdentity().hostDeviceID
        let all = try await database.companionExecutionWorkspaces().filter { !$0.deleted && $0.kind != .ios }
        let own = all.first { $0.kind == .mac && $0.executionDeviceID == device }
        let others = all.filter { $0.id != own?.id }.sorted {
            ($0.kind == .mac ? 0 : 1, $0.name.lowercased()) < ($1.kind == .mac ? 0 : 1, $1.name.lowercased())
        }
        return (own, others)
    }

    func resolveAgentToolDestination(_ raw: String?, callerWorkspace: UUID?) async throws -> AgentToolDestination {
        guard let raw else { return callerWorkspace.map(AgentToolDestination.configured) ?? .thisMac }
        let (own, others) = try await agentToolWorkspaces()
        let id = raw.lowercased()
        if let own, id == own.id { return .thisMac }
        if let uuid = UUID(uuidString: id), remoteWorkspaces.configuration(id: uuid) != nil { return .configured(uuid) }
        if let member = others.first(where: { $0.id == id }) { return .member(member) }
        if let database = dashboardStore?.database,
           try await database.companionExecutionWorkspaces().contains(where: { $0.id == id && $0.kind == .ios }) {
            throw WorkspaceToolError.invalid("An iPhone or iPad runs only its own Quick Chats. Choose a Mac or Linux workspace.")
        }
        let valid = ([own].compactMap { $0 } + others).map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
        throw WorkspaceToolError.invalid("Name the destination by workspace ID" + (valid.isEmpty ? "." : ": " + valid + "."))
    }

    /// Creates a session on another member's workspace and sends its first
    /// message. The destination applies its own saved defaults (model,
    /// permission, tools), exactly as for a session its own user starts. IDs
    /// derive from the caller and request, so a retry replays receipts.
    func createMemberToolSession(sourceID: String, requestID: String, workspace: CompanionExecutionWorkspace,
                                 runtime: AgentRuntimeKind, title: String, text: String) async throws -> WovenMatterToolResponse {
        let client = try centralExecutionClient()
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let device = try await database.companionLibraryIdentity().hostDeviceID
        let providers = try await client.providers(workspace: workspace)
        guard let provider = providers.first(where: { $0.runtimeKind == runtime.rawValue && $0.available && $0.canStart }) else {
            let ready = providers.filter { $0.available && $0.canStart }.map(\.runtimeKind)
            throw WorkspaceToolError.invalid("\(runtime.rawValue) is not ready on \(workspace.name)." + (ready.isEmpty ? "" : " Ready: " + ready.joined(separator: ", ") + "."))
        }
        let conversationID = Self.memberToolID(sourceID, requestID, "session")
        func command(_ kind: CompanionCommand.Kind, _ suffix: String, text: String? = nil, action: CompanionWorkspaceAction? = nil) -> CompanionCommand {
            .init(commandID: Self.memberToolID(sourceID, requestID, suffix), deviceID: device, kind: kind, conversationID: conversationID,
                  providerID: kind == .createSession ? provider.id : nil, runtimeKind: kind == .createSession ? runtime.rawValue : nil,
                  text: text, workspaceAction: action, libraryID: workspace.libraryID, workspaceID: workspace.id)
        }
        _ = try await client.submit(command(.createSession, "create"), workspace: workspace)
        _ = try? await client.submit(command(.workspace, "title", action: .conversation(id: conversationID, action: "rename", title: title, folderID: nil)), workspace: workspace)
        let receipt = try await client.submit(command(.send, "send", text: text), workspace: workspace)
        return .init(result: .object([
            "session": .object(["id": .string(conversationID), "title": .string(title), "harness": .string(runtime.rawValue),
                                "workspace": .string(workspace.id), "workspaceName": .string(workspace.name),
                                "workspaceKind": .string(workspace.kind.rawValue)]),
            "receipt": .object(["commandID": .string(receipt.commandID), "status": .string(receipt.status.rawValue)]),
            // Sessions on other devices are not coordinated from here; their
            // history reaches this library as they run.
            "independent": .bool(true)
        ]))
    }

    /// `woven_sessions_harnesses`: this Mac (its real workspace ID and name),
    /// then paired Macs, then Linux workspaces. A member that cannot be
    /// reached is listed once with `online: false`.
    func agentToolHarnessRows() async throws -> [GatewayJSONValue] {
        let (own, others) = try await agentToolWorkspaces()
        var rows: [GatewayJSONValue] = LocalACPRuntimeCatalog.definitions.map {
            .object(["harness": .string($0.runtimeKind.rawValue), "workspace": own.map { .string($0.id) } ?? .null,
                     "workspaceName": .string(own?.name ?? DevelopmentLaunch.deviceName()), "workspaceKind": .string("mac"),
                     "ready": .bool(isLocalACPAgentReady($0.runtimeKind))])
        }
        let configured = Set(remoteWorkspaces.workspaces.map { $0.id.uuidString.lowercased() })
        for workspace in others {
            if workspace.kind == .linux, let uuid = UUID(uuidString: workspace.id), configured.contains(workspace.id),
               let configuration = remoteWorkspaces.configuration(id: uuid) {
                rows += (remoteWorkspaces.harnesses[uuid] ?? []).map { harness in
                    .object(["harness": .string(harness.id.rawValue), "workspace": .string(workspace.id), "workspaceName": .string(workspace.name),
                             "workspaceKind": .string("linux"), "ready": .bool(remoteWorkspaces.isHarnessReady(harness.id, in: configuration))])
                }
                continue
            }
            let base: [String: GatewayJSONValue] = ["workspace": .string(workspace.id), "workspaceName": .string(workspace.name),
                                                    "workspaceKind": .string(workspace.kind.rawValue)]
            do {
                let providers = try await centralExecutionClient().providers(workspace: workspace)
                let kinds = Set(AgentRuntimeKind.allCases.map(\.rawValue))
                for provider in providers where kinds.contains(provider.runtimeKind) {
                    rows.append(.object(base.merging(["harness": .string(provider.runtimeKind),
                        "ready": .bool(provider.available && provider.canStart)]) { $1 }))
                }
            } catch {
                rows.append(.object(base.merging(["online": .bool(false), "error": .string(String(error.localizedDescription.prefix(256)))]) { $1 }))
            }
        }
        return rows
    }

    /// Peers that refused library sync with `update_required`, worded so the
    /// devices' "Versions don't match" notice offers Update everything.
    nonisolated static func libraryUpdateNotices(_ status: LibrarySyncStatus?) -> [String] {
        (status?.peers ?? []).filter { $0.state == .updateRequired }.map { peer in
            "\(peer.name) needs the same Woven Matter version to synchronize" + (peer.version.map { " (it runs \($0))." } ?? ".")
        }
    }

    /// A stable UUID for one step of one agent request.
    nonisolated static func memberToolID(_ sourceID: String, _ requestID: String, _ step: String) -> String {
        var bytes = Array(PortableSHA256.hash(data: Data("woven-member-tool-v1\0\(sourceID)\0\(requestID)\0\(step)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }
}
