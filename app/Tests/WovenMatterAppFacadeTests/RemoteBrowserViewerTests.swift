import AppKit
import SwiftUI
import Testing
import WovenMatterClient
@testable import WovenMatterAppFacade

@MainActor struct RemoteBrowserViewerTests {
    private let tabs = [RemoteBrowserTab(id: "first", title: "Local development", url: "http://localhost:3000"),
                        RemoteBrowserTab(id: "second", title: "Documentation", url: "https://example.test/docs")]

    private func frame(_ id: String) throws -> RemoteBrowserFrame {
        let image = NSImage(size: NSSize(width: 1280, height: 800), flipped: false) { bounds in
            NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.95, alpha: 1).setFill()
            bounds.fill()
            ("Workspace development preview" as NSString).draw(at: NSPoint(x: 70, y: 650),
                withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.black])
            ("This page is running inside the remote workspace." as NSString).draw(at: NSPoint(x: 70, y: 590),
                withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray])
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]))
        return .init(tabID: id, imageBase64: jpeg.base64EncodedString())
    }

    @Test func selectionChangesAndViewerDismissalRejectLateFrames() async throws {
        var pending: CheckedContinuation<RemoteBrowserFrame, any Error>?
        let viewer = RemoteBrowserViewerModel(loadTabs: { .init(running: true, tabs: tabs) },
            loadFrame: { _ in try await withCheckedThrowingContinuation { pending = $0 } })
        let loading = Task { await viewer.refresh() }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let first = try #require(pending)
        viewer.select("second")
        first.resume(returning: try frame("first"))
        await loading.value
        #expect(viewer.selectedID == "second")
        #expect(viewer.image == nil)
        pending = nil
        let secondLoading = Task { await viewer.refresh() }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let second = try #require(pending)
        viewer.clear()
        second.resume(returning: try frame("second"))
        await secondLoading.value
        #expect(viewer.tabs.isEmpty)
        #expect(viewer.image == nil)
        #expect(viewer.updatedAt == nil)
    }

    @Test func closedTabsAndConnectionErrorsClearOldImages() async throws {
        var catalog = tabs
        var offline = false
        let viewer = RemoteBrowserViewerModel(loadTabs: {
            if offline { throw URLError(.notConnectedToInternet) }
            return .init(running: true, tabs: catalog)
        }, loadFrame: { try frame($0) })
        await viewer.refresh()
        #expect(viewer.image != nil)
        catalog = [tabs[1]]
        await viewer.refresh()
        #expect(viewer.selectedID == "second")
        #expect(viewer.image != nil)
        offline = true
        await viewer.refresh()
        #expect(viewer.image == nil)
        #expect(viewer.tabs.isEmpty)
        #expect(viewer.error != nil)
    }

    @Test func frameIdentityMustMatchSelectedTab() async throws {
        let viewer = RemoteBrowserViewerModel(loadTabs: { .init(running: true, tabs: tabs) },
            loadFrame: { _ in try frame("different-tab") })
        await viewer.refresh()
        #expect(viewer.image == nil)
        #expect(viewer.error != nil)
    }

    @Test func lateBackendFrameCannotRestoreRevokedWorkspaceAccess() async throws {
        let suite = "remote-browser-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = RemoteWorkspaceConfiguration(name: "Fixture", workspaceID: "fixture", hostName: "fixture.invalid")
        defaults.set(true, forKey: "wovenmatter.remote-workspaces.credential-access-enabled")
        defaults.set(try JSONEncoder().encode([configuration]), forKey: "wovenmatter.remote-workspaces.v1")
        let owner = RemoteWorkspacesModel(defaults: defaults, backendProjection: false)
        let projection = RemoteWorkspacesModel(defaults: defaults, backendProjection: true)
        let oldSnapshot = owner.backendSnapshot()
        projection.applyBackendSnapshot(oldSnapshot)
        var pending: CheckedContinuation<Data, any Error>?
        projection.backendRequest = { method, _ in
            #expect(method == "remoteWorkspaces.command")
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let loading = Task { try await projection.browserFrame(tabID: "first", for: configuration) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let completion = try #require(pending)
        owner.disableCredentialAccess()
        projection.applyBackendSnapshot(owner.backendSnapshot())
        completion.resume(returning: try JSONEncoder().encode(BackendRemoteWorkspaceResponse(
            snapshot: oldSnapshot, browserFrame: frame("first"))))
        await #expect(throws: CancellationError.self) { try await loading.value }
        #expect(!projection.isCredentialAccessEnabled)
        #expect(projection.browserIdentity(for: configuration) == nil)
    }

    @Test func browserReadsBypassCommandReplayStorage() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let backend = BackendApplicationService(model: fixture.model)
        let requestID = UUID().uuidString
        let missing = BackendRPCRequest(id: requestID, method: "remoteWorkspaces.command",
            payload: try JSONEncoder().encode(BackendRemoteWorkspaceCommand.browserTabs(UUID())))
        #expect(await backend.handle(missing).error == "This workspace is no longer configured.")
        fixture.model.remoteWorkspaces.disableCredentialAccess()
        let current = BackendRPCRequest(id: requestID, method: "remoteWorkspaces.command",
            payload: try JSONEncoder().encode(BackendRemoteWorkspaceCommand.browserTabs(fixture.remote.id)))
        #expect(await backend.handle(current).error == "Enable credential access in Settings to connect.")
    }

    @Test func renderViewerWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["WOVENMATTER_REMOTE_BROWSER_PREVIEW"] else { return }
        let viewer = RemoteBrowserViewerModel(loadTabs: { .init(running: true, tabs: tabs) }, loadFrame: { try frame($0) })
        await viewer.refresh()
        for (theme, appearance, width) in [(DashboardTheme.green, NSAppearance.Name.aqua, 1000), (.cognac, .aqua, 700), (.dark, .darkAqua, 700)] {
            let view = NSHostingView(rootView: RemoteBrowserContent(viewer: viewer, workspaceName: "Development workspace", onClose: {}).environment(\.dashboardTheme, theme))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: width, height: 720)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output + "-" + theme.rawValue + ".png"))
        }
    }
}
