import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct CompanionRunControlTests {
    @Test func gatewaySessionCreationUsesLinkedAgentWithoutAnyACPLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let agentID = UUID(), conversationID = UUID().uuidString.lowercased()
        try database.saveOpenClawGatewayLink(.init(agentID: agentID, location: .localAgentWorkspace,
            endpoint: .init(url: URL(string: "ws://127.0.0.1:1")!, authorization: .localService)))
        let created = try database.createLocalACPSession(runtimeKind: .openclaw, title: "Gateway fixture",
            ownerDeviceID: UUID(), conversationID: conversationID, gatewayAgentID: agentID)
        #expect(created == conversationID)
        let session = try database.openClawGatewaySession(conversationID: created)
        #expect(session.agentID == agentID)
        #expect(session.sessionKey == "agent:main:wovenmatter:\(conversationID)")
        #expect(try database.localACPSession(conversationID: created).runtimeKind == .openclaw)
    }

    @Test func recoveryCopyRetainsUnknownBytesAndRetryCannotResurrectDeletedCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let sourceID = UUID().uuidString.lowercased()
        let raw = #"{"version":999,"blocks":[{"type":"future","unknown":{"value":"Do not flatten"}}]}"#
        let copyID = try database.preserveRecoveryCopy(sourceID: sourceID, title: "Preserved", content: raw, folderID: nil)
        #expect(copyID != sourceID)
        #expect(try database.companionNote(id: copyID)?.content == raw)
        #expect(try database.preserveRecoveryCopy(sourceID: sourceID, title: "Preserved", content: raw, folderID: nil) == copyID)
        let revision = try #require(try database.companionNote(id: copyID)?.revision)
        let deleted = try database.applyCompanionMutation(.init(deviceID: UUID().uuidString, kind: .deleteNote,
            resourceID: copyID, expectedRevision: revision))
        #expect(deleted.status == .accepted)
        #expect(throws: WorkspaceNoteMutationError.noteNotFound) {
            try database.preserveRecoveryCopy(sourceID: sourceID, title: "Preserved", content: raw, folderID: nil)
        }
        #expect(try database.companionNote(id: copyID) == nil)
    }

    @Test(arguments: AgentRuntimeKind.allCases, [true, false])
    func acceptedRunSurvivesCallerDisconnectAndControlsAreRunTargeted(runtime: AgentRuntimeKind, steeringAdvertised: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = UUID().uuidString.lowercased()
        let conversationID = try database.createLocalACPSession(runtimeKind: runtime, title: "Companion fixture", ownerDeviceID: UUID(), conversationID: id)
        #expect(conversationID == id)
        let gate = CompanionPromptGate()
        let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
            LocalACPSessionDriver(initializeSession: { _, _, _, _ in
                .init(sessionID: "fixture", loadedExistingSession: false)
            }, prompt: { input, onEvent, _, _ in
                try await onEvent?(.assistantChunk("Fixture output"))
                await gate.wait(input: input)
                return .cancelled
            }, configuration: { .empty }, setConfiguration: { _, _ in .empty },
            activeInput: { _ in .init(completion: Task { nil }) },
            activeInputCapability: { LocalACPClient.activeInputRoute(runtimeKind: runtime, steeringSupported: steeringAdvertised) },
            cancel: { await gate.release() }, shutdown: { await gate.release() })
        })
        let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: runtime, executableURL: URL(filePath: "/nonexistent-fake-provider"), arguments: [])
        let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory, repositoriesURL: directory)
        let noteID = try database.createNote(folderID: nil, title: "Offline idea", content: "Capture once")
        let note = try #require(try database.companionNote(id: noteID))
        let reference = AgentMessageReferenceDraft(kind: .note, resourceID: noteID,
            titleSnapshot: note.title, contentSnapshot: note.content, revisionSnapshot: String(note.revision))
        let input = AgentMessageInput(text: "Develop this idea", attachments: [.reference(reference)])
        let caller = Task { try await coordinator.accept(conversationID: id, input: input,
            noteContext: .init(noteID: noteID, title: note.title, folderID: nil, revision: String(note.revision)),
            launch: launch, workspace: workspace) }
        let run = try await caller.value
        caller.cancel()
        for _ in 0..<200 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.started)
        #expect(await gate.input?.references.first?.resourceID == noteID)
        #expect(await gate.input?.references.first?.revisionSnapshot == String(note.revision))
        #expect(await gate.input?.references.first?.contentSnapshot == note.content)
        let persistedReference = try #require(try database.conversationContent(id: id).references.first(where: { $0.id == reference.id }))
        #expect(persistedReference.resourceID == noteID)
        #expect(persistedReference.revisionSnapshot == String(note.revision))
        #expect(persistedReference.contentSnapshot == note.content)
        // A later canonical edit cannot rewrite the immutable run reference.
        _ = try database.updateNote(id: noteID, title: "Later title", content: note.content, expectedRevision: String(note.revision))
        #expect(try database.conversationContent(id: id).references.first(where: { $0.id == reference.id })?.titleSnapshot == "Offline idea")
        #expect(try database.conversationContent(id: id).runs.first?.status == "running")
        #expect(await coordinator.activeInputCapability(conversationID: id) == LocalACPClient.activeInputRoute(runtimeKind: runtime, steeringSupported: steeringAdvertised))
        await #expect(throws: LocalACPSessionDatabaseError.runNotFound) {
            try await coordinator.cancel(conversationID: id, expectedRunID: "stale-run")
        }
        await #expect(throws: LocalACPSessionDatabaseError.runNotFound) {
            try await coordinator.sendActiveInput(conversationID: id, input: .init(text: "Stale"), expectedRunID: "stale-run")
        }
        if LocalACPClient.activeInputRoute(runtimeKind: runtime, steeringSupported: steeringAdvertised) == .unsupported {
            let count = try database.conversationContent(id: id).messages.count
            await #expect(throws: LocalACPSessionDatabaseError.steeringUnsupported) {
                try await coordinator.sendActiveInput(conversationID: id, input: .init(text: "Unsupported"), expectedRunID: run.runID)
            }
            #expect(try database.conversationContent(id: id).messages.count == count)
        } else {
            let steering = try await coordinator.sendActiveInput(conversationID: id, input: .init(text: "Follow up"), expectedRunID: run.runID)
            #expect(steering.runID == run.runID)
        }
        try await coordinator.cancel(conversationID: id, expectedRunID: run.runID)
        for _ in 0..<200 {
            if try database.conversationContent(id: id).runs.first?.status != "running" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try database.conversationContent(id: id).runs.count == 1)
        #expect(try database.conversationContent(id: id).runs.first?.status != "running")
        await coordinator.shutdown()
    }
}

private actor CompanionPromptGate {
    private(set) var started = false
    private(set) var input: AgentMessageInput?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait(input: AgentMessageInput) async {
        self.input = input
        started = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
