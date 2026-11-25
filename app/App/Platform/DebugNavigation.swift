import SwiftUI
import WebKit

/// Debug builds only: with `--debug-open FILE`, every SIGUSR2 reads FILE and
/// shows what it names (`note:ID`, a window destination such as `library`, or
/// a sheet such as `history` or `trash`), so a build can be checked without
/// driving the mouse. Release builds ignore it.
struct DebugNavigation: ViewModifier {
    let openNote: (String) -> Void
    let show: (WindowDestination) -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(NotificationCenter.default.publisher(for: DebugNavigationSignal.name)) { notification in
            guard let request = notification.object as? String else { return }
            // After the post: a view that changes state while the notification is
            // still being delivered can subscribe again and receive it again.
            DispatchQueue.main.async {
                if request.hasPrefix("note:") { openNote(String(request.dropFirst(5))) }
                else if let destination = WindowDestination(rawValue: request) { show(destination) }
            }
        }
        .onAppear { DebugNavigationSignal.startIfRequested() }
        #else
        content
        #endif
    }
}

/// Runs `action` when the debug request names `request`.
struct DebugRequest: ViewModifier {
    let request: String
    let action: () -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(NotificationCenter.default.publisher(for: DebugNavigationSignal.name)) { notification in
            if notification.object as? String == request { DispatchQueue.main.async(execute: action) }
        }
        #else
        content
        #endif
    }
}

/// Runs `action` with the rest of a debug request that starts with `prefix`.
struct DebugCommand: ViewModifier {
    let prefix: String
    let action: (String) -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(NotificationCenter.default.publisher(for: DebugNavigationSignal.name)) { notification in
            if let request = notification.object as? String, request.hasPrefix(prefix) {
                let value = String(request.dropFirst(prefix.count))
                DispatchQueue.main.async { action(value) }
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Debug builds: `PREFIX…` requests run `action` with what follows the prefix.
    func debugCommand(_ prefix: String, _ action: @escaping (String) -> Void) -> some View {
        modifier(DebugCommand(prefix: prefix, action: action))
    }

    func debugRequest(_ request: String, _ action: @escaping () -> Void) -> some View {
        modifier(DebugRequest(request: request, action: action))
    }

    func debugNavigation(openNote: @escaping (String) -> Void, show: @escaping (WindowDestination) -> Void) -> some View {
        modifier(DebugNavigation(openNote: openNote, show: show))
    }
}

#if DEBUG
@MainActor
enum DebugNavigationSignal {
    static let name = Notification.Name("WovenDebugNavigation")
    private static var source: (any DispatchSourceSignal)?

    static func startIfRequested() {
        let arguments = CommandLine.arguments
        guard source == nil, let index = arguments.firstIndex(of: "--debug-open"), index + 1 < arguments.count else { return }
        let file = URL(fileURLWithPath: arguments[index + 1])
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if request.hasPrefix("web-snapshot:") {
                snapshotWebViews(to: URL(fileURLWithPath: String(request.dropFirst(13))))
            } else if request.hasPrefix("snapshot:") {
                snapshotWindow(to: URL(fileURLWithPath: String(request.dropFirst(9))), chatOnly: false)
            } else if request.hasPrefix("snapshot-chat:") {
                // Only the chat panel: the width of the largest scroll view, the window's height.
                snapshotWindow(to: URL(fileURLWithPath: String(request.dropFirst(14))), chatOnly: true)
            } else if request.hasPrefix("key-scroll:") {
                // `key-scroll:POINTS` moves the largest scroll view by POINTS
                // (negative is up) through its clip view, as Page Up and the
                // arrow keys do, with no scroll phase.
                let scrollViews = scrollViews(in: mainWindow?.contentView)
                guard let points = Double(request.dropFirst(11)),
                      let scrollView = scrollViews.max(by: { $0.visibleRect.height < $1.visibleRect.height }) else { return }
                let clip = scrollView.contentView
                var origin = clip.bounds.origin
                origin.y += clip.isFlipped ? points : -points
                clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
                scrollView.reflectScrolledClipView(clip)
            } else if request.hasPrefix("theme:") {
                // `theme:RAW` sets the app theme (green, cognac, dark), as Appearance does.
                UserDefaults.standard.set(String(request.dropFirst(6)), forKey: WovenTheme.storageKey)
            } else if request.hasPrefix("window:") {
                // `window:WxH` resizes the main window, in points, keeping its top left.
                let size = request.dropFirst(7).split(separator: "x").compactMap { Double($0) }
                if size.count == 2, let window = mainWindow {
                    var frame = window.frame
                    frame.origin.y += frame.height - size[1]
                    frame.size = CGSize(width: size[0], height: size[1])
                    window.setFrame(frame, display: true)
                }
            } else {
                NotificationCenter.default.post(name: name, object: request)
            }
        }
        source.resume()
        self.source = source
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private static var mainWindow: NSWindow? {
        NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    /// `snapshot:PATH` writes the main window as a PNG at its backing scale,
    /// drawn by the app itself, so it needs no screen. Web views draw blank
    /// that way, so each visible one's own snapshot is drawn in where it
    /// sits. The file is written last, in one piece, so a script can wait for it.
    private static func snapshotWindow(to path: URL, chatOnly: Bool) {
        guard let view = mainWindow?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        func webViews(in view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        let shown = webViews(in: view).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
        var pieces: [(image: NSImage, frame: NSRect, whole: NSRect, framed: Bool)] = []
        let group = DispatchGroup()
        for webView in shown {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.visibleRect
            let frame = view.convert(webView.visibleRect, from: webView)
            let whole = view.convert(webView.bounds, from: webView)
            // A visual reply sits at the bottom of its rounded, stroked frame.
            let framed = webView is ConversationHTMLNativeWebView
            group.enter()
            webView.takeSnapshot(with: configuration) { image, _ in
                if let image { pieces.append((image, frame, whole, framed)) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                func unflipped(_ rect: NSRect) -> NSRect {
                    view.isFlipped ? NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
                }
                for piece in pieces {
                    NSGraphicsContext.saveGraphicsState()
                    if piece.framed {
                        // Only what the frame shows: inside its stroke, with its
                        // rounded bottom corners (the header above keeps the top ones).
                        let whole = unflipped(piece.whole)
                        let radius = ConversationMetrics.blockRadius - 1
                        NSBezierPath(roundedRect: NSRect(x: whole.minX + 1, y: whole.minY + 1, width: whole.width - 2,
                                                         height: whole.height + radius), xRadius: radius, yRadius: radius).addClip()
                    }
                    piece.image.draw(in: unflipped(piece.frame))
                    NSGraphicsContext.restoreGraphicsState()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            var output = bitmap
            if chatOnly, let panel = scrollViews(in: view).max(by: { $0.visibleRect.height < $1.visibleRect.height }),
               let image = bitmap.cgImage {
                let frame = view.convert(panel.bounds, from: panel)
                let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let crop = CGRect(x: frame.minX * scale, y: 0, width: frame.width * scale, height: CGFloat(bitmap.pixelsHigh))
                if let cropped = image.cropping(to: crop.integral) { output = NSBitmapImageRep(cgImage: cropped) }
            }
            try? output.representation(using: .png, properties: [:])?.write(to: path, options: .atomic)
        }
    }

    /// Window captures draw web content blank, so `web-snapshot:PATH` writes
    /// each visible web view's own snapshot as PATH-N.png.
    private static func snapshotWebViews(to path: URL) {
        func webViews(in view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        let views = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(webViews)
        for (index, webView) in views.enumerated() {
            webView.takeSnapshot(with: nil) { image, _ in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
                try? bitmap.representation(using: .png, properties: [:])?.write(to: path.appendingPathExtension("\(index).png"))
            }
        }
    }
}
#endif
