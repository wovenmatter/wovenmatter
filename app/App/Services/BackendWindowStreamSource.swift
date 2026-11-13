import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// What the background server's windows read on their live connection
/// (`ExecutionWindowStreamServer`). A conversation this Mac runs is read from
/// its own tables, exactly as for a member's WebSocket. A conversation another
/// machine runs is relayed from what this server already holds for it: the
/// one WebSocket it keeps to that machine (`CentralExecutionClient`), read
/// again only when that stream pushes or an action finishes. A machine this
/// server cannot reach shows the history library sync brought, marked offline;
/// nothing polls it.
@MainActor
final class BackendWindowStreamSource: ExecutionConversationSource {
    private unowned let model: ApplicationModel
    /// Told when relayed state changed, so its subscriptions compare again.
    var changed: (Set<String>) -> Void = { _ in }
    private enum Kind { case local, remote }
    private var kinds: [String: Kind] = [:]
    private var openCounts: [String: Int] = [:]
    private var snapshots: [String: FederatedExecutionSnapshot] = [:]
    private var failures: [String: String] = [:]
    /// Relayed reads in flight; true when another change arrived meanwhile.
    private var reading: [String: Bool] = [:]

    init(model: ApplicationModel) { self.model = model }

    private var database: WorkspaceDatabase {
        get throws {
            guard let database = model.libraryStore?.database else { throw ApplicationModelError.libraryStoreUnavailable }
            return database
        }
    }

    // MARK: Subscriptions

    func conversationOpened(_ conversationID: String) async throws {
        let kind: Kind
        if let known = kinds[conversationID] { kind = known } else { kind = try await classify(conversationID) }
        kinds[conversationID] = kind
        openCounts[conversationID, default: 0] += 1
        guard kind == .remote, openCounts[conversationID] == 1 else { return }
        // Every chat open in a window stays live, however many are open.
        (try? model.centralExecutionClient())?.hold(conversationID)
        await read(conversationID)
    }

    func conversationClosed(_ conversationID: String) async {
        guard let count = openCounts[conversationID] else { return }
        guard count <= 1 else { openCounts[conversationID] = count - 1; return }
        openCounts.removeValue(forKey: conversationID)
        let kind = kinds.removeValue(forKey: conversationID)
        snapshots.removeValue(forKey: conversationID); failures.removeValue(forKey: conversationID)
        // The background server's own `conversation` subscription ends with the window's.
        if kind == .remote {
            model.federatedExecutionClient?.release(conversationID)
            _ = try? await model.performFederatedExecution(.close(conversationID: conversationID))
        }
    }

    /// A conversation another machine runs, or one this Mac runs; anything
    /// else (OpenCode, remote-workspace and gateway sessions) the window keeps
    /// reading from its projection when `server.state` names it.
    private func classify(_ id: String) async throws -> Kind {
        let database = try database
        if try await database.libraryExecutionOwner(conversationID: id) != nil { return .remote }
        guard let conversation = try await database.libraryConversations(ids: [id])[id], MacExecutionAPI.runsLocally(conversation) else {
            throw LibraryAPIError(code: "wrong_workspace", message: "This conversation is not running on this Mac.")
        }
        return .local
    }

    // MARK: Reads

    func localTranscript(conversationID: String, before: String?) async throws -> LibraryTranscript {
        if kinds[conversationID] == .remote {
            return snapshots[conversationID]?.transcript ?? LibraryTranscript(conversationID: conversationID)
        }
        return try await model.libraryCommands.transcript(conversationID: conversationID, before: before)
    }

    func localCapabilities(conversationID: String) async throws -> HarnessCapabilities {
        if kinds[conversationID] == .remote {
            guard let capability = snapshots[conversationID]?.capability else { throw Self.unavailable }
            return capability
        }
        return try await model.libraryCommands.sessionCapabilities(conversationID: conversationID)
    }

    func localSessionSettings(conversationID: String) async throws -> SessionSettings {
        if kinds[conversationID] == .remote {
            guard let session = snapshots[conversationID]?.session else { throw Self.unavailable }
            return session
        }
        guard case .session(let settings) = try await model.libraryCommands.readWorkspace(.session(id: conversationID)) else { throw Self.unavailable }
        return settings
    }

    func conversationRelay(conversationID: String) async -> ExecutionConversationRelay? {
        guard kinds[conversationID] == .remote else { return nil }
        guard let snapshot = snapshots[conversationID] else {
            return .init(interactions: [], owner: .init(online: false, error: failures[conversationID]))
        }
        return .init(interactions: snapshot.interactions.filter { $0.conversationID == conversationID },
                     owner: .init(online: snapshot.online, error: snapshot.error ?? failures[conversationID]))
    }

    private static let unavailable = LibraryAPIError(code: "unavailable", message: "Not known yet.")

    // MARK: Relay

    /// This server's view of these relayed chats changed (its stream pushed,
    /// or an action finished): read them again, one read at a time per chat.
    func liveChanged(_ ids: Set<String>) {
        for id in ids where openCounts[id] != nil && kinds[id] == .remote {
            if reading[id] != nil { reading[id] = true; continue }
            Task { await self.read(id) }
        }
    }

    private func read(_ id: String) async {
        guard reading[id] == nil else { reading[id] = true; return }
        repeat {
            reading[id] = false
            do {
                let snapshot = try await model.performFederatedExecution(.refresh(conversationID: id))
                guard openCounts[id] != nil else { break }
                snapshots[id] = snapshot; failures.removeValue(forKey: id)
            } catch {
                guard openCounts[id] != nil else { break }
                failures[id] = error.localizedDescription
                let saved = snapshots[id] == nil ? await model.federatedSnapshotAfterFailure(id) : nil
                if var snapshot = snapshots[id] ?? saved {
                    snapshot.online = false; snapshot.error = error.localizedDescription
                    snapshots[id] = snapshot
                }
            }
        } while reading[id] == true
        reading.removeValue(forKey: id)
        guard openCounts[id] != nil else { return }
        changed([id])
    }
}

extension ApplicationModel {
    /// The background server's side of its windows' live connection, started
    /// with the first window that connects once the store is open.
    func acceptWindowStream(_ channel: BackendStreamChannel) {
        guard !backendStopping, let database = libraryStore?.database else { channel.close(); return }
        if let server = backendWindowStream { server.accept(channel); return }
        let source = BackendWindowStreamSource(model: self)
        let server = ExecutionWindowStreamServer(database: database, source: source) { [weak self] in
            await self?.windowStreamHello() ?? StreamHello(deviceID: "", libraryID: "", workspaceID: "", serverTime: MemberRequestSignature.now())
        }
        source.changed = { [weak server] ids in server?.liveStateChanged(conversationIDs: ids) }
        backendWindowSource = source
        backendWindowStream = server
        // Every invalidation reaches the windows as `server.state`; settings
        // and runtime changes also mean session state may have changed.
        let feed = server.serverState, journal = backendApplicationService?.invalidations
        server.accept(channel)
        Task {
            await journal?.setListener { scopes, conversationIDs in
                await feed.publish(StreamServerState(scopes: scopes.map(\.rawValue).sorted(),
                    conversationIDs: conversationIDs.isEmpty ? nil : conversationIDs.sorted()))
                if !scopes.isDisjoint(with: [.settings, .runtime, .permissions]) {
                    server.liveStateChanged(conversationIDs: conversationIDs)
                }
            }
            await server.start()
        }
    }

    /// A relayed chat's state changed in this server.
    func windowStreamRelayChanged(_ ids: Set<String>) {
        backendWindowSource?.liveChanged(ids)
    }

    private func windowStreamHello() async -> StreamHello {
        let identity = try? await libraryStore?.database.libraryIdentity()
        let libraryID = identity?.libraryID ?? ""
        return StreamHello(deviceID: identity?.hostDeviceID ?? "", libraryID: libraryID,
            workspaceID: libraryID.isEmpty ? "" : libraryHost.localExecutionWorkspaceID(libraryID: libraryID),
            serverTime: MemberRequestSignature.now(), capabilities: [StreamProtocol.capability, StreamProtocol.Stream.serverState.rawValue])
    }
}
