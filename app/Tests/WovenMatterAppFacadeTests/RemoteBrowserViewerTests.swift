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
        return .init(tabID: id, imageBase64: jpeg.base64EncodedString(), frameID: "frame-" + id)
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

    @Test func browserOperationsBypassCommandReplayStorage() async throws {
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
        let inputRequestID = UUID().uuidString
        var action = RemoteBrowserAction(kind: "text"); action.text = "ephemeral user input"
        let firstInput = BackendRPCRequest(id: inputRequestID, method: "remoteWorkspaces.command",
            payload: try JSONEncoder().encode(BackendRemoteWorkspaceCommand.browserAction(UUID(), action)))
        #expect(await backend.handle(firstInput).error == "This workspace is no longer configured.")
        let currentInput = BackendRPCRequest(id: inputRequestID, method: "remoteWorkspaces.command",
            payload: try JSONEncoder().encode(BackendRemoteWorkspaceCommand.browserAction(fixture.remote.id, action)))
        #expect(await backend.handle(currentInput).error == "Enable credential access in Settings to connect.")
    }

    @Test func nativeCanvasMapsLetterboxingAndEmitsRealPageGestures() throws {
        let canvas = RemoteBrowserInputView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        canvas.image = NSImage(size: NSSize(width: 1280, height: 800))
        #expect(canvas.normalizedPoint(NSPoint(x: 500, y: 360)) == NSPoint(x: 0.5, y: 0.5))
        #expect(canvas.normalizedPoint(NSPoint(x: 500, y: 20)) == nil)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        var actions: [RemoteBrowserAction] = []
        canvas.frameID = "pressed-frame"
        canvas.send = { actions.append($0) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 500, y: 360), modifierFlags: [],
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { canvas.mouseDown(with: event); canvas.frameID = "newer-frame" } else { canvas.mouseUp(with: event) }
        }
        #expect(actions.first?.kind == "click")
        #expect(actions.first?.frameID == "pressed-frame")
        #expect(actions.first?.x == 0.5 && actions.first?.y == 0.5)
        canvas.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(actions.count == 1) // Composition remains local until committed.
        canvas.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(actions.last?.text == "日本語")
        #expect(!canvas.hasMarkedText())
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        canvas.keyDown(with: enter)
        #expect(actions.last?.key == "Enter")
        canvas.resetInput()
    }

    @Test func queuedInputIsOrderedAndDismissalDiscardsUnsentText() async throws {
        var pending: CheckedContinuation<RemoteBrowserActionResult, any Error>?
        var sent: [RemoteBrowserAction] = []
        let viewer = RemoteBrowserViewerModel(loadTabs: { .init(running: true, tabs: tabs) }, loadFrame: { try frame($0) },
            sendAction: { action in
                sent.append(action)
                return try await withCheckedThrowingContinuation { pending = $0 }
            })
        await viewer.refresh()
        var click = RemoteBrowserAction(kind: "click"); click.x = 0.5; click.y = 0.5
        viewer.enqueue(click)
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let completion = try #require(pending)
        var text = RemoteBrowserAction(kind: "text"); text.text = "must not arrive after dismissal"
        viewer.enqueue(text)
        #expect(sent.count == 1)
        #expect(sent.first?.tabID == "first")
        #expect(sent.first?.frameID == "frame-first")
        viewer.clear()
        completion.resume(returning: .init(tabID: "first", accepted: true))
        for _ in 0..<20 { await Task.yield() }
        #expect(sent.count == 1)
        #expect(viewer.image == nil)
        #expect(viewer.tabs.isEmpty)
    }

    @Test func uncertainInputIsNotRetriedAndCannotDrainIntoAnotherTab() async throws {
        var pending: CheckedContinuation<RemoteBrowserActionResult, any Error>?
        var sent: [RemoteBrowserAction] = []
        let viewer = RemoteBrowserViewerModel(loadTabs: { .init(running: true, tabs: tabs) }, loadFrame: { try frame($0) },
            sendAction: { action in
                sent.append(action)
                return try await withCheckedThrowingContinuation { pending = $0 }
            })
        await viewer.refresh()
        var text = RemoteBrowserAction(kind: "text"); text.text = "first"
        viewer.enqueue(text)
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let completion = try #require(pending)
        text.text = "discarded"; viewer.enqueue(text)
        viewer.select("second")
        completion.resume(throwing: URLError(.timedOut))
        for _ in 0..<20 { await Task.yield() }
        #expect(sent.count == 1)
        #expect(viewer.selectedID == "second")
        #expect(viewer.inputError == nil)
    }

    @Test func nativeSurfaceCollaboratesWithRealBrowserWhenRequested() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["WOVENMATTER_BROWSER_INPUT_FIXTURE"],
              let url = URL(string: endpoint) else { return }
        let client = RemoteWorkspaceServiceClient(baseURL: url, token: "fixture")
        let catalog = try await client.browserTabs()
        let tab = try #require(catalog.tabs.first { $0.title == "Shared collaboration fixture" })
        let viewer = RemoteBrowserViewerModel(loadTabs: { try await client.browserTabs() },
            loadFrame: { try await client.browserFrame(tabID: $0) }, sendAction: { try await client.browserAction($0) })
        viewer.select(tab.id); await viewer.refresh()
        #expect(viewer.frameID != nil)
        let canvas = RemoteBrowserInputView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        canvas.image = viewer.image; canvas.frameID = viewer.frameID; canvas.tabID = tab.id; canvas.send = viewer.enqueue
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        func click(_ x: CGFloat, _ y: CGFloat) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 800 - y), modifierFlags: [],
                    timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
        }
        try click(100, 40)
        let selectAll = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(canvas.performKeyEquivalent(with: selectAll))
        for character in ["h", "i"] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
                windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: 4))
            canvas.keyDown(with: event)
        }
        canvas.insertText(" 日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        try click(60, 100)
        var state: [String: String] = [:]
        for _ in 0..<100 {
            var request = URLRequest(url: url.appendingPathComponent("fixture/state"))
            request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            state = try JSONDecoder().decode([String: String].self, from: data)
            if state["output"] == "Hello hi 日本語" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state["name"] == "hi 日本語")
        #expect(state["output"] == "Hello hi 日本語")
        #expect(viewer.inputError == nil)
        viewer.clear()
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
