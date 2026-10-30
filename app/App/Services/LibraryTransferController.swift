import AppKit
import CompanionClient
import CryptoKit
import Foundation
import Observation
import Security
import WovenMatterCore
import WovenMatterDashboardStore

struct TransferredLibraryNode: Codable, Sendable {
    let relocation: CompanionLibraryRelocation
    let workspace: CompanionExecutionWorkspace
    let management: CompanionExecutionManagementGrant
}

struct LibraryTransferPresentation: Codable, Sendable {
    var outgoing: CompanionLibraryTransferStatus?
    var incoming: [LibraryTransferReceiver.Session] = []
    var message: String?
    var restartRequired = false
    var invitations: [CompanionDiscoveredPeer] = []
}

/// The UI owns intent; the process holding the database owns the protocol. The
/// durable source commit marker fences the former authority across process loss.
@Observable @MainActor
final class LibraryTransferController {
    private struct Outgoing: Codable {
        var request: CompanionLibraryTransferRequest
        var destination: URL
        var status: CompanionLibraryTransferStatus
        var commitIssued = false
        var workspace: CompanionExecutionWorkspace
        var management: CompanionExecutionManagementGrant
    }
    private weak var model: ApplicationModel?
    private(set) var presentation = LibraryTransferPresentation()
    private var receiver: LibraryTransferReceiver?
    private var destinationDatabase: WorkspaceDatabase?
    private var destinationAuthentication: CompanionAuthentication?
    private var outgoing: Outgoing?
    private var operation: Task<Void, Never>?
    private var ownerRelocationTask: Task<Void, Never>?
    private var restored = false
    private var recoveryServer: CompanionHTTPServer?
    private var recoveryExposure: CompanionTailscaleServe?
    private let network = LibraryTransferNetwork()
    init(model: ApplicationModel) { self.model = model }
    private var root: URL { get throws {
        if let database = model?.dashboardStore?.database { return database.supportDirectory }
        return try ApplicationModel.dashboardSupportDirectory()
    } }
    private var transferRoot: URL { get throws { try root.appending(path: "Library Transfers") } }
    private var outgoingFile: URL { get throws { try transferRoot.appending(path: "outgoing.json") } }
    static func node(in directory: URL) -> TransferredLibraryNode? {
        try? JSONDecoder().decode(TransferredLibraryNode.self, from: Data(contentsOf: directory.appending(path: "library-node.json")))
    }
    static func requiresRecovery(in directory: URL) -> Bool {
        let root = directory.appending(path: "Library Transfers")
        if let value = try? JSONDecoder().decode(Outgoing.self, from: Data(contentsOf: root.appending(path: "outgoing.json"))),
           [.receiving, .verified].contains(value.status.phase) { return true }
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root.appending(path: "received"), includingPropertiesForKeys: nil) else { return false }
        return folders.contains { folder in
            guard let session = try? JSONDecoder().decode(LibraryTransferReceiver.Session.self, from: Data(contentsOf: folder.appending(path: "session.json"))) else { return false }
            return [.receiving, .verified].contains(session.status.phase)
        }
    }
    func startNodeRecoveryListenerIfNeeded() async throws {
        guard model?.isLibraryClient == true, recoveryServer == nil,
              let active = presentation.incoming.first(where: { [.receiving, .verified].contains($0.status.phase) }),
              let endpoint = active.status.destinationEndpoint, let model else { return }
        model.libraryClient.holdForLibraryTransferRecovery()
        await model.libraryClient.initialize()
        let listener = CompanionHTTPServer { [weak self] request in
            guard let self else { return .error("unavailable", "Database transfer recovery is stopped.", status: 503) }
            return await self.handle(request) ?? .error("library_transferring", "Finish the saved database transfer before using this workspace.", status: 503)
        }
        recoveryServer = listener
        let port = try await listener.start(), exposure = CompanionTailscaleServe()
        recoveryExposure = exposure
        _ = try await exposure.start(loopbackPort: port, preferredHTTPSPort: endpoint.port)
    }
    func stopRecoveryListener() async throws {
        recoveryServer?.stop(); recoveryServer = nil
        recoveryExposure?.stop(); try await recoveryExposure?.waitUntilStopped(); recoveryExposure = nil
    }
    private func receiverStore() throws -> LibraryTransferReceiver {
        if let receiver { return receiver }
        let store = try LibraryTransferReceiver(directory: transferRoot.appending(path: "received"))
        receiver = store; return store
    }
    private func save(_ value: Outgoing) throws {
        try LibraryTransferArchive.persist(value, to: outgoingFile)
        outgoing = value; presentation.outgoing = value.status
    }
    func restore() async throws {
        guard !restored else { return }; restored = true
        let store = try receiverStore()
        presentation.incoming = await store.allSessions()
        if let model, let database = model.dashboardStore?.database { try await store.restoreFences(database: database) }
        if FileManager.default.fileExists(atPath: try outgoingFile.path) {
            let value = try JSONDecoder().decode(Outgoing.self, from: Data(contentsOf: try outgoingFile))
            outgoing = value; presentation.outgoing = value.status
            if ![.cancelled, .committed].contains(value.status.phase) {
                if [.receiving, .verified].contains(value.status.phase), let database = model?.dashboardStore?.database {
                    try await database.fenceLibraryTransfer(value.request.id)
                }
            }
        }
    }
    func refresh() async {
        do {
            try await restore(); presentation.incoming = await (try receiverStore()).allSessions()
            retryOwnerRelocations()
        }
        catch { presentation.message = error.localizedDescription }
    }
    private func retryOwnerRelocations() {
        guard ownerRelocationTask == nil, let model, !model.isLibraryClient, !model.isTransferredLibraryNode,
              !model.libraryTransferPaused, let database = model.dashboardStore?.database, let endpoint = model.companionHost.endpoint else { return }
        let sessions = presentation.incoming.filter { $0.status.phase == .committed }
        guard !sessions.isEmpty else { return }
        ownerRelocationTask = Task { [weak self] in
            guard let self else { return }; defer { self.ownerRelocationTask = nil }
            do {
                let file = try self.transferRoot.appending(path: "notified-workspaces.json")
                var notified = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))) ?? []
                let workspaces = try await database.companionExecutionWorkspaces()
                let libraryID = try await database.companionWorkspaceID()
                for session in sessions {
                    let incoming = try await self.receiverStore().incomingDirectory(session.request.id)
                    let grants = try JSONDecoder().decode([CompanionExecutionManagementGrant].self, from: Data(contentsOf: incoming.appending(path: "authority.json")))
                    for grant in grants where workspaces.contains(where: { $0.id == grant.workspaceID && $0.kind == .linux && !$0.deleted && $0.endpoint == grant.endpoint }) {
                        let key = session.request.id + ":" + grant.workspaceID
                        guard !notified.contains(key) else { continue }
                        do {
                            try await model.companionHost.notifyLibraryRelocation(.init(transferID: session.request.id,
                                previousLibraryID: grant.executionLibraryID ?? session.request.sourceLibraryID, endpoint: endpoint, libraryID: libraryID), grant: grant)
                            notified.insert(key); try LibraryTransferArchive.persist(notified, to: file)
                        } catch { /* Offline execution owners keep their journals and retry on the next health refresh. */ }
                    }
                }
            } catch { self.presentation.message = error.localizedDescription }
        }
    }
    func begin(destination peer: CompanionDiscoveredPeer) async {
        do {
            guard operation == nil, outgoing == nil || [.cancelled, .committed].contains(outgoing!.status.phase),
                  peer.advertisement.capabilities?.contains("library.transfer.v1") == true,
                  let model, !model.isLibraryClient, !model.isTransferredLibraryNode,
                  let database = model.dashboardStore?.database, let sourceEndpoint = model.companionHost.endpoint else {
                throw failure("Choose an available Mac running a compatible Woven Matter version.")
            }
            let identity = try await database.companionLibraryIdentity()
            let workspace = try await model.companionHost.prepareLibraryTransferAuthority().first { $0.workspaceID == model.companionHost.transferLocalWorkspaceID(libraryID: identity.libraryID) }
            guard let management = workspace,
                  let descriptor = try await database.companionExecutionWorkspaces().first(where: { $0.id == management.workspaceID }) else { throw failure("This Mac’s execution workspace is not ready.") }
            let id = UUID().uuidString.lowercased(), secret = try LibraryTransferSecretVault.create(id)
            let digest = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
            let request = CompanionLibraryTransferRequest(id: id,
                source: .init(deviceID: identity.hostDeviceID, deviceName: Host.current().localizedName ?? "This Mac", metadata: CompanionMacPairingController.metadata),
                sourceEndpoint: sourceEndpoint, sourceLibraryID: identity.libraryID,
                destinationDeviceID: peer.advertisement.identity.deviceID, secretDigest: digest)
            try save(.init(request: request, destination: peer.endpoint, status: .init(id: id, phase: .awaitingApproval), workspace: descriptor, management: management))
            presentation.message = "Approve the database transfer on \(peer.advertisement.identity.deviceName)."
            resume()
        } catch { presentation.message = error.localizedDescription }
    }
    func resume() {
        guard operation == nil, outgoing != nil else { return }
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            var delay = 2
            while !Task.isCancelled {
                do { try await self.runSource(); return }
                catch is CancellationError { return }
                catch let error as URLError {
                    self.presentation.message = "Waiting for the other Mac to reconnect. The saved transfer will resume automatically. " + error.localizedDescription
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    delay = min(delay * 2, 30)
                }
                catch { self.presentation.message = error.localizedDescription; return }
            }
        }
    }
    func resumeIfNeeded() {
        if let outgoing, ![.cancelled, .committed].contains(outgoing.status.phase) { resume() }
    }
    private func runSource() async throws {
        guard var value = outgoing, let model, let database = model.dashboardStore?.database else { throw failure("This Mac’s database is unavailable.") }
        let id = value.request.id, secret = try LibraryTransferSecretVault.load(id)
        var status: CompanionLibraryTransferStatus = try await network.request(value.destination, path: "v1/library-transfer/request", body: JSONEncoder().encode(value.request))
        while status.phase == .awaitingApproval {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            status = try await network.request(value.destination, path: "v1/library-transfer/\(id)/status", secret: secret)
        }
        guard status.phase != .cancelled else { try await finishSourceCancellation(value); return }
        if !value.commitIssued {
            if [.receiving, .verified].contains(value.status.phase) { model.pauseLibraryTransferRuntimeForRecovery() }
            else { try await model.prepareForLibraryTransfer() }
            try await database.fenceLibraryTransfer(id)
            let directory = try transferRoot.appending(path: id)
            let backup = directory.appending(path: "source-backup"), export = directory.appending(path: "export")
            value.status = .init(id: id, phase: .receiving, backupPath: backup.path)
            try save(value)
            try await LibraryTransferArchive.backup(database: database, to: backup)
            let authentication = try await model.companionHost.libraryTransferAuthentication()
            let authBackup = backup.appending(path: "companion-devices.json")
            if !FileManager.default.fileExists(atPath: authBackup.path) { try LibraryTransferArchive.persist(await authentication.transferDevices(), to: authBackup) }
            if !FileManager.default.fileExists(atPath: export.appending(path: "manifest.json").path) {
                if FileManager.default.fileExists(atPath: export.path) { try FileManager.default.removeItem(at: export) }
                try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let projectionDirectory = directory.appending(path: "projection")
                if FileManager.default.fileExists(atPath: projectionDirectory.path) { try FileManager.default.removeItem(at: projectionDirectory) }
                try FileManager.default.createDirectory(at: projectionDirectory, withIntermediateDirectories: true)
                let snapshot = projectionDirectory.appending(path: "workspace.sqlite")
                if !FileManager.default.fileExists(atPath: snapshot.path) { try LibraryTransferSQLite.snapshot(backup.appending(path: "workspace.sqlite"), to: snapshot) }
                let copied = try await WorkspaceDatabase(url: snapshot)
                try await copied.projectLibraryTransferOrigins()
                // Checkpoint the projected export through SQLite's backup API;
                // the source backup remains byte-for-byte untouched.
                let projected = export.appending(path: "workspace.sqlite")
                try? FileManager.default.removeItem(at: projected)
                try await copied.backupLibrary(to: projected)
                let bootstrap = Self.bootstrap(secret)
                try await authentication.provisionTransferredHost(deviceID: value.request.source.deviceID, name: value.request.source.deviceName, token: bootstrap)
                try LibraryTransferArchive.persist(await authentication.transferDevices(), to: export.appending(path: "devices.json"))
                try LibraryTransferArchive.persist(try await model.companionHost.prepareLibraryTransferAuthority(), to: export.appending(path: "authority.json"))
                try LibraryTransferArchive.persist(try await database.libraryTransferAliases(), to: export.appending(path: "lineage.json"))
                for path in LibraryTransferArchive.assetDirectories {
                    let file = backup.appending(path: path), destination = export.appending(path: path)
                    if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: file, to: destination)
                    }
                }
                let manifest = CompanionLibraryTransferManifest(transferID: id, libraryID: value.request.sourceLibraryID, files: try LibraryTransferArchive.files(in: export))
                try LibraryTransferArchive.validate(manifest)
                try LibraryTransferArchive.persist(manifest, to: export.appending(path: "manifest.json"))
            }
            let manifest = try JSONDecoder().decode(CompanionLibraryTransferManifest.self, from: Data(contentsOf: export.appending(path: "manifest.json")))
            if status.phase == .receiving {
                status = try await network.request(value.destination, path: "v1/library-transfer/\(id)/manifest", secret: secret, body: JSONEncoder().encode(manifest))
                for file in manifest.files {
                    let input = try FileHandle(forReadingFrom: export.appending(path: file.path)); defer { try? input.close() }
                    var offset = status.offsets[file.path] ?? 0
                    guard offset >= 0, offset <= file.byteCount else { throw failure("The destination returned an invalid transfer offset.") }
                    try input.seek(toOffset: UInt64(offset))
                    while offset < file.byteCount {
                        try Task.checkCancellation()
                        guard let data = try input.read(upToCount: LibraryTransferArchive.chunkBytes), !data.isEmpty else { throw failure("The retained transfer snapshot is incomplete.") }
                        let next: CompanionLibraryTransferStatus = try await network.request(value.destination, path: "v1/library-transfer/\(id)/chunk", secret: secret,
                            body: JSONEncoder().encode(CompanionLibraryTransferChunk(path: file.path, offset: offset, data: data)))
                        guard next.offsets[file.path] == offset + Int64(data.count) else { throw failure("The destination did not durably acknowledge this transfer chunk.") }
                        offset += Int64(data.count); status = next
                        value.status.offsets = next.offsets; try save(value)
                        presentation.message = "Transferring and verifying your library…"
                    }
                }
                status = try await network.request(value.destination, path: "v1/library-transfer/\(id)/verify", secret: secret, body: Data("{}".utf8))
            }
            guard status.phase == .verified || status.phase == .committed,
                  let endpoint = status.destinationEndpoint, let libraryID = status.destinationLibraryID else { throw failure("The destination has not verified the merged library.") }
            value.status.destinationEndpoint = endpoint; value.status.destinationLibraryID = libraryID
            value.status.phase = .verified
            try Task.checkCancellation()
            // Save the future node's own credential before issuing commit. A
            // Keychain failure leaves the original source authoritative and fenced.
            try MobileCredentialVault.save(.init(endpoint: endpoint, workspaceID: value.request.sourceLibraryID,
                deviceID: value.request.source.deviceID, token: Self.bootstrap(secret)))
            try Task.checkCancellation()
            value.commitIssued = true; try save(value)
        }
        // Once this durable decision exists the old library never resumes writes
        // as central, even if activation succeeds and its acknowledgement is lost.
        status = try await network.request(value.destination, path: "v1/library-transfer/\(id)/commit", secret: secret, body: Data("{}".utf8))
        while status.phase == .committed, status.readyForClients != true {
            presentation.message = "The merged library is verified. Continue on the destination Mac to finish its restart."
            try await Task.sleep(for: .seconds(2))
            status = try await network.request(value.destination, path: "v1/library-transfer/\(id)/status", secret: secret)
        }
        guard status.phase == .committed, let endpoint = status.destinationEndpoint, let libraryID = status.destinationLibraryID else { throw failure("The destination has not confirmed activation. Retry this saved transfer.") }
        let relocation = CompanionLibraryRelocation(transferID: id, previousLibraryID: value.request.sourceLibraryID, endpoint: endpoint, libraryID: libraryID)
        let replica = try MobileStore(file: root.appending(path: "LibraryClient/Transferred/" + id + "/library.json"), deviceID: value.request.source.deviceID)
        try await replica.bindWorkspace(value.request.sourceLibraryID)
        let connection = try HTTPSCompanionTransport(credential: .init(endpoint: endpoint, workspaceID: value.request.sourceLibraryID,
            deviceID: value.request.source.deviceID, token: Self.bootstrap(secret)))
        try await MobileSyncEngine(store: replica, transport: connection).synchronize()
        try await database.retireLibraryAuthority(workspace: value.workspace)
        try LibraryTransferArchive.persist(TransferredLibraryNode(relocation: relocation, workspace: value.workspace, management: value.management), to: try root.appending(path: "library-node.json"))
        value.status.phase = .committed; try save(value)
        try await database.releaseLibraryTransfer(id)
        presentation.restartRequired = true; presentation.message = "Both libraries are merged. Restart to continue as a node. Both backups are retained."
    }
    func cancelSource() async throws {
        guard let value = outgoing, !value.commitIssued else { throw failure("The destination may already be central. Retry completion instead of cancelling this handoff.") }
        let running = operation; running?.cancel(); await running?.value
        guard outgoing?.commitIssued != true else { throw failure("The destination may already be central. Retry completion instead of cancelling this handoff.") }
        let secret = try LibraryTransferSecretVault.load(value.request.id)
        let _: CompanionLibraryTransferStatus = try await network.request(value.destination, path: "v1/library-transfer/\(value.request.id)/cancel", secret: secret, body: Data("{}".utf8))
        try await finishSourceCancellation(value)
    }
    private func finishSourceCancellation(_ prior: Outgoing) async throws {
        var value = prior
        try await model?.dashboardStore?.database.releaseLibraryTransfer(value.request.id)
        value.status.phase = .cancelled; value.commitIssued = false; try save(value)
        await model?.resumeAfterLibraryTransferCancellation()
    }
    func approve(_ id: String) async {
        do {
            guard let model else { return }
            try await model.prepareForLibraryTransfer()
            let database = try await receivingDatabase()
            let endpoint = model.isLibraryClient ? model.libraryClient.localEndpoint : model.companionHost.endpoint
            guard let endpoint else { throw failure("Enable this Mac’s Apple device connection before accepting the transfer.") }
            let replica = model.isLibraryClient ? model.libraryClient.transferStore : nil
            try await receiverStore().approve(id, database: database, endpoint: endpoint, additionalBackup: { backup in
                try await replica?.backupForLibraryTransfer(to: backup.appending(path: "Node Replica"))
            })
            presentation.incoming = await (try receiverStore()).allSessions()
        } catch {
            if !(await (try? receiverStore())?.allSessions() ?? []).contains(where: { [.receiving, .verified].contains($0.status.phase) }) {
                await model?.resumeAfterLibraryTransferCancellation()
            }
            presentation.message = error.localizedDescription
        }
    }
    func decline(_ id: String) async {
        do { try await receiverStore().cancel(id, database: destinationDatabase ?? model?.dashboardStore?.database); try await stopRecoveryListener(); await model?.resumeAfterLibraryTransferCancellation(); await refresh() }
        catch { presentation.message = error.localizedDescription }
    }
    private func receivingDatabase() async throws -> WorkspaceDatabase {
        if let destinationDatabase { return destinationDatabase }
        if let model, !model.isLibraryClient, let database = model.dashboardStore?.database { destinationDatabase = database; return database }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        destinationDatabase = database; return database
    }
    private func receivingAuthentication() async throws -> CompanionAuthentication {
        if let destinationAuthentication { return destinationAuthentication }
        if let model, !model.isLibraryClient { return try await model.companionHost.libraryTransferAuthentication() }
        let auth = try CompanionAuthentication(fileURL: root.appending(path: "companion-devices.json"))
        destinationAuthentication = auth; return auth
    }
    func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse? {
        let raw = URLComponents(string: "http://localhost" + request.target)?.path ?? ""
        let path = raw.hasPrefix("/wovenmatter/") ? String(raw.dropFirst("/wovenmatter".count)) : raw
        guard path.hasPrefix("/v1/library-transfer/") else { return nil }
        do {
            let maximum = path.hasSuffix("/manifest") ? 32 * 1_024 * 1_024 : 2 * 1_024 * 1_024
            guard request.headers["x-woven-protocol"] == String(CompanionProtocol.version), request.headers["origin"] == nil,
                  request.body.count <= maximum else { throw failure("Invalid database transfer request.") }
            let receiver = try receiverStore()
            if path == "/v1/library-transfer/invite", request.method == "POST" {
                guard let model, !model.isLibraryClient, !model.isTransferredLibraryNode,
                      let bearer = request.bearer else { throw failure("Only a paired Mac can request this central database.") }
                let authentication = try await receivingAuthentication()
                let device = try await authentication.authenticate(bearer: bearer)
                let peer = try JSONDecoder().decode(CompanionDiscoveredPeer.self, from: request.body)
                let registered = try await receivingDatabase().companionExecutionWorkspaces()
                guard device.kind == .mac, peer.advertisement.identity.deviceID == device.id,
                      registered.contains(where: { ($0.executionDeviceID ?? $0.ownerDeviceID) == device.id && $0.endpoint == peer.endpoint && !$0.deleted }) else { throw failure("The requested destination is not this paired Mac’s registered workspace.") }
                presentation.invitations.removeAll { $0.advertisement.identity.deviceID == device.id }
                presentation.invitations.append(peer)
                return try .json(["requested": true])
            }
            if path == "/v1/library-transfer/request", request.method == "POST" {
                let value = try JSONDecoder().decode(CompanionLibraryTransferRequest.self, from: request.body)
                let ownID = model?.isLibraryClient == true ? model!.libraryClient.state.deviceID : try await receivingDatabase().companionLibraryIdentity().hostDeviceID
                let status = try await receiver.request(value, destinationDeviceID: ownID)
                await refresh(); return try .json(status)
            }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4, let secret = request.headers["x-woven-transfer-secret"] else { throw failure("The database transfer needs its approved device secret.") }
            let id = parts[2], action = parts[3]
            let session = try await receiver.authenticated(id, secret: secret)
            let status: CompanionLibraryTransferStatus
            switch (request.method, action) {
            case ("GET", "status"): status = session.status
            case ("POST", "manifest"): status = try await receiver.setManifest(JSONDecoder().decode(CompanionLibraryTransferManifest.self, from: request.body), id: id, secret: secret)
            case ("POST", "chunk"): status = try await receiver.upload(JSONDecoder().decode(CompanionLibraryTransferChunk.self, from: request.body), id: id, secret: secret)
            case ("POST", "verify"):
                status = try await receiver.verify(id, secret: secret)
                if status.phase == .verified { try await prepareVerifiedDestination(session.request, status: status) }
            case ("POST", "commit"):
                if session.status.phase != .committed { try await prepareVerifiedDestination(session.request, status: session.status) }
                status = try await receiver.commit(id, secret: secret, database: receivingDatabase(), authentication: receivingAuthentication())
                try await finishDestination(session.request, status: status)
            case ("POST", "cancel"):
                try await receiver.cancel(id, database: destinationDatabase); try await stopRecoveryListener(); await model?.resumeAfterLibraryTransferCancellation()
                status = try await receiver.authenticated(id, secret: secret).status
            default: return .error("not_found", "Unknown database transfer operation.", status: 404)
            }
            await refresh()
            var response = status
            response.readyForClients = status.phase == .committed && model?.isLibraryClient == false && model?.isTransferredLibraryNode == false
            return try .json(response)
        } catch let error as CompanionAPIError { return .error(error.code, error.message, status: 409) }
        catch { presentation.message = error.localizedDescription; return .error("transfer_failed", "The database transfer could not finish. Both original backups and the saved transfer have been retained.", status: 500) }
    }
    private func prepareVerifiedDestination(_ request: CompanionLibraryTransferRequest, status: CompanionLibraryTransferStatus) async throws {
        try await model?.prepareForLibraryTransfer()
        guard let endpoint = status.destinationEndpoint, let libraryID = status.destinationLibraryID else { throw failure("The destination is not ready.") }
        let incoming = try await receiverStore().incomingDirectory(request.id)
        let stagedURL = incoming.deletingLastPathComponent().appending(path: "merged.sqlite")
        let staged = try await WorkspaceDatabase(url: stagedURL)
        try await staged.prepareReceivedLibraryAuthority()
        let aliases = try JSONDecoder().decode([CompanionLibraryRelocation].self, from: Data(contentsOf: incoming.appending(path: "lineage.json")))
        for previous in Set(aliases.map(\.previousLibraryID) + [request.sourceLibraryID]) {
            try await staged.installLibraryTransferAlias(.init(transferID: request.id, previousLibraryID: previous, endpoint: endpoint, libraryID: libraryID))
        }
        // A paired destination's pending local edits belong in the new central,
        // including writing created while the old central was unreachable.
        if let store = model?.isLibraryClient == true ? model?.libraryClient.transferStore : nil {
            try await store.backupForLibraryTransfer(to: incoming.deletingLastPathComponent().appending(path: "Replica at verification"))
            try await LibraryTransferWritingImporter.merge(store: store, database: staged, transferID: request.id)
        }
        let grants = try JSONDecoder().decode([CompanionExecutionManagementGrant].self, from: Data(contentsOf: incoming.appending(path: "authority.json")))
        for grant in grants { try ExecutionManagementVault.save(grant, libraryID: libraryID) }
    }
    private func finishDestination(_ request: CompanionLibraryTransferRequest, status: CompanionLibraryTransferStatus) async throws {
        guard let model else { return }
        if model.isLibraryClient || model.isTransferredLibraryNode {
            if model.isLibraryClient { try LibraryTransferArchive.persist(true, to: root.appending(path: "retained-node-workspace.json")) }
            let nodeFile = try root.appending(path: "library-node.json")
            if FileManager.default.fileExists(atPath: nodeFile.path) { try FileManager.default.removeItem(at: nodeFile) }
            model.commitReceivedLibraryRole()
            presentation.restartRequired = true
        } else {
            await model.resumeAfterLibraryTransferCancellation()
            await model.refreshWorkspace()
        }
        presentation.message = "The merged database is ready on this Mac. Both backups are retained."
    }
    func relocation(for libraryID: String) -> CompanionLibraryRelocation? {
        if let value = outgoing, value.commitIssued, value.status.phase != .cancelled,
           model?.isTransferredLibraryNode == true || value.status.phase != .committed,
           let endpoint = value.status.destinationEndpoint, let current = value.status.destinationLibraryID {
            return .init(transferID: value.request.id, previousLibraryID: libraryID, endpoint: endpoint, libraryID: current)
        }
        return nil
    }
    private static func bootstrap(_ secret: String) -> String { SHA256.hash(data: Data(("woven-library-node-v1\0" + secret).utf8)).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ message: String) -> CompanionAPIError { .init(code: "library_transfer", message: message) }
}

/// Per-transfer control secrets stay in this Mac's Keychain. They never enter a
/// roster, SQLite content, discovery response, UserDefaults, or log.
private enum LibraryTransferSecretVault {
    private static func query(_ id: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: ClientCredentialNamespace.service("com.wovenmatter.library-transfer"), kSecAttrAccount: id]
    }
    static func create(_ id: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MobileConnectionError.invalidResponse }
        let secret = Data(bytes).base64EncodedString()
        let attributes: [CFString: Any] = [kSecValueData: Data(secret.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }; return secret
    }
    static func load(_ id: String) throws -> String {
        var request = query(id); request[kSecReturnData] = true; request[kSecMatchLimit] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        guard status == errSecSuccess, let bytes = value as? Data, let secret = String(data: bytes, encoding: .utf8) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return secret
    }
}
