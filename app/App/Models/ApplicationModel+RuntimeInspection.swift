import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    func runtimeInspection(_ query: RuntimeInspectionRequest = .init()) async throws -> RuntimeInspection {
        if isBackendFrontend {
            return try JSONDecoder().decode(RuntimeInspection.self,
                from: await callBackend(method: "server.inspect", payload: JSONEncoder().encode(query)))
        }
        let conversation = query.conversationID.flatMap { id in workspaceOverview?.conversations.first { $0.id == id } }
        if let workspaceID = query.workspaceID ?? conversation?.remoteWorkspaceID {
            guard let configuration = remoteWorkspaces.configuration(id: workspaceID) else {
                throw BackendRPCError.remote("This workspace is no longer configured.")
            }
            var snapshot = try await remoteWorkspaces.inspectRuntime(configuration)
            if let id = query.conversationID {
                guard let native = localACPSessionMetadata[id]?.sessionKey else {
                    snapshot.items = snapshot.items.filter { $0.kind == "service" }
                    snapshot.items.append(.init(id: "chat:" + id, conversationID: id, kind: "conversation",
                        title: conversation?.title ?? "Chat", state: "unknown", detail: "No live native session binding is available for this chat."))
                    return snapshot
                }
                snapshot.items = snapshot.items.filter { $0.kind == "service" || $0.nativeSessionID == native }
            }
            return snapshot
        }
        let root = "server:mac"
        var items: [RuntimeInspection.Item] = [
            .init(id: root, kind: "service", title: DevelopmentLaunch.mode == nil ? "Background Server" : "Development background server",
                  state: backendStopping ? "stopping" : "running", processID: ProcessInfo.processInfo.processIdentifier)
        ]
        let processes = LocalACPClient.inspectionItems()
        if query.conversationID == nil {
            items += CompanionTailscaleServe.inspectionItems().map { var item = $0; item.parentID = root; return item }
        }
        items += processes.filter { query.conversationID == nil || $0.conversationID == query.conversationID }
            .map { var item = $0; item.parentID = item.conversationID.map { "chat:" + $0 } ?? root; return item }
        let ids = query.conversationID.map { Set([$0]) }
            ?? runningToolSessionIDs.union(processes.compactMap(\.conversationID))
        for id in ids.sorted().prefix(128) {
            let conversation = workspaceOverview?.conversations.first { $0.id == id }
            if query.conversationID != nil, conversation == nil { throw BackendRPCError.remote("This chat is unavailable.") }
            items.append(.init(id: "chat:" + id, parentID: root, conversationID: id, kind: "conversation",
                title: conversation?.title ?? "Chat", state: runningToolSessionIDs.contains(id) ? "working" : "idle",
                detail: localACPSessionMetadata[id]?.model))
            // Query the owner's bounded history window, independent of whether a
            // particular frontend has opened or refreshed this conversation.
            if let page = try await dashboardStore?.conversationHistoryPage(id: id, limit: 40, compactActivities: false) {
                for record in page.activities.suffix(100) where items.count < 1_000 {
                    let activity = record.activity
                    if let children = activity.subagents {
                        items += children.prefix(max(0, 1_000 - items.count)).map { .init(id: "child:" + id + ":" + $0.id, parentID: "chat:" + id,
                            conversationID: id, kind: "subagent", title: $0.name ?? "Subagent",
                            state: runningToolSessionIDs.contains(id) ? ($0.executionStatus ?? $0.state ?? "unknown") : "recorded", detail: $0.modelID) }
                    } else if activity.toolName != nil {
                        items.append(.init(id: "tool:" + record.id, parentID: "chat:" + id,
                            conversationID: id, kind: "tool", title: activity.toolName ?? "Tool",
                            state: runningToolSessionIDs.contains(id) ? (activity.status ?? "unknown") : "recorded", detail: activity.detail.map { ProgramStatus.message($0) ?? "" }))
                    }
                }
            }
        }
        var unique: [String: RuntimeInspection.Item] = [:]
        for item in items { unique[item.id] = item }
        let observed = await RuntimeProcessMetrics.sample(unique.values.sorted { $0.id < $1.id }, includeServerDescendants: query.conversationID == nil)
        return .init(ownerID: "mac", items: observed)
    }

    func stopBackgroundServer(confirmed: Bool) async throws -> BackgroundServerStopResult {
        guard isBackendFrontend else { throw BackendRPCError.remote("This isolated development host stops when you close its app.") }
        return try JSONDecoder().decode(BackgroundServerStopResult.self,
            from: await callBackend(method: "server.stop", payload: JSONEncoder().encode(BackgroundServerStopRequest(confirmed: confirmed))))
    }

    func startBackgroundServer() async throws {
        // The connection path performs one launch only when no owner answers.
        await startBackendClient()
        if case let .failed(message) = state { throw BackendRPCError.remote(message) }
    }
}
