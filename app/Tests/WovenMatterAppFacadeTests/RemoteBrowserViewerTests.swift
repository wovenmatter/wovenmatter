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


    @Test func lateBackendFrameCannotRestoreRemovedWorkspace() async throws {
        let suite = "remote-browser-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = RemoteWorkspaceConfiguration(name: "Fixture", workspaceID: "fixture", hostName: "fixture.invalid", kind: .host)
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
        defaults.set(try JSONEncoder().encode([RemoteWorkspaceConfiguration]()), forKey: "wovenmatter.remote-workspaces.v1")
        let removed = RemoteWorkspacesModel(defaults: defaults, backendProjection: false)
        projection.applyBackendSnapshot(removed.backendSnapshot())
        completion.resume(returning: try JSONEncoder().encode(BackendRemoteWorkspaceResponse(
            snapshot: oldSnapshot, browserFrame: frame("first"))))
        await #expect(throws: CancellationError.self) { try await loading.value }
        #expect(projection.workspaces.isEmpty)
        #expect(projection.browserIdentity(for: configuration) == nil)
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
        #expect(actions.map(\.kind) == ["pointerDown", "pointerUp"])
        #expect(actions.first?.gestureID == actions.last?.gestureID)
        #expect(actions.first?.frameID == "pressed-frame")
        #expect(actions.last?.frameID == "newer-frame")
        #expect(actions.first?.x == 0.5 && actions.first?.y == 0.5)
        canvas.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(actions.count == 2) // Composition remains local until committed.
        canvas.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(actions.last?.text == "日本語")
        #expect(!canvas.hasMarkedText())
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        canvas.keyDown(with: enter)
        #expect(actions.last?.key == "Enter")
        canvas.resetInput()
    }

    @Test func nativeSurfaceCollaboratesWithRealBrowserWhenRequested() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["WOVENMATTER_BROWSER_INPUT_FIXTURE"],
              let url = URL(string: endpoint) else { return }
        let client = RemoteWorkspaceServiceClient(baseURL: url, token: "fixture")
        let catalog = try await client.browserTabs()
        let tab = try #require(catalog.tabs.first { $0.title == "Shared collaboration fixture" })
        let identity = RemoteWorkspaceRequestIdentity(configuration: .init(name: "Fixture", workspaceID: "fixture", hostName: "localhost"), credentialEpoch: UUID(), workspaceEpoch: UUID())
        let feed = RemoteBrowserFrameFeed(tabID: tab.id, identity: identity, frames: client.browserFrames(tabID: tab.id))
        defer { feed.stop() }
        let viewer = RemoteBrowserViewerModel(loadTabs: { try await client.browserTabs() },
            loadFrame: { _, previous in try await feed.latest(previousFrameID: previous) },
            sendBatch: { try await client.browserActions($0) }, sendAction: { try await client.browserAction($0) })
        viewer.select(tab.id); await viewer.refresh()
        #expect(viewer.frameID != nil)
        let firstImage = viewer.image
        let canvas = RemoteBrowserInputView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        canvas.image = viewer.image; canvas.frameID = viewer.frameID; canvas.tabID = tab.id; canvas.send = viewer.enqueue
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 800 - y), modifierFlags: [],
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { canvas.mouseDown(with: event) }
            else if type == .leftMouseDragged { canvas.mouseDragged(with: event) }
            else { canvas.mouseUp(with: event) }
        }
        func click(_ x: CGFloat, _ y: CGFloat) throws {
            try mouse(.leftMouseDown, x, y); try mouse(.leftMouseUp, x, y)
        }
        func state() async throws -> [String: String] {
            var request = URLRequest(url: url.appendingPathComponent("fixture/state"))
            request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
            return try JSONDecoder().decode([String: String].self, from: await URLSession.shared.data(for: request).0)
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
        var observed: [String: String] = [:]
        for _ in 0..<100 {
            observed = try await state()
            if observed["output"] == "Hello hi 日本語" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(observed["name"] == "hi 日本語")
        #expect(observed["output"] == "Hello hi 日本語")
        for _ in 0..<10 where viewer.image === firstImage { await viewer.refresh(includeTabs: false) }
        #expect(viewer.image !== firstImage)
        canvas.image = viewer.image; canvas.frameID = viewer.frameID
        try mouse(.leftMouseDown, 30, 220)
        try mouse(.leftMouseDragged, 290, 220)
        for _ in 0..<100 {
            observed = try await state()
            if Int(observed["level"] ?? "0") ?? 0 > 80 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Int(observed["level"] ?? "0") ?? 0 > 80)
        #expect(observed["held"] == "true") // The DOM changes before mouse-up.
        #expect(Int(observed["moves"] ?? "0") ?? 0 > 0)
        if ProcessInfo.processInfo.environment["WOVENMATTER_BROWSER_LONG_DRAG"] == "1" {
            // Exercise real frame expiry while continuing the same held gesture.
            for index in 0..<32 {
                try await Task.sleep(for: .seconds(1))
                await viewer.refresh(includeTabs: false)
                canvas.image = viewer.image; canvas.frameID = viewer.frameID
                try mouse(.leftMouseDragged, index.isMultiple(of: 2) ? 280 : 290, 220)
            }
            try await Task.sleep(for: .milliseconds(200))
            observed = try await state()
            #expect(observed["held"] == "true")
            #expect(Int(observed["level"] ?? "0") ?? 0 > 80)
            #expect(viewer.inputError == nil)
        }
        canvas.resetInput() // Dismissal/focus loss releases without requiring mouse-up.
        for _ in 0..<100 {
            observed = try await state()
            if observed["held"] == "false" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(observed["held"] == "false")
        #expect(viewer.inputError == nil)
        viewer.clear()
    }

    @Test func dragCoalescesAcrossFreshFramesWithoutDroppingRelease() async throws {
        var pending: CheckedContinuation<RemoteBrowserActionBatchResult, any Error>?
        var batches: [[RemoteBrowserAction]] = []
        let viewer = RemoteBrowserViewerModel(loadTabs: { .init(running: true, tabs: tabs) },
            loadFrame: { id, _ in try frame(id) }, sendBatch: { actions in
                batches.append(actions)
                if batches.count == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
                return .init(results: actions.map { .init(tabID: $0.tabID, accepted: true) })
            })
        await viewer.refresh()
        var down = RemoteBrowserAction(kind: "pointerDown")
        down.gestureID = UUID().uuidString; down.x = 0.1; down.y = 0.1
        viewer.enqueue(down)
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let completion = try #require(pending)
        for i in 1...70 {
            var move = RemoteBrowserAction(kind: "pointerMove")
            move.gestureID = down.gestureID; move.frameID = "new-frame-\(i)"; move.x = Double(i) / 100; move.y = 0.1
            viewer.enqueue(move)
        }
        var up = RemoteBrowserAction(kind: "pointerUp")
        up.gestureID = down.gestureID; up.frameID = "new-frame-70"; up.x = 0.7; up.y = 0.1
        viewer.enqueue(up)
        completion.resume(returning: .init(results: [.init(tabID: "first", accepted: true)]))
        for _ in 0..<100 where batches.count < 2 { await Task.yield() }
        #expect(batches.map(\.count) == [1, 2])
        #expect(batches.last?.map(\.kind) == ["pointerMove", "pointerUp"])
        #expect(batches.last?.first?.frameID == "new-frame-70")
        #expect(batches.last?.first?.x == 0.7)
        viewer.clear()
    }

    @Test func latestFrameFeedDropsObsoleteFramesAndStopsAfterItsLease() async throws {
        let pair = AsyncThrowingStream<RemoteBrowserFrame, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let identity = RemoteWorkspaceRequestIdentity(configuration: .init(name: "Fixture", workspaceID: "fixture", hostName: "localhost"), credentialEpoch: UUID(), workspaceEpoch: UUID())
        let feed = RemoteBrowserFrameFeed(tabID: "first", identity: identity, frames: pair.stream)
        for i in 0..<100 { pair.continuation.yield(.init(tabID: "first", imageBase64: "fixture", frameID: String(i), imageID: "same-image")) }
        let latest = try await feed.latest(previousFrameID: nil)
        #expect(latest.frameID == "99")
        #expect(try await feed.latest(previousFrameID: "99").imageBase64.isEmpty)
        feed.stopIfLeaseExpired(at: .now.advanced(by: .seconds(4)))
        #expect(feed.stopped)
        await #expect(throws: CancellationError.self) { try await feed.latest(previousFrameID: nil) }
    }

    @Test func measureNativeViewerWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["WOVENMATTER_BROWSER_PERFORMANCE"] == "1",
              let endpoint = ProcessInfo.processInfo.environment["WOVENMATTER_BROWSER_INPUT_FIXTURE"],
              let url = URL(string: endpoint) else { return }
        func memory() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.resident_size : 0
        }
        func measure(_ label: String, action: () async throws -> Void) async throws {
            let start = ContinuousClock.now, cpu = clock(), rss = memory()
            try await action()
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let percent = Double(clock() - cpu) / Double(CLOCKS_PER_SEC) / seconds * 100
            print("NATIVE_VIEWER \(label) cpu_one_core_percent=\(percent) rss_before_MiB=\(Double(rss)/1048576) rss_after_MiB=\(Double(memory())/1048576)")
        }
        try await measure("baseline") { try await Task.sleep(for: .seconds(5)) }
        let client = RemoteWorkspaceServiceClient(baseURL: url, token: "fixture")
        let tab = try #require(try await client.browserTabs().tabs.first { $0.title == "Shared collaboration fixture" })
        let identity = RemoteWorkspaceRequestIdentity(configuration: .init(name: "Fixture", workspaceID: "fixture", hostName: "localhost"), credentialEpoch: UUID(), workspaceEpoch: UUID())
        let feed = RemoteBrowserFrameFeed(tabID: tab.id, identity: identity, frames: client.browserFrames(tabID: tab.id))
        defer { feed.stop() }
        let viewer = RemoteBrowserViewerModel(loadTabs: { try await client.browserTabs() },
            loadFrame: { _, previous in try await feed.latest(previousFrameID: previous) })
        viewer.select(tab.id); await viewer.refresh()
        let canvas = RemoteBrowserInputView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Disposable remote browser performance fixture"
        window.isReleasedWhenClosed = false; window.contentView = canvas
        window.orderBack(nil)
        defer { window.close() }
        func renderForFiveSeconds() async throws {
            let start = ContinuousClock.now
            var drawn = 0
            while start.duration(to: .now) < .seconds(5) {
                let tick = ContinuousClock.now
                await viewer.refresh(includeTabs: false)
                if canvas.image !== viewer.image {
                    canvas.image = viewer.image; canvas.needsDisplay = true; canvas.displayIfNeeded(); drawn += 1
                }
                try await Task.sleep(until: tick.advanced(by: .milliseconds(16)), clock: .continuous)
            }
            print("NATIVE_VIEWER drawn_frames=\(drawn)")
        }
        try await measure("idle") { try await renderForFiveSeconds() }
        var request = URLRequest(url: url.appendingPathComponent("fixture/animation").appending(queryItems: [.init(name: "enabled", value: "true")]))
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: request)
        try await measure("animated") { try await renderForFiveSeconds() }
        request.url = url.appendingPathComponent("fixture/animation").appending(queryItems: [.init(name: "enabled", value: "false")])
        _ = try await URLSession.shared.data(for: request)
        viewer.clear()
    }

    @Test func renderViewerWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["WOVENMATTER_REMOTE_BROWSER_PREVIEW"] else { return }
        let viewer = RemoteBrowserViewerModel(loadTabs: { .init(running: true, tabs: tabs) }, loadFrame: { id, _ in try frame(id) })
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
