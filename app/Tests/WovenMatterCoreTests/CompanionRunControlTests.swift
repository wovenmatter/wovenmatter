import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct CompanionRunControlTests {

    @Test func recoveryCopyRetainsUnknownBytesAndRetryCannotResurrectDeletedCopy() async throws {
        let persistence = try PersistenceFixture(); defer { persistence.remove() }
        let database = try await persistence.openDatabase()
        let sourceID = UUID().uuidString.lowercased()
        let raw = #"{"version":999,"blocks":[{"type":"future","unknown":{"value":"Do not flatten"}}]}"#
        let copyID = try await database.preserveRecoveryCopy(sourceID: sourceID, title: "Preserved", content: raw, folderID: nil)
        #expect(copyID != sourceID)
        #expect(try await database.companionNote(id: copyID)?.content == raw)
        #expect(try await database.preserveRecoveryCopy(sourceID: sourceID, title: "Preserved", content: raw, folderID: nil) == copyID)
        let revision = try #require(try await database.companionNote(id: copyID)?.revision)
        let deleted = try await database.applyCompanionMutation(.init(deviceID: UUID().uuidString, kind: .deleteNote,
            resourceID: copyID, expectedRevision: revision))
        #expect(deleted.status == .accepted)
        await #expect(throws: WorkspaceNoteMutationError.noteNotFound) {
            try await database.preserveRecoveryCopy(sourceID: sourceID, title: "Preserved", content: raw, folderID: nil)
        }
        #expect(try await database.companionNote(id: copyID) == nil)
    }


    // OpenCode v2 owns its native HTTP session lifecycle; legacy ACP transcripts
    // are read-only. Its acceptance/disconnect recovery is covered by
    // OpenCodeIntegrationTests rather than this injected ACP driver matrix.
    @Test(arguments: AgentRuntimeKind.allCases.filter { $0 != .opencode }, [true, false])
    func acceptedRunSurvivesCallerDisconnectAndControlsAreRunTargeted(runtime: AgentRuntimeKind, steeringAdvertised: Bool) async throws {
        let persistence = try PersistenceFixture(); defer { persistence.remove() }
        let database = try await persistence.openDatabase()
        let requestedConversationID = UUID()
        let id = requestedConversationID.uuidString.lowercased()
        let conversationID = try await database.createFixtureLocalACPSession(runtimeKind: runtime, title: "Companion fixture", ownerDeviceID: UUID(), requestedConversationID: requestedConversationID,
            fixtureLocation: .init(workspaceID: "device:fixture", rootPath: persistence.directory.path, managed: false))
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
            activeInput: { _ in
                guard LocalACPClient.activeInputRoute(runtimeKind: runtime, steeringSupported: steeringAdvertised) != .unsupported else {
                    throw LocalACPSessionDatabaseError.steeringUnsupported
                }
                return .init(completion: Task { nil })
            },
            activeInputCapability: { LocalACPClient.activeInputRoute(runtimeKind: runtime, steeringSupported: steeringAdvertised) },
            cancel: { await gate.release() }, shutdown: { await gate.release() })
        })
        let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: runtime, executableURL: URL(filePath: "/nonexistent-fake-provider"), arguments: [])
        let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: persistence.directory)
        let noteID = try await database.createNote(folderID: nil, title: "Offline idea", content: "Capture once")
        let note = try #require(try await database.companionNote(id: noteID))
        let reference = AgentMessageReferenceDraft(kind: .note, resourceID: noteID,
            titleSnapshot: note.title, contentSnapshot: note.content, revisionSnapshot: String(note.revision))
        let input = AgentMessageInput(text: "Develop this idea", attachments: [.reference(reference)])
        let caller = Task { try await coordinator.accept(conversationID: id, input: input,
            noteContext: .init(noteID: noteID, title: note.title, folderID: nil, revision: String(note.revision)),
            launch: launch, workspace: workspace) }
        let run = try await caller.value
        caller.cancel()
        _ = try await pollUntil(attempts: 200, interval: .milliseconds(10)) { await gate.started }
        #expect(await gate.started)
        #expect(await gate.input?.references.first?.resourceID == noteID)
        #expect(await gate.input?.references.first?.revisionSnapshot == String(note.revision))
        #expect(await gate.input?.references.first?.contentSnapshot == note.content)
        let persistedReference = try #require(try await database.conversationContent(id: id).references.first(where: { $0.id == reference.id }))
        #expect(persistedReference.resourceID == noteID)
        #expect(persistedReference.revisionSnapshot == String(note.revision))
        #expect(persistedReference.contentSnapshot == note.content)
        // A later canonical edit cannot rewrite the immutable run reference.
        _ = try await database.persistNoteDraft(id: noteID, title: "Later title", content: note.content, expectedRevision: String(note.revision))
        #expect(try await database.conversationContent(id: id).references.first(where: { $0.id == reference.id })?.titleSnapshot == "Offline idea")
        #expect(try await database.conversationContent(id: id).runs.first?.status == "running")
        #expect(await coordinator.activeInputCapability(conversationID: id) == LocalACPClient.activeInputRoute(runtimeKind: runtime, steeringSupported: steeringAdvertised))
        await #expect(throws: LocalACPSessionDatabaseError.runNotFound) {
            try await coordinator.cancel(conversationID: id, expectedRunID: "stale-run")
        }
        await #expect(throws: LocalACPSessionDatabaseError.runNotFound) {
            try await coordinator.sendActiveInput(conversationID: id, input: .init(text: "Stale"), expectedRunID: "stale-run")
        }
        if LocalACPClient.activeInputRoute(runtimeKind: runtime, steeringSupported: steeringAdvertised) == .unsupported {
            let count = try await database.conversationContent(id: id).messages.count
            await #expect(throws: LocalACPSessionDatabaseError.steeringUnsupported) {
                try await coordinator.sendActiveInput(conversationID: id, input: .init(text: "Unsupported"), expectedRunID: run.runID)
            }
            #expect(try await database.conversationContent(id: id).messages.count == count)
        } else {
            let steering = try await coordinator.sendActiveInput(conversationID: id, input: .init(text: "Follow up"), expectedRunID: run.runID)
            #expect(steering.runID == run.runID)
        }
        try await coordinator.cancel(conversationID: id, expectedRunID: run.runID)
        _ = try await pollUntil(attempts: 200, interval: .milliseconds(10)) {
            try await database.conversationContent(id: id).runs.first?.status != "running"
        }
        #expect(try await database.conversationContent(id: id).runs.count == 1)
        #expect(try await database.conversationContent(id: id).runs.first?.status != "running")
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
