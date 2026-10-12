import CompanionClient
import Foundation
import WovenMatterCompanion
import WovenMatterDashboardStore

/// Shared replica reads do not import foreign execution identities into the
/// native database. All lifecycle commands still use the native session tools.
@MainActor
final class SecondaryMacReplicaTools {
    private unowned let model: ApplicationModel
    private let replica: MobileStore
    private let workspaceID: String
    init(model: ApplicationModel, replica: MobileStore, workspaceID: String) {
        self.model = model; self.replica = replica; self.workspaceID = workspaceID
    }
    func read(_ request: WovenMatterToolRequest, command: WovenMatterToolCommand, callerID: String,
              refreshLocal: @MainActor () async throws -> Void) async throws -> WovenMatterToolResponse? {
        guard !command.isMutation, let group = command.group,
              [.history, .sessions, .library, .usage].contains(group), let database = model.dashboardStore?.database else { return nil }
        if group == .sessions, !["list", "status"].contains(command.action) { return nil }
        // This adapter never grants access to a remote/replica caller identity.
        _ = try await database.localACPSession(conversationID: callerID)
        let tools = try await database.sessionTools(callerID)
        // Native history retains its narrower own-session/attachment exceptions.
        // Browsing other devices' cached history requires the actual history tool.
        if group == .history, !tools.enabled.contains(.history) { return nil }
        try await database.requireTool(group, sessionID: callerID)
        let snapshot = try await database.companionSnapshot()
        guard let caller = snapshot.conversations.first(where: { $0.id == callerID }) else { throw WorkspaceToolError.notFound("The native caller is no longer available.") }
        let nativeIDs = Set(snapshot.conversations.map(\.id))
        let explicit = command.options["conversation"] ?? (["conversation", "status"].contains(command.action) ? command.options["id"] ?? command.positional.first : nil)
        if let explicit, nativeIDs.contains(explicit) { return nil }
        if group == .history, ["folders", "harnesses"].contains(command.action) { return nil }
        try await refreshLocal()
        // Recheck after the refresh's actor suspensions; user selection is final.
        try await database.requireTool(group, sessionID: callerID)
        let context = MobileToolContext(sessionID: callerID, workspaceID: workspaceID, folderID: caller.folderID, enabled: tools.enabled)
        if group == .library { return try await library(request, command: command, context: context) }
        if group == .usage { return try await usage(command) }
        if group == .history, ["message", "event", "trace"].contains(command.action) {
            let journal = await replica.journal.snapshot()
            let id = command.options["id"] ?? command.options["run"] ?? command.positional.first
            if command.action == "message", let id {
                let cachedState = await replica.snapshot()
                let isForeign = journal.transcripts.values.contains { transcript in
                    !nativeIDs.contains(transcript.conversationID) && transcript.messages.contains { $0.id == id }
                } || cachedState.transcripts.values.contains { transcript in
                    !nativeIDs.contains(transcript.conversationID) && transcript.messages.contains { $0.id == id }
                }
                if !isForeign { return nil }
            } else if let id, !journal.entries.values.contains(where: {
                $0.workspaceID != workspaceID && (command.action == "event" ? $0.eventID == id : $0.runID == id)
            }) { return nil }
        }
        return await replica.executeLocalTool(request, context: context)
    }
    private func library(_ request: WovenMatterToolRequest, command: WovenMatterToolCommand, context: MobileToolContext) async throws -> WovenMatterToolResponse {
        guard let native = model.agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
        let manifests = await replica.artifacts.manifests().filter { !$0.deleted }
        if command.action == "read" {
            let id = try command.required("id", allowPositional: true)
            if manifests.contains(where: { $0.id == id }) { return await replica.executeLocalTool(request, context: context) }
            return try await native.library(command, callerID: context.sessionID)
        }
        // Cached manifests do not contain these native attribution fields. They
        // cannot truthfully match a query that explicitly requires attribution.
        if ["harness", "sender", "since", "until"].contains(where: { command.options[$0] != nil }) {
            let result = try await native.library(command, callerID: context.sessionID)
            guard var value = result.result?.objectValue else { return result }
            value["replicaAttributionUnavailable"] = .bool(!manifests.isEmpty)
            return .init(success: result.success, result: .object(value), error: result.error, code: result.code, requestID: request.requestID)
        }
        let search = command.options["search"] ?? ""
        let workspaces = command.options["workspace"].map { Set($0.split(separator: ",").map(String.init)) }
        let kind = command.options["kind"]
        guard kind == nil || ["photo", "file", "link"].contains(kind!) else { throw WorkspaceToolError.invalid("Use file, link, or photo.") }
        let cached = manifests.filter {
            $0.workspaceID != workspaceID &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) &&
            (workspaces == nil || workspaces!.contains($0.workspaceID)) &&
            (kind == nil || (kind == "file" && !$0.mediaType.hasPrefix("image/")) || (kind == "photo" && $0.mediaType.hasPrefix("image/")))
        }.sorted { $0.id < $1.id }
        let offset = try command.integer("offset", default: 0, range: 0...Int.max)
        let limit = try command.integer("limit", default: 100, range: 1...200)
        var items = try cached.dropFirst(offset).prefix(limit).map(MobileToolSupport.value)
        let remaining = limit - items.count
        let nativeCommand = try paged(command, offset: max(0, offset - cached.count), limit: max(1, remaining))
        let page = try await native.library(nativeCommand, callerID: context.sessionID).result?.objectValue ?? [:]
        let nativeItems = page["items"]?.arrayValue ?? []
        if remaining > 0 { items += nativeItems }
        let moreCached = offset < cached.count && items.count < cached.count - offset
        let moreNative = remaining == 0 ? !nativeItems.isEmpty : page["hasMore"] == .bool(true)
        return .init(result: .object(["available": .bool(true), "items": .array(items), "hasMore": .bool(moreCached || moreNative),
            "nextOffset": .number(Double(offset + items.count))]), requestID: request.requestID)
    }
    private func usage(_ command: WovenMatterToolCommand) async throws -> WovenMatterToolResponse {
        let from = try command.options["since"].map(MobileToolSupport.date) ?? .distantPast
        let to = try command.options["until"].map(MobileToolSupport.date) ?? Date()
        guard to >= from else { throw WorkspaceToolError.invalid("--until must be at or after --since.") }
        let journal = await replica.journal.snapshot()
        var cached: [CompanionUsageSample] = []
        for workspace in journal.workspaces.values where workspace.id != workspaceID {
            var samples = try DeviceUsageProjection.samples(in: journal, workspaceID: workspace.id, from: from, to: to)
            for index in samples.indices { samples[index].workspace = workspace.name }
            cached += samples
        }
        cached.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
        let offset = try command.integer("offset", default: 0, range: 0...(Int.max - 1))
        let limit = try command.integer("limit", default: 100, range: 1...200)
        var samples = try cached.dropFirst(offset).prefix(limit).map(MobileToolSupport.value)
        let remaining = limit - samples.count
        let native = try await model.handleAgentUsage(paged(command, offset: max(0, offset - cached.count), limit: max(1, remaining)))
        var value = native.result?.objectValue ?? [:]
        let nativeSamples = value["samples"]?.arrayValue ?? []
        if remaining > 0 { samples += nativeSamples }
        var moreNative = remaining == 0 ? !nativeSamples.isEmpty : false
        if remaining > 0, nativeSamples.count == remaining {
            let next = try await model.handleAgentUsage(paged(command, offset: max(0, offset - cached.count) + nativeSamples.count, limit: 1))
            moreNative = next.result?.objectValue?["samples"]?.arrayValue?.isEmpty == false
        }
        value["samples"] = .array(samples)
        value["hasMore"] = .bool((offset < cached.count && samples.count < cached.count - offset) || moreNative)
        value["nextOffset"] = .number(Double(offset + samples.count))
        return .init(result: .object(value))
    }
    private func paged(_ command: WovenMatterToolCommand, offset: Int, limit: Int) throws -> WovenMatterToolCommand {
        var arguments = command.operationArguments, index = 0
        while index < arguments.count {
            if ["--offset", "--limit"].contains(arguments[index]) { arguments.removeSubrange(index...min(index + 1, arguments.count - 1)) }
            else { index += 1 }
        }
        arguments += ["--offset", String(offset), "--limit", String(limit)]
        return try WovenMatterToolCommand(arguments)
    }
}
