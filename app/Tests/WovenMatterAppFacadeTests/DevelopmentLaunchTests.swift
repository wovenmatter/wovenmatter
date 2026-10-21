import CompanionClient
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct DevelopmentLaunchTests {
    @Test func linkedAssetsKeepTheirHostPreviewWhileOrdinaryNotesUseTheDesktopEditor() throws {
        let link = DatabaseArtifactLink(sourceID: "host", databaseID: "data", relativePath: "data.sqlite", sqliteQuery: "SELECT 1")
        let linked = try NoteDocument(kind: .html, html: "<p>Preview</p>", databaseLink: link).encoded()
        #expect(DevelopmentLibraryProjection.usesCentralPreview(.init(id: "linked", title: "Linked", content: linked, revision: 1)))
        #expect(!DevelopmentLibraryProjection.usesCentralPreview(.init(id: "ordinary", title: "Note", content: "Text", revision: 1)))
    }

    @Test func duplicateLaunchCanOnlyActivateItsOwnInstance() {
        let production = WorkspaceProcessLeaseOwner(processIdentifier: 1, bundleIdentifier: "wovenmatter.desktop", bundlePath: "/production")
        let own = WorkspaceProcessLeaseOwner(processIdentifier: 2, bundleIdentifier: "wovenmatter.desktop.dev.a.live", bundlePath: "/own")
        var activated: [Int32] = []
        func candidate(_ owner: WorkspaceProcessLeaseOwner) -> WorkspaceProcessLeaseActivationCandidate {
            .init(owner: owner, isTerminated: { false }, activate: { activated.append(owner.processIdentifier); return true })
        }
        let ownHandoff = WorkspaceProcessLease.verifyIncumbentHandoff(own, currentProcessIdentifier: 3,
            currentBundleIdentifier: own.bundleIdentifier, candidateForProcessIdentifier: { _ in candidate(own) },
            candidatesForBundleIdentifier: { _ in [candidate(production)] })
        #expect(ownHandoff == .activated(own))
        activated = []
        let foreignHandoff = WorkspaceProcessLease.verifyIncumbentHandoff(production, currentProcessIdentifier: 3,
            currentBundleIdentifier: own.bundleIdentifier, candidateForProcessIdentifier: { _ in candidate(production) },
            candidatesForBundleIdentifier: { _ in [candidate(production)] })
        #expect(foreignHandoff == .unavailable)
        #expect(activated.isEmpty)
    }

    @Test func replicasHaveIndependentIdentityAndCredentialNamespaces() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try MobileStore(file: directory.appending(path: "a/library.json"))
        let b = try MobileStore(file: directory.appending(path: "b/library.json"))
        let library = UUID().uuidString.lowercased()
        let note = CompanionNote(id: UUID().uuidString.lowercased(), title: "Shared", content: "same content", revision: 1)
        for store in [a, b] { try await store.apply(.init(workspaceID: library, cursor: 0, notes: [note])) }
        let first = await a.snapshot(), second = await b.snapshot()
        #expect(first.deviceID != second.deviceID)
        #expect(first.notes == second.notes)
        #expect(ClientCredentialNamespace.service("pairing", bundleID: "wovenmatter.desktop") == "pairing")
        #expect(ClientCredentialNamespace.service("pairing", bundleID: "wovenmatter.desktop.dev.a.live")
            != ClientCredentialNamespace.service("pairing", bundleID: "wovenmatter.desktop.dev.b.live"))
        #expect(WovenMatterKeychainService.name(forBundleIdentifier: "wovenmatter.desktop.dev.a.live")
            != WovenMatterKeychainService.name(forBundleIdentifier: "wovenmatter.desktop"))
    }

    @Test func localEnrollmentIsIndependentDurableAndRevocable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "devices.json")
        let auth = try CompanionAuthentication(fileURL: file)
        let library = UUID().uuidString.lowercased(), a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        let first = try await auth.enrollLocalDevelopment(deviceID: a, name: "Dev · a", workspaceID: library)
        let second = try await auth.enrollLocalDevelopment(deviceID: b, name: "Dev · b", workspaceID: library)
        #expect(first.credential != second.credential)
        let reopened = try CompanionAuthentication(fileURL: file)
        #expect(try await reopened.authenticate(bearer: first.credential).id == a)
        try await reopened.revoke(deviceID: a)
        await #expect(throws: (any Error).self) { try await reopened.authenticate(bearer: first.credential) }
        #expect(try await reopened.authenticate(bearer: second.credential).id == b)
        await #expect(throws: (any Error).self) {
            try await reopened.enrollLocalDevelopment(deviceID: b, name: "Dev · different", workspaceID: library)
        }
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(second.credential))
    }

    @Test func snapshotOfRealSchemaPreservesHistoryWithoutSchedulingCopiedTasks() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = try await fixture.createConversation()
        let now = Date()
        let task = WorkspaceCalendarTask(prompt: "Fixture only", configuration: .init(runtimeKind: .codex,
            title: "Fixture", model: "fixture", thinking: "high", permission: "read-only",
            nativeWorkingDirectory: fixture.directory.path, tools: .init(enabled: [.notes])))
        let event = try await fixture.database.saveCalendarEvent(draft: .init(title: "Copied schedule",
            startsAt: now, timeZoneID: "UTC", task: task), creating: true, now: now)
        let originalIdentity = try await fixture.database.companionWorkspaceID()
        let identity = try await fixture.database.companionLibraryIdentity()
        let foreignOwner = UUID().uuidString.lowercased(), foreignID = UUID().uuidString.lowercased()
        let owner = CompanionExecutionWorkspace(id: foreignOwner, libraryID: originalIdentity,
            ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Foreign",
            endpoint: URL(string: "https://fixture.test.ts.net:8443/wovenmatter"))
        _ = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: owner), deviceID: identity.hostDeviceID)
        let foreignHistory = CompanionTranscript(conversationID: foreignID,
            messages: [.init(id: "saved", conversationID: foreignID, role: "assistant", content: "Retained foreign history")])
        _ = try await fixture.database.ingestCompanionJournal(.init(libraryID: originalIdentity, entries: [
            .init(workspaceID: foreignOwner, originSequence: 1, conversationID: foreignID,
                  kind: .conversation, conversation: .init(id: foreignID, title: "Foreign")),
            .init(workspaceID: foreignOwner, originSequence: 2, conversationID: foreignID,
                  kind: .transcript, transcript: foreignHistory)
        ]), deviceID: identity.hostDeviceID)
        let destination = fixture.directory.deletingLastPathComponent().appending(path: "snapshot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appending(path: "scripts/dev-build.py").path, "snapshot",
            "--source", fixture.directory.path, "--destination", destination.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let snapshot = try await WorkspaceDatabase(url: destination.appending(path: "workspace.sqlite"))
        #expect(try await snapshot.companionWorkspaceID() != originalIdentity)
        let snapshotOwner = try #require(try await snapshot.companionExecutionWorkspaces().first)
        #expect(snapshotOwner.endpoint == nil)
        #expect(snapshotOwner.libraryID == (try await snapshot.companionWorkspaceID()))
        #expect(try await snapshot.companionFederatedTranscript(conversationID: foreignID)?.messages == foreignHistory.messages)
        let archived = try #require(try await snapshot.workspaceOverview().conversations.first { $0.id == id })
        #expect(archived.isArchived)
        await #expect(throws: (any Error).self) { try await snapshot.localACPSession(conversationID: id) }
        #expect(try await snapshot.calendarItems().contains { $0.id == event })
        #expect(try await snapshot.dueCalendarRuns(now: now.addingTimeInterval(1)).isEmpty)
        let new = try await snapshot.saveCalendarEvent(draft: .init(title: "New snapshot schedule",
            startsAt: now, timeZoneID: "UTC", task: task), creating: true, now: now)
        #expect(try await snapshot.dueCalendarRuns(now: now.addingTimeInterval(1)).map(\.eventID) == [new])
        #expect(try await fixture.database.companionWorkspaceID() == originalIdentity)
        #expect(try await fixture.database.calendarItems().count == 1)
    }
}
