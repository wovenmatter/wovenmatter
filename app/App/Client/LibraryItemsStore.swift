#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation
import WovenProtocol

/// Files, links and saved artifacts agents produced, as the Library page lists them.
@MainActor
@Observable
final class LibraryItemsStore {
    /// The items that match the last query, newest first unless it asked otherwise.
    private(set) var items: [WorkspaceLibraryItem] = []
    /// Every machine and agent that has items, for the filters.
    private(set) var facets: [LibraryFacet] = []
    private(set) var hasMore = false
    private(set) var loading = false
    /// The last command that failed, until dismissed.
    private(set) var error: String?
    /// Why the list could not be read.
    private(set) var loadError: String?

    let savedArtifacts = SavedArtifactsStore()

    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var machines: MachinesStore?
    /// The server's item behind each listed item, by `WorkspaceLibraryItem.id`.
    @ObservationIgnored private var entries: [String: WovenProtocol.LibraryItem] = [:]
    /// The server's agent behind each facet, by `LibraryFacet.agentID`.
    @ObservationIgnored private var agentsByID: [String: LibraryAgent] = [:]
    @ObservationIgnored private var generation = 0

    init() {}

    func attach(_ server: ServerConnection, machines: MachinesStore) {
        self.server = server
        self.machines = machines
        savedArtifacts.attach(server, machines: machines)
    }

    /// The day the date filters count from.
    var today: Date { Date() }

    /// Reads items matching `query`. `more` asks for the next page; `preserveCount`
    /// keeps as many items as are already shown.
    func load(query: LibraryQuery, more: Bool = false, preserveCount: Bool = false) async {
        generation += 1
        let current = generation
        guard let server, server.isConnected else {
            loadError = ClientError.notConnected.localizedDescription
            return
        }
        loading = true
        defer { if current == generation { loading = false } }
        let pageSize = 100
        let request = ListLibraryItems(
            machineIDs: query.machines.map { Array($0) },
            runtimes: query.harnesses.map { $0.map(Self.runtime(harness:)) },
            agents: query.agents.map { $0.compactMap { agentsByID[$0] } },
            fromPerson: query.sender.map { $0 == .me },
            kind: query.kind, since: query.since, until: query.until,
            search: query.search, oldestFirst: query.oldestFirst,
            offset: more ? items.count : 0,
            limit: more || !preserveCount ? pageSize : min(500, max(pageSize, items.count)))
        do {
            let page = try await server.call(request)
            guard current == generation else { return }
            for item in page.items { entries[Self.identifier(item)] = item }
            let mapped = page.items.map(workspaceItem)
            items = more ? items + mapped : mapped
            hasMore = page.more
            facets = page.agents.map(facet)
            for agent in page.agents { agentsByID[Self.agentID(agent)] = agent }
            loadError = nil
        } catch {
            guard current == generation else { return }
            loadError = DatabasesStore.message(error)
        }
    }

    /// Opens a web link in the browser, or the item's file in the preview.
    func open(_ item: WorkspaceLibraryItem, onOpenFile: @escaping @MainActor (URL, String?) -> Void) {
        if item.storage == .link, item.isWebLink, let url = URL(string: item.source) {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
            return
        }
        Task {
            do {
                onOpenFile(try await fileURL(id: item.id), nil)
            } catch {
                self.error = DatabasesStore.message(error)
            }
        }
    }

    func dismissError() {
        error = nil
        loadError = nil
    }

    /// The message an item was sent in, for a chat that is no longer listed.
    func sourceMessage(id: String) async throws -> String {
        let entry = try await entry(id: id)
        guard let server, server.isConnected else { throw ClientError.notConnected }
        var after = 0
        while true {
            let page = try await server.call(SessionItems(sessionID: entry.sessionID, afterSequence: after, limit: 500))
            if let item = page.first(where: { $0.id == entry.sessionItemID }) {
                switch item.content {
                case .userMessage(let text, _), .assistantMessage(let text): return text
                default: throw LibraryFailure(message: "That message has no text.")
                }
            }
            guard let last = page.last else { break }
            after = last.sequence
        }
        throw LibraryFailure(message: "That message is no longer in its chat.")
    }

    /// A local copy of an item's file, fetched by its content.
    func fileURL(id: String) async throws -> URL {
        let entry = try await entry(id: id)
        if let attachment = entry.attachment {
            return try await ContentFiles.file(digest: attachment.digest, name: attachment.name, server: server)
        }
        if let path = localPath(entry) { return URL(fileURLWithPath: path) }
        throw LibraryFailure(message: "This file is not on this Mac.")
    }

    /// A local copy of a message attachment, fetched by its content digest.
    func attachmentURL(contentHash: String, fileName: String, mimeType: String,
                       remoteConversationID: String? = nil) async throws -> URL {
        try await ContentFiles.file(digest: contentHash, name: fileName, server: server)
    }

    // MARK: Mapping

    private func entry(id: String) async throws -> WovenProtocol.LibraryItem {
        if let entry = entries[id] { return entry }
        guard let server, server.isConnected else { throw ClientError.notConnected }
        for item in try await Self.allItems(server) { entries[Self.identifier(item)] = item }
        guard let entry = entries[id] else { throw LibraryFailure(message: "That item is no longer in the Library.") }
        return entry
    }

    /// Every library item, oldest first.
    static func allItems(_ server: ServerConnection) async throws -> [WovenProtocol.LibraryItem] {
        var items: [WovenProtocol.LibraryItem] = []
        while true {
            let page = try await server.call(ListLibraryItems(oldestFirst: true, offset: items.count, limit: 500))
            items += page.items
            if !page.more || page.items.isEmpty { return items }
        }
    }

    private static func identifier(_ item: WovenProtocol.LibraryItem) -> String {
        WorkspaceLibraryItem.identifier(messageID: item.sessionItemID, source: item.source)
    }

    private static func agentID(_ agent: LibraryAgent) -> String {
        if let kind = AgentRuntimeKind(runtime: agent.runtime) { return WorkspaceAgent.id(machineID: agent.machineID, runtime: kind) }
        return agent.machineID + "/" + agent.runtime.rawValue
    }

    private static func harness(_ runtime: RuntimeKind) -> String {
        AgentRuntimeKind(runtime: runtime)?.rawValue ?? runtime.rawValue
    }

    private static func runtime(harness: String) -> RuntimeKind {
        AgentRuntimeKind(rawValue: harness)?.runtime ?? RuntimeKind(rawValue: harness)
    }

    private func machineName(_ id: String) -> String {
        machines?.machine(id: id)?.name ?? id
    }

    /// A file path the item names that exists on this Mac, for an item from this Mac's sessions.
    private func localPath(_ item: WovenProtocol.LibraryItem) -> String? {
        guard item.agent.machineID == machines?.thisMachine?.id,
              let path = LibraryFileReference.path(item.source), path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private func facet(_ agent: LibraryAgent) -> LibraryFacet {
        LibraryFacet(machineID: agent.machineID, machineName: machineName(agent.machineID),
                     harness: Self.harness(agent.runtime), agentID: Self.agentID(agent),
                     agentName: AgentRuntimeKind(runtime: agent.runtime)?.displayName ?? agent.runtime.rawValue)
    }

    private func workspaceItem(_ item: WovenProtocol.LibraryItem) -> WorkspaceLibraryItem {
        let isWebLink = ["http", "https"].contains(URL(string: item.source)?.scheme?.lowercased() ?? "")
        let storage: LibraryStorage, hasContent: Bool
        if item.attachment != nil {
            (storage, hasContent) = (.attachment, true)
        } else if isWebLink {
            (storage, hasContent) = (.link, false)
        } else if localPath(item) != nil {
            (storage, hasContent) = (.retained, true)
        } else {
            (storage, hasContent) = (.unavailable, false)
        }
        let facet = facet(item.agent)
        return WorkspaceLibraryItem(
            id: Self.identifier(item), conversationID: item.sessionID, messageID: item.sessionItemID,
            conversationTitle: item.sessionTitle, machineID: facet.machineID, machineName: facet.machineName,
            harness: facet.harness, agentID: facet.agentID, agentName: facet.agentName,
            sender: item.fromPerson ? .me : .agent, kind: item.kind, title: item.title, source: item.source,
            sentAt: item.sentAt, hasContent: hasContent, storage: storage, error: nil)
    }
}

/// Files agents saved on any machine, as Saved Artifacts lists them: every
/// distinct file sent in a chat, by its content.
@MainActor
@Observable
final class SavedArtifactsStore {
    private(set) var items: [SavedArtifactLibraryItem] = []
    private(set) var loading = false
    /// Items whose file is being fetched to this Mac.
    private(set) var preparing: Set<String> = []
    var error: String?

    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var machines: MachinesStore?

    init() {}

    func attach(_ server: ServerConnection, machines: MachinesStore) {
        self.server = server
        self.machines = machines
    }

    func refresh() async {
        guard let server, server.isConnected, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var seen = Set<String>()
            var result: [SavedArtifactLibraryItem] = []
            for item in try await LibraryItemsStore.allItems(server).reversed() {
                guard let attachment = item.attachment, seen.insert(attachment.digest).inserted else { continue }
                let machineID = item.agent.machineID
                result.append(SavedArtifactLibraryItem(
                    id: attachment.digest, title: attachment.name, mediaType: attachment.mimeType,
                    byteCount: attachment.size, machineID: machineID,
                    machineName: machines?.machine(id: machineID)?.name ?? machineID))
            }
            if result != items { items = result }
        } catch {
            self.error = DatabasesStore.message(error)
        }
    }

    /// A local copy of the item's file, or `nil` with `error` set.
    func prepare(_ item: SavedArtifactLibraryItem) async -> URL? {
        preparing.insert(item.id)
        defer { preparing.remove(item.id) }
        do {
            return try await ContentFiles.file(digest: item.id, name: item.title, server: server)
        } catch {
            self.error = DatabasesStore.message(error)
            return nil
        }
    }

    func open(_ item: SavedArtifactLibraryItem, onOpenFile: @escaping @MainActor (URL, String?) -> Void) async {
        guard let url = await prepare(item) else { return }
        onOpenFile(url, "saved-artifact:" + item.id)
    }
}

/// Files from the content store, fetched in pieces from this Mac's server
/// (which fetches what it lacks from another machine) into a temporary folder.
@MainActor
enum ContentFiles {
    static func file(digest: String, name: String, server: ServerConnection?) async throws -> URL {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appending(path: "Woven Content", directoryHint: .isDirectory)
            .appending(path: safe(digest), directoryHint: .isDirectory)
        let base = safe(name)
        let url = folder.appending(path: base.isEmpty ? "file" : base)
        if fileManager.fileExists(atPath: url.path) { return url }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: ".\(UUID().uuidString)")
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw LibraryFailure(message: "The file could not be saved on this Mac.")
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var offset: Int64 = 0
            while true {
                let chunk = try await server.call(FetchContent(digest: digest, offset: offset))
                try handle.write(contentsOf: chunk.data)
                offset += Int64(chunk.data.count)
                if offset >= chunk.size { break }
                if chunk.data.isEmpty { throw LibraryFailure(message: "The file ended early.") }
            }
            try handle.close()
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: partial)
            } else {
                try fileManager.moveItem(at: partial, to: url)
            }
            return url
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func safe(_ component: String) -> String {
        String(component.map { "/:\0".contains($0) ? "_" : $0 }).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}
