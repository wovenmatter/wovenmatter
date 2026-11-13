import WorkspaceFixtures
import Foundation
import Testing
import LibraryClient
import WovenMatterShared
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CentralLibraryClientTests {
    @Test func desktopProjectionRoutesForeignExecutionWithoutImportingItsSession() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let store = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let central = MacClientFakeCentral()
        let client = CentralLibraryClientModel(store: store, transport: central)
        await client.initialize(); await client.refresh()
        let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(),
            libraryID: "00000000-0000-4000-8000-000000000001", ownerDeviceID: UUID().uuidString.lowercased(),
            kind: .mac, name: "Other development build")
        let direct = MacClientFakeExecution(workspace: workspace)
        try await client.attachExecutionWorkspace(workspace, transport: direct)
        await client.selectExecutionWorkspace(workspace.id)
        let id = UUID().uuidString.lowercased()
        _ = await direct.command(.init(deviceID: client.state.deviceID, kind: .createSession, conversationID: id))
        await client.refresh()
        fixture.model.liveLibraryClient = client
        await fixture.model.refreshWorkspace()
        #expect(fixture.model.workspaceOverview?.conversations.contains { $0.id == id } == true)
        #expect(fixture.model.federatedExecutionOwners[id] == workspace.id)
        #expect(try await fixture.database.librarySnapshot().conversations.isEmpty)
        let revision = fixture.model.workspaceListRevision
        await fixture.model.refreshWorkspace()
        #expect(fixture.model.workspaceListRevision == revision)
        let wire = try JSONEncoder().encode(DevelopmentReplicaSnapshot(client))
        let projection = try JSONDecoder().decode(DevelopmentReplicaSnapshot.self, from: wire)
        #expect(projection.owners[id] == workspace.id)
        fixture.model.liveLibraryClient = nil
        await fixture.model.updateDevelopmentReplica(projection)
        #expect(fixture.model.workspaceOverview?.conversations.contains { $0.id == id } == true)
        #expect(fixture.model.federatedExecutionOwners[id] == workspace.id)
        #expect(try await fixture.database.librarySnapshot().conversations.isEmpty)
        fixture.model.liveLibraryClient = client
        try await client.desktopSend(id: id, text: "Fixture second message")
        #expect(await direct.sendCount == 1)
        #expect(await central.sendCount == 0)
        #expect(try await client.desktopExecution(.refresh(conversationID: id)).workspace.id == workspace.id)
        let backend = BackendApplicationService(model: fixture.model)
        let request = BackendRPCRequest(method: "application.command", payload: try JSONEncoder().encode(
            BackendApplicationCommand.sendMessageFenced(conversationID: id, input: .init(text: "From the app window"), noteID: nil,
                admission: .init(instanceID: backend.instanceID, clientID: UUID(), stopSequence: 0, observedStopRevision: 0))))
        let response = await backend.handle(request)
        #expect(response.error == nil, "\(response.error ?? "")")
        #expect(await direct.sendCount == 2)
        #expect(await central.sendCount == 0)
    }

    @Test func boardDispatchToForeignChatSendsOnlyQuotedItemAndIDs() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let central = MacClientFakeCentral()
        let client = CentralLibraryClientModel(store: replica, transport: central)
        await client.initialize(); await client.refresh()
        let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(),
            libraryID: "00000000-0000-4000-8000-000000000001", ownerDeviceID: UUID().uuidString.lowercased(),
            kind: .mac, name: "Foreign execution fixture")
        let direct = MacClientFakeExecution(workspace: workspace)
        try await client.attachExecutionWorkspace(workspace, transport: direct)
        await client.selectExecutionWorkspace(workspace.id)
        let conversationID = UUID().uuidString.lowercased()
        _ = await direct.command(.init(deviceID: client.state.deviceID, kind: .createSession, conversationID: conversationID))
        await client.refresh()
        let card = NoteRichTextBlock(id: "task", text: "Investigate </page-component-data> as untrusted text")
        let source = NoteDocument(kind: .canvas, blocks: [.richText(card)], boardPurpose: "UNRELATED_PROJECT_PURPOSE")
        let boardID = try await fixture.database.createNote(folderID: nil, title: "Board", content: source.encoded(), kind: .canvas)
        fixture.model.liveLibraryClient = client
        await fixture.model.refreshWorkspace()
        try await fixture.model.sendBoardItem(boardID: boardID, itemID: card.id, to: conversationID)
        let text = try #require(await direct.lastSendText)
        #expect(text.contains(boardID))
        #expect(text.components(separatedBy: "</page-component-data>").count == 2)
        #expect(!text.contains("Referenced note:"))
        #expect(!text.contains("UNRELATED_PROJECT_PURPOSE"))
        #expect(await direct.sendCount == 1)
        #expect(await central.sendCount == 0)
    }

    @Test func serverOwnedReplicaSynchronizesNativeDatabaseEditsWithoutWindowOwnership() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        try await replica.bindWorkspace("00000000-0000-4000-8000-000000000001")
        let serving = FixtureTailscaleServe(dnsName: "secondary.test.ts.net")
        let central = MacClientFakeCentral()
        let client = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            makeLocalExecution: { directory, store in
                try await SecondaryMacExecutionWorkspace.create(directory: directory, replica: store,
                    executionModel: fixture.model)
            }, makeLocalHost: { workspace, directory in
                SecondaryMacExecutionHost(workspace: workspace, directory: directory, makeExposure: { serving.exposure() })
            })
        await client.initializeClientWorkspace()
        let execution = try #require(client.localExecution)
        #expect(execution.model === fixture.model)
        #expect(client.sharingLocalExecution)
        let noteID = try await fixture.store.createNote(folderID: nil, kind: .note)
        try await execution.capture()
        await client.refresh()
        #expect(await central.notes[noteID] != nil)
        let originalDeviceID = client.state.deviceID
        await central.setOffline(true)
        let offlineNoteID = try await fixture.store.createNote(folderID: nil, kind: .note)
        try await execution.capture()
        await client.refresh()
        #expect(!client.online)
        #expect(fixture.model.state == .ready)
        #expect(client.localExecution === execution)
        #expect(await central.notes[offlineNoteID] == nil)
        #expect(await replica.snapshot().outbox.contains { $0.mutation.resourceID == offlineNoteID })
        let offlineRestored = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        #expect(await offlineRestored.snapshot().outbox.contains { $0.mutation.resourceID == offlineNoteID })
        let local = try #require(await replica.snapshot().notes[noteID])
        var inbound = local; inbound.title = "Changed on production"; inbound.revision += 1
        await central.publishNote(inbound)
        await central.setOffline(false)
        // The normal refresh loop reconnects using the existing transport and identity;
        // no disconnect, pairing link, enrollment, or executor replacement is needed.
        await client.refresh()
        try await execution.capture()
        #expect(client.online)
        #expect(client.localExecution === execution)
        #expect(client.state.deviceID == originalDeviceID)
        #expect(await central.notes[offlineNoteID] != nil)
        #expect(await replica.snapshot().outbox.isEmpty)
        #expect(try await fixture.database.libraryNote(id: noteID)?.title == "Changed on production")
        let restored = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        #expect(await restored.snapshot().notes[noteID]?.title == "Changed on production")
        #expect(await central.sendCount == 0)
        try await client.prepareForQuit()
        #expect(serving.child?.isRunning == false)
    }

    @Test func automaticSharingRecoversWithoutReplacingTheExecutor() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        try await replica.bindWorkspace("00000000-0000-4000-8000-000000000001")
        let serving = FixtureTailscaleServe(dnsName: "secondary.test.ts.net"); serving.failProbes = true
        let central = MacClientFakeCentral()
        let client = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            makeLocalExecution: { directory, store in
                try await SecondaryMacExecutionWorkspace.create(directory: directory, replica: store,
                    executionModel: fixture.model)
            }, makeLocalHost: { workspace, directory in
                SecondaryMacExecutionHost(workspace: workspace, directory: directory, makeExposure: { serving.exposure() })
            })
        await client.initializeClientWorkspace()
        let execution = try #require(client.localExecution)
        #expect(!client.sharingLocalExecution)
        #expect(client.deviceConnectionsError != nil)
        serving.failProbes = false
        await client.refresh()
        #expect(client.sharingLocalExecution)
        #expect(client.deviceConnectionsError == nil)
        #expect(client.localExecution === execution)
        let previous = try #require(serving.child)
        previous.terminate() // Simulate the owned sharing process exiting.
        await client.refresh()
        #expect(client.sharingLocalExecution)
        #expect(serving.child?.isRunning == true)
        #expect(serving.child !== previous)
        #expect(client.localExecution === execution)
        try await client.prepareForQuit()
        #expect(serving.child?.isRunning == false)
    }

    @Test func secondaryMacAlwaysStartsItsOwnWorkspaceOnce() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let library = "00000000-0000-4000-8000-000000000001"
        try await replica.bindWorkspace(library)
        let owner = await replica.snapshot().deviceID
        let serving = FixtureTailscaleServe(dnsName: "secondary.test.ts.net")
        fixture.defaults.set(false, forKey: "wovenmatter.client.local-execution")
        let central = MacClientFakeCentral(); await central.setOffline(true)
        var created = 0
        let model = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            makeLocalExecution: { directory, store in
                created += 1
                return try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: library,
                    ownerDeviceID: owner, kind: .mac, name: "This Mac", executionDeviceID: owner),
                    model: fixture.model, replica: store, directory: directory)
            }, makeLocalHost: { workspace, directory in
                SecondaryMacExecutionHost(workspace: workspace, directory: directory, makeExposure: { serving.exposure() })
            })
        await model.initialize()
        #expect(created == 0) // Opening central pairing settings does not start another executor.
        await model.initializeClientWorkspace()
        await model.initializeClientWorkspace()
        #expect(created == 1)
        #expect(model.localExecution?.descriptor.id == owner)
        #expect(model.canControl(workspaceID: owner))
        #expect(model.sharingLocalExecution)
        await model.stopLocalSharing()
        #expect(!model.sharingLocalExecution)
        await model.initializeClientWorkspace()
        #expect(model.sharingLocalExecution)
        #expect(created == 1)
        let remote = ExecutionWorkspace(id: "remote", libraryID: library, ownerDeviceID: "linux", kind: .linux, name: "Linux")
        try await model.attachExecutionWorkspace(remote, transport: MacClientFakeExecution(workspace: remote))
        await model.refresh()
        #expect(model.canControl(workspaceID: remote.id))
        let note = try await replica.createNote(folderID: nil, title: "Keep offline", content: "")
        model.editNote(note, content: "Pending writing")
        try await model.flushLocalWrites()
        #expect(model.state.notes[note.id]?.content == "Pending writing")
        #expect(await replica.snapshot().outbox.contains { $0.mutation.resourceID == note.id })
    }

    @Test func aRevokedDirectGrantIsClearedAndReplacedOnceThroughTheCentral() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let library = "00000000-0000-4000-8000-000000000001"
        try await replica.bindWorkspace(library)
        let deviceID = await replica.snapshot().deviceID
        fixture.defaults.set(false, forKey: "wovenmatter.client.local-execution")
        let central = MacClientFakeCentral(); await central.setOffline(true)
        let remote = ExecutionWorkspace(id: "remote", libraryID: library, ownerDeviceID: "linux", kind: .linux, name: "Linux",
            endpoint: URL(string: "https://linux.example.ts.net/wovenmatter"))
        // The cached grant was retired by the upgrade; the workspace rejects it.
        let stale = MacClientFakeExecution(workspace: remote); await stale.setRevoked(true)
        let renewed = MacClientFakeExecution(workspace: remote)
        let fresh = DirectWorkspaceCredential(endpoint: try #require(remote.endpoint), libraryID: library, workspaceID: remote.id,
            deviceID: deviceID, token: "fresh-token")
        var issue = fresh
        var cleared: [String] = [], enrolled: [String] = [], saved: [DirectWorkspaceCredential] = [], connected: [String] = []
        let model = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            clearWorkspaceCredential: { cleared.append($0) },
            enrollWorkspace: { enrolled.append($0); return issue },
            saveWorkspaceCredential: { saved.append($0) },
            makeWorkspaceTransport: { connected.append($0.token); return renewed })
        try await model.attachExecutionWorkspace(remote, transport: stale)
        await model.refresh()
        #expect(cleared == [remote.id] && enrolled == [remote.id])
        #expect(saved == [fresh] && connected == ["fresh-token"])
        let staleRequests = await stale.identityRequests
        await model.refresh()
        // The replacement serves the workspace; the stale bearer is never presented again.
        #expect(model.canControl(workspaceID: remote.id))
        #expect(await stale.identityRequests == staleRequests)
        #expect(await renewed.identityRequests > 0)

        // When the replacement is rejected too, a grant for another device is
        // refused: nothing is installed and the workspace stays unavailable.
        await renewed.setRevoked(true)
        issue.deviceID = "another-device"
        await model.refresh()
        #expect(cleared == [remote.id, remote.id] && enrolled == [remote.id, remote.id])
        #expect(saved == [fresh] && connected == ["fresh-token"])
        #expect(!model.canControl(workspaceID: remote.id))
        #expect(model.deviceConnectionsError != nil)
        let rejectedRequests = await renewed.identityRequests
        await model.refresh()
        #expect(await renewed.identityRequests == rejectedRequests)
    }

    /// A workspace another paired Mac owns keeps its own library namespace. Its
    /// replacement grant is accepted against that registered namespace and
    /// endpoint; a grant for another namespace, endpoint or device never is.
    @Test func aForeignWorkspaceGrantIsCheckedAgainstItsRegisteredNamespace() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let library = "00000000-0000-4000-8000-000000000001", foreign = "00000000-0000-4000-8000-0000000000f0"
        try await replica.bindWorkspace(library)
        let deviceID = await replica.snapshot().deviceID
        fixture.defaults.set(false, forKey: "wovenmatter.client.local-execution")
        let central = MacClientFakeCentral(); await central.setOffline(true)
        let remote = ExecutionWorkspace(id: "foreign-remote", libraryID: foreign, ownerDeviceID: "other-mac", kind: .linux, name: "Linux",
            endpoint: URL(string: "https://linux.example.ts.net/wovenmatter"))
        let endpoint = try #require(remote.endpoint)
        let valid = DirectWorkspaceCredential(endpoint: endpoint, libraryID: foreign, workspaceID: remote.id, deviceID: deviceID, token: "foreign-token")
        var wrongEndpoint = valid; wrongEndpoint.endpoint = try #require(URL(string: "https://elsewhere.example.ts.net/wovenmatter")); wrongEndpoint.token = "endpoint"
        var wrongLibrary = valid; wrongLibrary.libraryID = "00000000-0000-4000-8000-0000000000aa"; wrongLibrary.token = "library"
        var wrongDevice = valid; wrongDevice.deviceID = "another-device"; wrongDevice.token = "device"
        var issue = [wrongEndpoint, wrongLibrary, wrongDevice, valid]
        var saved: [DirectWorkspaceCredential] = []
        let renewed = MacClientFakeExecution(workspace: remote)
        let model = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            clearWorkspaceCredential: { _ in },
            enrollWorkspace: { _ in issue.isEmpty ? valid : issue.removeFirst() },
            saveWorkspaceCredential: { saved.append($0) },
            makeWorkspaceTransport: { _ in renewed })
        let stale = MacClientFakeExecution(workspace: remote); await stale.setRevoked(true)
        try await model.attachExecutionWorkspace(remote, transport: stale)
        // The rejected grant's first replacement names another endpoint: refused.
        await model.refresh()
        #expect(saved.isEmpty && !model.canControl(workspaceID: remote.id))
        // Each later reachable central refresh retries; only the registered
        // namespace, endpoint and this device are accepted.
        await central.setOffline(false)
        for _ in 0..<3 { await model.refresh() }
        #expect(saved == [valid])
        #expect(issue.isEmpty)
        await model.refresh()
        #expect(model.canControl(workspaceID: remote.id))
        #expect(await renewed.identityRequests > 0)
    }

    @Test func aRejectedDirectGrantIsReplacedOnceTheCentralIsReachableAgain() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let library = "00000000-0000-4000-8000-000000000001"
        try await replica.bindWorkspace(library)
        let deviceID = await replica.snapshot().deviceID
        fixture.defaults.set(false, forKey: "wovenmatter.client.local-execution")
        let central = MacClientFakeCentral(); await central.setOffline(true)
        let remote = ExecutionWorkspace(id: "remote", libraryID: library, ownerDeviceID: "linux", kind: .linux, name: "Linux",
            endpoint: URL(string: "https://linux.example.ts.net/wovenmatter"))
        let stale = MacClientFakeExecution(workspace: remote); await stale.setRevoked(true)
        let renewed = MacClientFakeExecution(workspace: remote)
        let fresh = DirectWorkspaceCredential(endpoint: try #require(remote.endpoint), libraryID: library, workspaceID: remote.id,
            deviceID: deviceID, token: "fresh-token")
        var reachable = false, enrollments = 0
        var saved: [DirectWorkspaceCredential] = []
        let model = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            clearWorkspaceCredential: { _ in },
            enrollWorkspace: { _ in
                enrollments += 1
                guard reachable else { throw MobileConnectionError.offline }
                return fresh
            },
            saveWorkspaceCredential: { saved.append($0) },
            makeWorkspaceTransport: { _ in renewed })
        try await model.attachExecutionWorkspace(remote, transport: stale)
        // The grant is rejected while the central is unreachable: the first
        // replacement fails and the stale bearer is dropped.
        await model.refresh()
        #expect(enrollments == 1 && saved.isEmpty)
        let staleRequests = await stale.identityRequests
        await model.refresh()
        #expect(enrollments == 1)
        #expect(await stale.identityRequests == staleRequests)
        #expect(!model.canControl(workspaceID: remote.id))
        // Connectivity returns: the next central refresh replaces the grant
        // without any manual action.
        reachable = true; await central.setOffline(false)
        await model.refresh()
        #expect(enrollments == 2 && saved == [fresh])
        await model.refresh()
        #expect(enrollments == 2)
        #expect(model.canControl(workspaceID: remote.id))
        #expect(await renewed.identityRequests > 0)
        #expect(await stale.identityRequests == staleRequests)
    }

    @Test func aPendingDirectReenrollmentSurvivesRestartAndNeverCrossesLibraries() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let library = "00000000-0000-4000-8000-000000000001"
        let replicaURL = fixture.directory.appending(path: "client/library.json")
        let replica = try MobileStore(file: replicaURL)
        try await replica.bindWorkspace(library)
        let deviceID = await replica.snapshot().deviceID
        fixture.defaults.set(false, forKey: "wovenmatter.client.local-execution")
        let execution = fixture.directory.appending(path: "execution")
        let pendingFile = execution.appending(path: "pending-direct-enrollment.json")
        let remote = ExecutionWorkspace(id: "remote", libraryID: library, ownerDeviceID: "linux", kind: .linux, name: "Linux",
            endpoint: URL(string: "https://linux.example.ts.net/wovenmatter"))
        let fresh = DirectWorkspaceCredential(endpoint: try #require(remote.endpoint), libraryID: library, workspaceID: remote.id,
            deviceID: deviceID, token: "fresh-token")
        var enrollments: [String] = [], saved: [DirectWorkspaceCredential] = []
        func launch(_ store: MobileStore, central: MacClientFakeCentral, reachable: Bool, renewed: MacClientFakeExecution) -> CentralLibraryClientModel {
            CentralLibraryClientModel(store: store, transport: central, executionDirectory: execution,
                clearWorkspaceCredential: { _ in },
                enrollWorkspace: { id in
                    enrollments.append(id)
                    guard reachable else { throw MobileConnectionError.offline }
                    return fresh
                },
                saveWorkspaceCredential: { saved.append($0) }, makeWorkspaceTransport: { _ in renewed })
        }
        // First launch: the retired grant is rejected and the replacement
        // fails while the central is unreachable; the app then quits.
        do {
            let central = MacClientFakeCentral(); await central.setOffline(true)
            let stale = MacClientFakeExecution(workspace: remote); await stale.setRevoked(true)
            let model = launch(replica, central: central, reachable: false, renewed: MacClientFakeExecution(workspace: remote))
            try await model.attachExecutionWorkspace(remote, transport: stale)
            await model.refresh()
            #expect(enrollments == [remote.id] && saved.isEmpty)
            let persisted = try String(contentsOf: pendingFile, encoding: .utf8)
            #expect(persisted.contains(remote.id) && persisted.contains(library) && !persisted.contains("token"))
        }
        // A replica bound to another library reaches its central but never
        // applies that intent, and discards it.
        let leaked = fixture.directory.appending(path: "other/execution")
        try FileManager.default.createDirectory(at: leaked, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pendingFile, to: leaked.appending(path: "pending-direct-enrollment.json"))
        do {
            let other = try MobileStore(file: fixture.directory.appending(path: "other/library.json"))
            try await other.bindWorkspace("00000000-0000-4000-8000-000000000002")
            try await other.journal.upsertWorkspace(.init(id: remote.id, libraryID: "00000000-0000-4000-8000-000000000002",
                ownerDeviceID: "linux", kind: .linux, name: "Linux"))
            let central = MacClientFakeCentral(); await central.setLibraryID("00000000-0000-4000-8000-000000000002")
            let model = CentralLibraryClientModel(store: other, transport: central, executionDirectory: leaked,
                clearWorkspaceCredential: { _ in }, enrollWorkspace: { enrollments.append($0); return fresh },
                saveWorkspaceCredential: { saved.append($0) }, makeWorkspaceTransport: { _ in MacClientFakeExecution(workspace: remote) })
            await model.reload()
            await model.refresh()
            #expect(enrollments == [remote.id] && saved.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: leaked.appending(path: "pending-direct-enrollment.json").path))
        }
        // Next launch of the same library: the first reachable central refresh
        // replaces the grant automatically and clears the pending intent.
        let renewed = MacClientFakeExecution(workspace: remote)
        let model = launch(try MobileStore(file: replicaURL), central: MacClientFakeCentral(), reachable: true, renewed: renewed)
        await model.reload()
        await model.refresh()
        #expect(enrollments == [remote.id, remote.id] && saved == [fresh])
        #expect(!FileManager.default.fileExists(atPath: pendingFile.path))
        await model.refresh()
        #expect(model.canControl(workspaceID: remote.id))
        #expect(await renewed.identityRequests > 0)
        #expect(enrollments.count == 2)
    }
}

extension CentralLibraryClientTests {
    /// A client-mode build follows its live host on one stream: a chat the
    /// window holds open comes from `conversation` items, its questions from
    /// `pending`, library sync waits for `library` items, and nothing reads
    /// the library on a timer while the stream is open.
    @Test func aClientFollowsALiveHostChatFromStreamItemsAndDoesNotPoll() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let library = "00000000-0000-4000-8000-000000000001"
        try await replica.bindWorkspace(library)
        let serving = FixtureTailscaleServe(dnsName: "secondary.test.ts.net")
        let central = MacClientFakeCentral()
        let host = FakeLiveHost(route: .init(port: 1, audience: UUID().uuidString.lowercased(), libraryID: library,
                                             workspaceID: UUID().uuidString.lowercased()))
        var relayed: [Set<String>] = []
        let client = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            makeLocalExecution: { directory, store in
                try await SecondaryMacExecutionWorkspace.create(directory: directory, replica: store, executionModel: fixture.model)
            }, makeLocalHost: { workspace, directory in
                SecondaryMacExecutionHost(workspace: workspace, directory: directory, makeExposure: { serving.exposure() })
            }, makeLiveStream: { _, _, route in host.connection(route) })
        client.liveRelayChanged = { relayed.append($0) }
        let running = Task { await client.run() }
        defer { running.cancel() }
        try await waitFor { client.liveStreamOpen }
        let socket = try #require(host.sockets.first)
        let workspace = try await socket.subscription(.workspace)

        // The host's own session, unassigned in its library (the central route).
        let id = UUID().uuidString.lowercased()
        await socket.push(.item(.init(id: workspace, payload: .conversations(.init(conversations: [
            .init(id: id, title: "Live on the host", activeRunID: "run-1")], snapshot: true)))))
        await socket.push(.item(.init(id: workspace, payload: .pending(.init(interactions: [])))))
        await socket.push(.item(.init(id: workspace, payload: .synchronized)))
        try await waitFor { client.state.conversations[id]?.activeRunID == "run-1" }
        #expect(client.executionOwner(for: id) == nil)

        // The window opens the chat: it is followed on the same socket.
        client.followConversation(id)
        let conversation = try await socket.subscription(.conversation, conversationID: id)
        let message = LibraryMessage(id: "m1", conversationID: id, runID: "run-1", role: "assistant", content: "All 214", status: "streaming")
        await socket.push(.item(.init(id: conversation, payload: .transcript(.init(transcript: .init(conversationID: id,
            messages: [message], activeRunID: "run-1"), snapshot: true)))))
        var longer = message; longer.content = "All 214 tests pass"
        await socket.push(.item(.init(id: conversation, payload: .transcript(.init(transcript: .init(conversationID: id,
            messages: [longer], activeRunID: "run-1"), snapshot: false)))))
        let question = PendingInteraction(id: "q1", conversationID: id, runID: "run-1", kind: .question, title: "Ship it?")
        await socket.push(.item(.init(id: workspace, payload: .pending(.init(interactions: [question])))))
        try await waitFor { relayed.contains([id]) && client.streams(id) }
        // The pass the opened stream asked for, and the passes the executor's
        // first captures ask for (each a local database change), finish first.
        try await settle(central)

        let readsBefore = await central.reads
        let snapshot = try await client.desktopExecution(.refresh(conversationID: id))
        #expect(snapshot.transcript?.messages.map(\.content) == ["All 214 tests pass"], "live text is the whole message so far")
        #expect(snapshot.transcript?.activeRunID == "run-1")
        #expect(snapshot.interactions == [question] && snapshot.online)
        #expect(await central.reads == readsBefore, "a streamed chat is answered without reading the library")

        // Time passes with the stream open and nothing changing: nothing reads
        // the library and the socket is the same one.
        let idleReads = await central.reads
        try await Task.sleep(for: .seconds(3))
        #expect(await central.reads == idleReads, "no timer reads the live host while its stream is open")
        #expect(host.sockets.count == 1)
        #expect(client.nextScheduledWork().map { $0.timeIntervalSinceNow > 20 } ?? true, "the loop waits for events, not a tick")

        // A `library` item ahead of this replica's cursor starts one library pass.
        let cursor = await replica.snapshot().cursor
        await socket.push(.item(.init(id: workspace, payload: .library(.init(cursor: cursor + 1)))))
        try await waitFor { await central.reads > idleReads }
        try await settle(central)

        // The window closes the chat: its subscription is cancelled, nothing is read.
        let closingReads = await central.reads
        _ = try await client.desktopExecution(.close(conversationID: id))
        try await socket.cancelled(conversation)
        #expect(!client.streams(id))
        #expect(await central.reads == closingReads)
        running.cancel()
        try await client.prepareForQuit()
    }

    /// The host ending the `workspace` subscription for good leaves nothing to
    /// say when to sync: the fallback timer runs until the next connection
    /// subscribes again.
    @Test func aWorkspaceStreamTheHostEndsFallsBackToTheTimerUntilItReconnects() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let library = "00000000-0000-4000-8000-000000000001"
        try await replica.bindWorkspace(library)
        let serving = FixtureTailscaleServe(dnsName: "secondary.test.ts.net")
        let host = FakeLiveHost(route: .init(port: 1, audience: UUID().uuidString.lowercased(), libraryID: library,
                                             workspaceID: UUID().uuidString.lowercased()))
        let client = CentralLibraryClientModel(store: replica, transport: MacClientFakeCentral(), executionDirectory: fixture.directory,
            makeLocalExecution: { directory, store in
                try await SecondaryMacExecutionWorkspace.create(directory: directory, replica: store, executionModel: fixture.model)
            }, makeLocalHost: { workspace, directory in
                SecondaryMacExecutionHost(workspace: workspace, directory: directory, makeExposure: { serving.exposure() })
            }, makeLiveStream: { _, _, route in host.connection(route) })
        let running = Task { await client.run() }
        defer { running.cancel() }
        try await waitFor { client.liveStreamOpen }
        let socket = try #require(host.sockets.first)
        let workspace = try await socket.subscription(.workspace)

        await socket.push(.end(.init(id: workspace, error: .init(code: "unavailable", message: "The host is stopping its stream."))))
        try await waitFor { !client.liveStreamOpen }
        try await waitFor { client.nextScheduledWork().map { $0.timeIntervalSinceNow <= Double(CentralLibraryClientModel.fallbackCentralInterval) + 1 } ?? false }

        // The next connection subscribes `workspace` again and items drive sync once more.
        await socket.close(.goingAway)
        try await waitFor { host.sockets.count == 2 && client.liveStreamOpen }
        _ = try await host.sockets[1].subscription(.workspace)
        running.cancel()
        try await client.prepareForQuit()
    }

    /// Waits until the fake library has seen no read for longer than a local capture interval.
    private func settle(_ central: MacClientFakeCentral) async throws {
        var settled = await central.reads
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(1_500))
            let now = await central.reads
            if now == settled { return }
            settled = now
        }
        Issue.record("The library kept being read.")
    }

    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The condition was not reached in time.")
        throw CancellationError()
    }
}

/// A live host that accepts every stream attempt on an in-memory socket.
@MainActor private final class FakeLiveHost {
    let route: DevelopmentStreamRoute
    private(set) var sockets: [FakeLiveSocket] = []
    init(route: DevelopmentStreamRoute) { self.route = route }
    func connection(_ route: DevelopmentLiveStream.Route) -> StreamConnection {
        let value = self.route
        return StreamConnection { [weak self] in
            let socket = FakeLiveSocket()
            route.current = value
            await socket.push(.hello(.init(deviceID: value.audience, libraryID: value.libraryID, workspaceID: value.workspaceID,
                                           serverTime: MemberRequestSignature.now(), capabilities: [WovenMatterShared.StreamProtocol.capability])))
            await MainActor.run { self?.sockets.append(socket) }
            return socket
        }
    }
}

private actor FakeLiveSocket: StreamTransport {
    private var inbox: [StreamFrame] = []
    private var receivers: [CheckedContinuation<StreamFrame, any Error>] = []
    private(set) var sent: [StreamFrame] = []
    private var closed = false

    func push(_ frame: StreamFrame) {
        if receivers.isEmpty { inbox.append(frame) } else { receivers.removeFirst().resume(returning: frame) }
    }
    func receive() async throws -> StreamFrame {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { throw StreamTransportClosed(code: 1000) }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }
    func send(_ frame: StreamFrame) async throws { sent.append(frame) }
    func ping() async throws {}
    func close(_ code: WovenMatterShared.StreamProtocol.CloseCode) async {
        closed = true
        for receiver in receivers { receiver.resume(throwing: StreamTransportClosed(code: code.rawValue)) }
        receivers.removeAll()
    }

    /// The wire ID of the client's subscription to `stream`.
    func subscription(_ stream: WovenMatterShared.StreamProtocol.Stream, conversationID: String? = nil) async throws -> String {
        for _ in 0..<500 {
            for frame in sent {
                if case .subscribe(let value) = frame, value.stream == stream.rawValue,
                   conversationID == nil || value.params.conversationID == conversationID { return value.id }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
    func cancelled(_ id: String) async throws {
        for _ in 0..<500 {
            if sent.contains(where: { if case .cancel(let value) = $0 { return value.id == id }; return false }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
}

private actor MacClientFakeCentral: LibraryTransport {
    var notes: [String: LibraryNote] = [:]
    var folders: [String: LibraryFolder] = [:]
    var publishedChanges: [LibraryChange] = []
    func publishNote(_ note: LibraryNote) {
        notes[note.id] = note
        publishedChanges.append(.init(cursor: Int64(publishedChanges.count + 1), resourceKind: .note,
            resourceID: note.id, operation: .upsert, revision: note.revision, note: note))
    }
    var receipts: [String: LibraryCommandReceipt] = [:]
    var sendCount = 0
    var offline = false
    func setOffline(_ value: Bool) { offline = value }
    var libraryID = "00000000-0000-4000-8000-000000000001"
    func setLibraryID(_ value: String) { libraryID = value }
    /// Every read of the library, as the HTTPS library API would see it.
    var reads = 0
    func workspaceIdentity() throws -> String { reads += 1; if offline { throw MobileConnectionError.offline }; return libraryID }
    func snapshot() -> LibrarySnapshot { reads += 1; return .init(workspaceID: libraryID, cursor: Int64(publishedChanges.count), folders: Array(folders.values), notes: Array(notes.values)) }
    func changes(after: Int64) -> LibraryChangePage { reads += 1; return .init(workspaceID: libraryID, cursor: Int64(publishedChanges.count), changes: publishedChanges.filter { $0.cursor > after }) }
    func mutate(_ mutation: LibraryMutation) throws -> LibraryMutationResult {
        if mutation.kind == .createFolder {
            let folder = LibraryFolder(id: mutation.resourceID, name: mutation.title ?? "", revision: 1)
            folders[folder.id] = folder
            return .init(operationID: mutation.operationID, status: .accepted, folder: folder)
        }
        let note = LibraryNote(id: mutation.resourceID, folderID: mutation.folderID, title: mutation.title ?? "", content: mutation.content ?? "", revision: 1)
        notes[note.id] = note
        return .init(operationID: mutation.operationID, status: .accepted, note: note)
    }
    func note(_ id: String) throws -> LibraryNote { try #require(notes[id]) }
    func providers() -> [HarnessCapabilities] { [.init(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)] }
    func pending() -> [PendingInteraction] { reads += 1; return [] }
    func transcript(_ id: String) -> LibraryTranscript { reads += 1; return .init(conversationID: id) }
    func command(_ command: LibraryCommand) throws -> LibraryCommandReceipt {
        if let receipt = receipts[command.commandID] { return receipt }
        let receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
        receipts[command.commandID] = receipt
        if command.kind == .send { sendCount += 1 }
        return receipt
    }
    func receipt(_ id: String) -> LibraryCommandReceipt? { receipts[id] }
}

private actor MacClientFakeExecution: ExecutionWorkspaceTransport {
    let workspace: ExecutionWorkspace
    var entries: [ExecutionJournalEntry] = []
    var receiptValues: [String: LibraryCommandReceipt] = [:]
    var sendCount = 0
    var lastSendText: String?
    init(workspace: ExecutionWorkspace) { self.workspace = workspace }
    var revoked = false
    var identityRequests = 0
    func setRevoked(_ value: Bool) { revoked = value }
    func identity() throws -> ExecutionWorkspace {
        identityRequests += 1
        // As HTTPSExecutionWorkspaceTransport reports a rejected bearer.
        if revoked { throw MobileConnectionError.revoked }; return workspace
    }
    func providers() -> [HarnessCapabilities] { [.init(id: "default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", routeName: "Linux", available: true)] }
    func pending() -> [PendingInteraction] { [] }
    func command(_ command: LibraryCommand) -> LibraryCommandReceipt {
        if let receipt = receiptValues[command.commandID] { return receipt }
        let id = command.conversationID ?? "invalid"
        let receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: id)
        receiptValues[command.commandID] = receipt
        if command.kind == .createSession {
            entries.append(.init(workspaceID: workspace.id, originSequence: Int64(entries.count + 1), conversationID: id,
                kind: .conversation, conversation: .init(id: id, title: "Direct chat", providerID: "default_agent")))
        }
        if command.kind == .send {
            sendCount += 1
            lastSendText = command.text
            entries.append(.init(workspaceID: workspace.id, originSequence: Int64(entries.count + 1), conversationID: id,
                kind: .transcript, transcript: .init(conversationID: id, messages: [.init(id: "message", conversationID: id, role: "assistant", content: "Direct result")])))
        }
        return receipt
    }
    func receipt(_ id: String) -> LibraryCommandReceipt? { receiptValues[id] }
    func events(after: Int64) -> ExecutionJournalPage { .init(libraryID: workspace.libraryID, cursor: Int64(entries.count), entries: Array(entries.dropFirst(Int(after)))) }
    func conversations() -> [LibraryConversation] { entries.compactMap(\.conversation) }
    func transcript(_ id: String) -> LibraryTranscript { entries.last(where: { $0.conversationID == id && $0.transcript != nil })?.transcript ?? .init(conversationID: id) }
}
