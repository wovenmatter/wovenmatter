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

    /// A signed Mac member's request. Phones don't manage harnesses. Every answer comes
    /// well inside the Mac server's 60-second response limit: an update answers at once
    /// with a running operation that the caller follows at `/v1/operations/:id`, as on a
    /// Linux host, and a check answers with what it has after 15 seconds.
    func memberMaintenance(_ request: LibraryHTTPRequest, path: String) async -> LibraryHTTPResponse {
        do {
            if path.hasPrefix("/v1/operations/") {
                let id = path.dropFirst("/v1/operations/".count)
                guard request.method == "GET", let uuid = UUID(uuidString: String(id)),
                      let operation = MemberMaintenanceStore.operations[uuid] else {
                    return .error("not_found", "Unknown operation.", status: 404)
                }
                return try .json(operation)
            }
            if path == "/v1/default-agent/sdks" {
                let command = request.method == "GET" ? DefaultAgentSDKRequest(action: .status)
                    : try JSONDecoder().decode(DefaultAgentSDKRequest.self, from: request.body)
                switch command.action {
                case .status: return try .json(try await DefaultAgentSDKControl.run(command))
                case .check: return try .json(try await boundedSDKCheck())
                case .update: return try .json(startMemberOperation(.defaultAgent) { [self] in await updateLocalSDKsForMember() }, status: 202)
                }
            }
            switch (request.method, path) {
            case ("GET", "/v1/runtime-maintenance"):
                return try .json(MaintenanceDocument(runtimes: localMaintenanceRows()))
            case ("POST", "/v1/runtime-maintenance/check"):
                refreshRuntimeInventory()
                await waitForRuntime(timeout: .seconds(15)) { !self.checkingRuntimeInventory && self.checkingRuntimeKinds.isEmpty }
                return try .json(MaintenanceDocument(runtimes: localMaintenanceRows()))
            default:
                break
            }
            let parts = path.split(separator: "/").map(String.init)
            guard request.method == "POST", parts.count == 4, parts[1] == "runtime-maintenance",
                  let kind = AgentRuntimeKind(rawValue: parts[2]),
                  Self.fleetHarnessKinds.contains(kind) || (kind == .defaultAgent && parts[3] == "update") else {
                return .error("not_found", "Unknown maintenance route.", status: 404)
            }
            switch parts[3] {
            case "check":
                checkRuntimeUpdate(kind)
                await waitForRuntime(timeout: .seconds(15)) { !self.checkingRuntimeKinds.contains(kind) }
                return try .json(maintenanceRow(kind))
            case "update" where kind == .defaultAgent:
                return try .json(startMemberOperation(.defaultAgent) { [self] in await updateLocalSDKsForMember() }, status: 202)
            case "update":
                struct Body: Decodable { var force: Bool? }
                let force = (try? JSONDecoder().decode(Body.self, from: request.body))?.force ?? false
                return try .json(startMemberOperation(kind) { [self] in await updateLocalRuntimeForMember(kind, force: force) }, status: 202)
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

    /// Records a running operation, runs `work` past the reply, and records how it ended.
    private func startMemberOperation(_ kind: AgentRuntimeKind, _ work: @escaping @MainActor () async -> String?) -> RemoteHarnessOperation {
        let started = Self.timestamp()
        let operation = RemoteHarnessOperation(id: UUID(), harnessID: kind, action: "update", status: "running", startedAt: started)
        MemberMaintenanceStore.record(operation)
        Task { @MainActor in
            let error = await work()
            MemberMaintenanceStore.record(.init(id: operation.id, harnessID: kind, action: "update",
                                                status: error == nil ? "succeeded" : "failed", error: error,
                                                startedAt: started, finishedAt: Self.timestamp()))
        }
        return operation
    }

    /// Updates one harness to the end; nil on success. A busy harness is refused unless
    /// `force`, which stops the chats using harnesses here first.
    private func updateLocalRuntimeForMember(_ kind: AgentRuntimeKind, force: Bool) async -> String? {
        if localRuntimeMaintenanceHasActiveConversation {
            guard force else { return Self.busyRuntimeError }
            await stopLocalRuntimeConversations()
            guard !localRuntimeMaintenanceHasActiveConversation else { return Self.busyRuntimeError }
        }
        updateRuntime(kind)
        await waitForRuntime(timeout: .seconds(10)) { self.updatingRuntimeKinds.contains(kind) }
        await waitForRuntime(timeout: .seconds(900)) { !self.updatingRuntimeKinds.contains(kind) && !self.runtimeMaintenanceBusy(kind) }
        if failedRuntimeUpdateKinds.contains(kind) { return runtimeFailureDetails[kind] ?? "The update failed." }
        if runtimeInventories[kind]?.updateAvailable == true { return "It is still out of date." }
        return nil
    }

    private func updateLocalSDKsForMember() async -> String? {
        do {
            let status = try await DefaultAgentSDKControl.run(.init(action: .update))
            connections.invalidateSDKCatalog(scopeKey: "local")
            return status.sdks.contains { $0.updateAvailable } ? "It is still out of date." : nil
        } catch { return error.localizedDescription }
    }

    /// A check that answers within 15 seconds: the fresh result when it's ready, else the
    /// installed versions while the check finishes for next time.
    private func boundedSDKCheck() async throws -> DefaultAgentSDKStatus {
        let check = MemberMaintenanceStore.sdkCheck ?? Task { @MainActor in
            defer { MemberMaintenanceStore.sdkCheck = nil }
            return try await DefaultAgentSDKControl.run(.init(action: .check))
        }
        MemberMaintenanceStore.sdkCheck = check
        let deadline = ContinuousClock.now + .seconds(15)
        while MemberMaintenanceStore.sdkCheck != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if MemberMaintenanceStore.sdkCheck == nil, let status = try? await check.value { return status }
        return try await DefaultAgentSDKControl.run(.init(action: .status))
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
    private func memberClient(machineID: String) async throws -> (client: MemberSignedHTTPClient, isMac: Bool) {
        guard let target = await memberBotTargets().first(where: { $0.audience == machineID.lowercased() }) else {
            throw BotsError.unavailable("That machine isn't reachable from this Mac right now.")
        }
        return (try await botsClient(for: target.workspace), target.workspace.kind == .mac)
    }

    /// A Mac from before these routes answers 404, or 426 from its library API.
    private static func predatesRoutes(_ error: MemberSignedHTTPError) -> Bool {
        if case .http(let status, _, _) = error { return status == 404 || status == 426 }
        return false
    }

    /// Another machine's harnesses and Pi Durable SDKs. A machine that predates these
    /// routes answers 404, reported as needing an update.
    func memberInventory(machineID: String, checkLatest: Bool) async throws -> FleetMemberInventory {
        let client = try await memberClient(machineID: machineID).client
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
            if Self.predatesRoutes(error) { return .init(runtimes: [], sdks: nil, unsupported: true) }
            // A bots-only Linux host has no workspace, so no harnesses.
            if case .http(status: 409, let code, _) = error, code == "workspace_disabled" { return .init(runtimes: [], sdks: nil) }
            throw error
        }
    }

    /// The download a Linux host would run for this update; nil for a Mac, whose
    /// harnesses update from their package registries with integrity checks.
    func memberInstallerPreview(machineID: String, kind: AgentRuntimeKind) async throws -> RemoteInstallerPreview? {
        let (client, isMac) = try await memberClient(machineID: machineID)
        guard !isMac else { return nil }
        do {
            return try await client.request("v1/harnesses/\(kind.rawValue)/install-preview", timeout: 25)
        } catch let error as MemberSignedHTTPError {
            if Self.predatesRoutes(error) { return nil }
            throw error
        }
    }

    /// Updates a harness on another machine and follows it to the end. A Linux host
    /// verifies the reviewed download; a Mac stops its chats first when `force`.
    func updateMemberHarness(machineID: String, kind: AgentRuntimeKind, sourceSHA256: String?, packageSpec: String?,
                             force: Bool, progress: @escaping @MainActor (String) -> Void) async throws {
        let client = try await memberClient(machineID: machineID).client
        var payload: [String: Any] = ["confirmed": true, "force": force]
        if let sourceSHA256 { payload["sourceSHA256"] = sourceSHA256 }
        if let packageSpec { payload["packageSpec"] = packageSpec }
        var operation: RemoteHarnessOperation
        do {
            operation = try await client.request("v1/runtime-maintenance/\(kind.rawValue)/update", method: "POST",
                                                 body: try JSONSerialization.data(withJSONObject: payload), timeout: 30)
        } catch let error as MemberSignedHTTPError {
            if case .http(status: 409, let code, let message) = error,
               code == Self.busyRuntimeError || message.contains(Self.busyRuntimeError) {
                throw FleetBusyError()
            }
            throw error
        }
        progress("Updating \(kind.displayName)…")
        try await follow(operation, client: client)
    }

    /// Polls an operation until it ends; throws how it failed.
    private func follow(_ started: RemoteHarnessOperation, client: MemberSignedHTTPClient) async throws {
        var operation = started, polls = 0
        while operation.status == "running", polls < 1_000 {
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

    /// Updates another machine's Pi Durable SDKs: a Mac answers with an operation to
    /// follow; a Linux host updates within the request.
    func updateMemberSDKs(machineID: String) async throws {
        let (client, isMac) = try await memberClient(machineID: machineID)
        if isMac {
            let operation: RemoteHarnessOperation = try await client.request(
                "v1/runtime-maintenance/default_agent/update", method: "POST", body: Data("{}".utf8), timeout: 30)
            try await follow(operation, client: client)
            return
        }
        let _: DefaultAgentSDKStatus = try await client.request(
            "v1/default-agent/sdks", method: "POST",
            body: JSONEncoder().encode(DefaultAgentSDKRequest(action: .update)), timeout: 590)
    }
}

/// Operations other Macs started here, and a Pi Durable SDK check in flight.
@MainActor
enum MemberMaintenanceStore {
    private(set) static var operations: [UUID: RemoteHarnessOperation] = [:]
    static var sdkCheck: Task<DefaultAgentSDKStatus, any Error>?

    static func record(_ operation: RemoteHarnessOperation) {
        operations[operation.id] = operation
        // Keep the recent ones; a caller follows its own within minutes.
        if operations.count > 50, let oldest = operations.values.filter({ $0.status != "running" })
            .min(by: { $0.startedAt < $1.startedAt }) {
            operations[oldest.id] = nil
        }
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
