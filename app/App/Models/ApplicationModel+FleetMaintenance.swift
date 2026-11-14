import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// Harnesses and Pi Durable SDKs across machines, for Settings → Updates.
///
/// This Mac serves its own at `/v1/runtime-maintenance` and `/v1/default-agent/sdks`
/// to other Macs, in the shapes a Linux host already serves. It reaches another Mac,
/// or a Linux host another Mac added, the same way, signed with its member key. All of
/// it runs in the process that owns execution; the window asks through bots commands.
extension ApplicationModel {
    /// The harnesses this Mac reports: those installed, not counting Pi Durable, whose
    /// SDKs are reported separately.
    static let fleetHarnessKinds: [AgentRuntimeKind] = [.codex, .claudeCode, .grokBuild, .opencode]

    // MARK: This Mac's side, for other Macs

    /// A signed Mac member's request. Phones don't manage harnesses.
    func memberMaintenance(_ request: LibraryHTTPRequest, path: String) async -> LibraryHTTPResponse {
        do {
            if path == "/v1/default-agent/sdks" {
                let command = request.method == "GET" ? DefaultAgentSDKRequest(action: .status)
                    : try JSONDecoder().decode(DefaultAgentSDKRequest.self, from: request.body)
                let status = try await DefaultAgentSDKControl.run(command)
                if command.action == .update { connections.invalidateSDKCatalog(scopeKey: "local") }
                return try .json(status)
            }
            switch (request.method, path) {
            case ("GET", "/v1/runtime-maintenance"):
                return try .json(MaintenanceDocument(runtimes: localMaintenanceRows()))
            case ("POST", "/v1/runtime-maintenance/check"):
                refreshRuntimeInventory()
                await waitForRuntime(timeout: .seconds(60)) { !self.checkingRuntimeInventory && self.checkingRuntimeKinds.isEmpty }
                return try .json(MaintenanceDocument(runtimes: localMaintenanceRows()))
            default:
                break
            }
            let parts = path.split(separator: "/").map(String.init)
            guard request.method == "POST", parts.count == 4, parts[1] == "runtime-maintenance",
                  let kind = AgentRuntimeKind(rawValue: parts[2]), Self.fleetHarnessKinds.contains(kind) else {
                return .error("not_found", "Unknown maintenance route.", status: 404)
            }
            switch parts[3] {
            case "check":
                checkRuntimeUpdate(kind)
                await waitForRuntime(timeout: .seconds(60)) { !self.checkingRuntimeKinds.contains(kind) }
                return try .json(maintenanceRow(kind))
            case "update":
                struct Body: Decodable { var force: Bool? }
                let force = (try? JSONDecoder().decode(Body.self, from: request.body))?.force ?? false
                return try .json(await updateLocalRuntimeForMember(kind, force: force))
            default:
                return .error("not_found", "Unknown maintenance route.", status: 404)
            }
        } catch {
            return .error("failed", error.localizedDescription, status: 400)
        }
    }

    struct MaintenanceDocument: Codable { let runtimes: [RemoteRuntimeMaintenance] }

    func localMaintenanceRows() -> [RemoteRuntimeMaintenance] {
        Self.fleetHarnessKinds.compactMap { kind in
            guard runtimeInventories[kind]?.isInstalled == true else { return nil }
            return maintenanceRow(kind)
        }
    }

    private func maintenanceRow(_ kind: AgentRuntimeKind) -> RemoteRuntimeMaintenance {
        let operation: RemoteHarnessOperation? = updatingRuntimeKinds.contains(kind)
            ? .init(id: UUID(), harnessID: kind, action: "update", status: "running", startedAt: Self.timestamp())
            : failedRuntimeUpdateKinds.contains(kind)
                ? .init(id: UUID(), harnessID: kind, action: "update", status: "failed",
                        error: runtimeFailureDetails[kind] ?? "The update failed.", startedAt: Self.timestamp())
                : nil
        guard let inventory = runtimeInventories[kind] else {
            return RemoteRuntimeMaintenance(id: kind, displayName: kind.displayName, installed: false, components: [],
                                            operation: operation, updateAvailable: false)
        }
        return inventory.maintenance(operation: operation, failureCount: runtimeFailures[kind] ?? 0)
    }

    /// Runs the update to the end, so the caller gets one finished operation. A busy
    /// harness is refused unless `force`, which stops the chats using it first.
    private func updateLocalRuntimeForMember(_ kind: AgentRuntimeKind, force: Bool) async -> RemoteHarnessOperation {
        let started = Self.timestamp()
        func finished(_ error: String?) -> RemoteHarnessOperation {
            .init(id: UUID(), harnessID: kind, action: "update", status: error == nil ? "succeeded" : "failed",
                  error: error, startedAt: started, finishedAt: Self.timestamp())
        }
        if localRuntimeMaintenanceHasActiveConversation {
            guard force else { return finished(Self.busyRuntimeError) }
            await stopLocalRuntimeConversations()
            guard !localRuntimeMaintenanceHasActiveConversation else { return finished(Self.busyRuntimeError) }
        }
        updateRuntime(kind)
        await waitForRuntime(timeout: .seconds(10)) { self.updatingRuntimeKinds.contains(kind) }
        await waitForRuntime(timeout: .seconds(900)) { !self.updatingRuntimeKinds.contains(kind) && !self.runtimeMaintenanceBusy(kind) }
        if failedRuntimeUpdateKinds.contains(kind) { return finished(runtimeFailureDetails[kind] ?? "The update failed.") }
        if runtimeInventories[kind]?.updateAvailable == true { return finished("It is still out of date.") }
        return finished(nil)
    }

    /// What a host answers when chats are using the harness. Settings → Updates offers
    /// to stop them and try again.
    static let busyRuntimeError = "runtime_active_stop_conversations_or_server_first"

    /// Stops every chat on this Mac that uses a harness installed here.
    func stopLocalRuntimeConversations() async {
        let conversations = workspaceOverview?.conversations ?? []
        let ids = localRunningConversationIDs.filter { id in
            conversations.first { $0.id == id }.map { $0.localRuntimeKind != nil && $0.remoteWorkspaceID == nil } ?? true
        }
        for id in ids { cancelLocalACPPrompt(conversationID: id) }
        await waitForRuntime(timeout: .seconds(30)) { self.localRunningConversationIDs.isDisjoint(with: ids) }
    }

    private func waitForRuntime(timeout: Duration, until done: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(500)) }
    }

    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    // MARK: Other machines, from this Mac

    /// The signed client for another Mac or Linux workspace in the registry, by its device ID.
    private func memberClient(machineID: String) async throws -> MemberSignedHTTPClient {
        guard let target = await memberBotTargets().first(where: { $0.audience == machineID.lowercased() }) else {
            throw BotsError.unavailable("That machine isn't reachable from this Mac right now.")
        }
        return try await botsClient(for: target.workspace)
    }

    /// Another machine's harnesses and Pi Durable SDKs. A machine that predates these
    /// routes answers 404, reported as needing an update.
    func memberInventory(machineID: String, checkLatest: Bool) async throws -> FleetMemberInventory {
        let client = try await memberClient(machineID: machineID)
        // Both at once: the window waits at most 30 seconds for this answer.
        let sdkBody = checkLatest ? try JSONEncoder().encode(DefaultAgentSDKRequest(action: .check)) : nil
        async let sdkReply: DefaultAgentSDKStatus = client.request(
            "v1/default-agent/sdks", method: checkLatest ? "POST" : "GET", body: sdkBody, timeout: 20)
        do {
            let document: MaintenanceDocument = try await client.request(
                checkLatest ? "v1/runtime-maintenance/check" : "v1/runtime-maintenance",
                method: checkLatest ? "POST" : "GET", body: checkLatest ? Data() : nil, timeout: 20)
            let sdks = try? await sdkReply
            return .init(runtimes: document.runtimes.filter { $0.installed && $0.source != "system" && $0.id != .defaultAgent },
                         sdks: sdks)
        } catch let error as MemberSignedHTTPError {
            if case .http(status: 404, _, _) = error {
                return .init(runtimes: [], sdks: nil, unsupported: true)
            }
            throw error
        }
    }

    /// The download a Linux host would run for this update; nil for a Mac, whose
    /// harnesses update from their package registries with integrity checks.
    func memberInstallerPreview(machineID: String, kind: AgentRuntimeKind) async throws -> RemoteInstallerPreview? {
        let client = try await memberClient(machineID: machineID)
        do {
            return try await client.request("v1/harnesses/\(kind.rawValue)/install-preview", timeout: 25)
        } catch let error as MemberSignedHTTPError {
            if case .http(status: 404, _, _) = error { return nil }
            throw error
        }
    }

    /// Updates a harness on another machine and follows it to the end. A Linux host
    /// verifies the reviewed download; a Mac stops its chats first when `force`.
    func updateMemberHarness(machineID: String, kind: AgentRuntimeKind, sourceSHA256: String?, packageSpec: String?,
                             force: Bool, progress: @escaping @MainActor (String) -> Void) async throws {
        let client = try await memberClient(machineID: machineID)
        var payload: [String: Any] = ["confirmed": true, "force": force]
        if let sourceSHA256 { payload["sourceSHA256"] = sourceSHA256 }
        if let packageSpec { payload["packageSpec"] = packageSpec }
        var operation: RemoteHarnessOperation
        do {
            operation = try await client.request("v1/runtime-maintenance/\(kind.rawValue)/update", method: "POST",
                                                 body: try JSONSerialization.data(withJSONObject: payload), timeout: 960)
        } catch let error as MemberSignedHTTPError {
            if case .http(status: 409, let code, let message) = error,
               code == Self.busyRuntimeError || message.contains(Self.busyRuntimeError) {
                throw FleetBusyError()
            }
            throw error
        }
        progress("Updating \(kind.displayName)…")
        var polls = 0
        while operation.status == "running", polls < 900 {
            try await Task.sleep(for: .seconds(1))
            operation = try await client.request("v1/operations/\(operation.id.uuidString.lowercased())", timeout: 20)
            polls += 1
        }
        if operation.status == "running" { throw BotsError.unavailable("It did not finish in time.") }
        if operation.status == "failed" {
            if operation.error?.contains(Self.busyRuntimeError) == true { throw FleetBusyError() }
            throw BotsError.unavailable(operation.error ?? "The update failed.")
        }
    }

    /// Updates another machine's Pi Durable SDKs.
    func updateMemberSDKs(machineID: String) async throws {
        let client = try await memberClient(machineID: machineID)
        let _: DefaultAgentSDKStatus = try await client.request(
            "v1/default-agent/sdks", method: "POST",
            body: JSONEncoder().encode(DefaultAgentSDKRequest(action: .update)), timeout: 900)
    }
}

/// Another machine's harnesses, as Settings → Updates shows them.
struct FleetMemberInventory: Codable, Equatable, Sendable {
    var runtimes: [RemoteRuntimeMaintenance]
    var sdks: DefaultAgentSDKStatus?
    /// Its Woven server predates harness reporting.
    var unsupported = false
}

/// The harness is in use by chats on that machine.
struct FleetBusyError: LocalizedError {
    /// How the job reports it, so the window can offer to stop those chats.
    static let message = "Chats there are using it."
    var errorDescription: String? { Self.message }
}
