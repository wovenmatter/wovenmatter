import CoreImage
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
            } else if request.hasPrefix("snapshot-sheet:") {
                // The sheet over the main window, such as an expanded visual reply.
                snapshotWindow(to: URL(fileURLWithPath: String(request.dropFirst(15))), chatOnly: false, sheet: true)
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
                ConversationReaderInput.note()
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
    private static func snapshotWindow(to path: URL, chatOnly: Bool, sheet: Bool = false) {
        guard let view = (sheet ? mainWindow?.attachedSheet : mainWindow)?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // The window as drawn, copied apart for redrawing what floats over the
        // pages. (Never the composite's own image: asked for before the pages
        // are drawn in, it would hand that earlier image back for the file.)
        let covers = Array(ConversationEdgeSnapshot.covers.values)
        let window: CGImage? = ConversationHTMLControlsSnapshot.shown.isEmpty && covers.isEmpty ? nil
            : (bitmap.copy() as? NSBitmapImageRep)?.cgImage
        // Window captures draw glass (the composer) clear. The window again with
        // the transcripts under each glass surface left out gives the surface's
        // own content alone, drawn sharp over what it blurs. The transcripts are
        // hidden only for this capture and shown again before anything reaches
        // the screen.
        let glass = Array(ConversationEdgeSnapshot.glass.values)
        // Only where the glass is: the rest of the window is not drawn again.
        let glassArea = glass.reduce(CGRect.null) { $0.union($1) }.intersection(view.bounds)
        let clean: CGImage? = glassArea.isEmpty ? nil : {
            let under = scrollViews(in: view).filter { scroll in
                guard !scroll.isHidden else { return false }
                let frame = view.convert(scroll.bounds, from: scroll)
                return glass.contains { frame.contains(CGPoint(x: $0.midX, y: $0.midY)) && frame.height > 2 * $0.height }
            }
            under.forEach { $0.isHidden = true }
            defer { under.forEach { $0.isHidden = false } }
            let area = view.isFlipped ? glassArea
                : CGRect(x: glassArea.minX, y: view.bounds.height - glassArea.maxY, width: glassArea.width, height: glassArea.height)
            guard let copy = view.bitmapImageRepForCachingDisplay(in: area) else { return nil }
            view.cacheDisplay(in: area, to: copy)
            return copy.cgImage
        }()
        func webViews(in view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        // What the window shows: a web view drawn fully transparent (a visual
        // reply still loading) shows nothing, and is left out.
        func shows(_ view: NSView) -> Bool {
            var alpha: CGFloat = 1
            var current: NSView? = view
            while let next = current {
                alpha *= next.alphaValue * CGFloat(next.layer?.opacity ?? 1)
                current = next.superview
            }
            return alpha > 0.01
        }
        let shown = webViews(in: view).filter { webView in
            !webView.isHiddenOrHasHiddenAncestor && !webView.visibleRect.isEmpty && shows(webView)
                && (webView as? ConversationHTMLNativeWebView)?.isCovered != true
        }
        var pieces: [(image: NSImage, frame: NSRect, whole: NSRect, framed: Bool)] = []
        // A web view whose picture never came is said beside the still,
        // never passed off as an empty frame.
        var missing: [String] = []
        let group = DispatchGroup()
        for webView in shown {
            // The whole page, drawn where it sits and cut to what shows.
            let frame = view.convert(webView.visibleRect, from: webView)
            let whole = view.convert(webView.bounds, from: webView)
            // A visual reply sits at the bottom of its rounded, stroked frame.
            let framed = webView is ConversationHTMLNativeWebView
            group.enter()
            func take(_ attempt: Int) {
                webView.takeSnapshot(with: nil) { image, error in
                    if let image {
                        pieces.append((image, frame, whole, framed))
                        group.leave()
                    } else if attempt < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { take(attempt + 1) }
                    } else {
                        missing.append("web view at \(Int(whole.minX)),\(Int(whole.minY)) \(Int(whole.width))x\(Int(whole.height)): "
                            + "no picture after \(attempt + 1) tries (\(error?.localizedDescription ?? "no error"))")
                        group.leave()
                    }
                }
            }
            take(0)
        }
        group.notify(queue: .main) {
            let note = path.appendingPathExtension("missing-web.txt")
            if missing.isEmpty { try? FileManager.default.removeItem(at: note) }
            else { try? (missing.joined(separator: "\n") + "\n").write(to: note, atomically: true, encoding: .utf8) }
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                func unflipped(_ rect: NSRect) -> NSRect {
                    view.isFlipped ? NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
                }
                // What the window drew over the pages (their floating controls, while
                // they show) is drawn again over the pages' pictures.
                let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                // Web content sits in a transcript, under that transcript's faded edges.
                for piece in pieces {
                    let cg = context.cgContext
                    cg.beginTransparencyLayer(auxiliaryInfo: nil)
                    NSGraphicsContext.saveGraphicsState()
                    if piece.framed {
                        // Only what the frame shows: inside its stroke on every
                        // side, with its rounded corners.
                        let whole = unflipped(piece.whole).insetBy(dx: 1, dy: 1)
                        let radius = ConversationMetrics.blockRadius - 1
                        NSBezierPath(roundedRect: whole, xRadius: radius, yRadius: radius).addClip()
                    }
                    NSBezierPath(rect: unflipped(piece.frame)).addClip()
                    piece.image.draw(in: unflipped(piece.whole))
                    NSGraphicsContext.restoreGraphicsState()
                    if let edges = ConversationEdgeSnapshot.containing(piece.frame) {
                        fade(cg, to: edges, height: view.bounds.height, width: view.bounds.width)
                    }
                    cg.endTransparencyLayer()
                }
                // Then what floats opaque over the transcript (notices, the jump
                // button): web content scrolls behind it, never over it.
                if let window {
                    for rect in ConversationHTMLControlsSnapshot.shown + covers where !pieces.isEmpty {
                        let target = unflipped(rect)
                        let source = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                            width: rect.width * scale, height: rect.height * scale).integral
                        if let piece = window.cropping(to: source) {
                            context.cgContext.draw(piece, in: target.integral)
                        }
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            var output = bitmap
            if let clean, let drawn = bitmap.cgImage,
               let glassed = glassed(drawn, clean: clean, cleanOrigin: glassArea.origin, surfaces: glass, scale: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                     dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) {
                output = NSBitmapImageRep(cgImage: glassed)
            }
            if chatOnly, let panel = scrollViews(in: view).max(by: { $0.visibleRect.height < $1.visibleRect.height }),
               let image = output.cgImage {
                let frame = view.convert(panel.bounds, from: panel)
                let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let crop = CGRect(x: frame.minX * scale, y: 0, width: frame.width * scale, height: CGFloat(bitmap.pixelsHigh))
                if let cropped = image.cropping(to: crop.integral) { output = NSBitmapImageRep(cgImage: cropped) }
            }
            try? output.representation(using: .png, properties: [:])?.write(to: path, options: .atomic)
        }
    }

    private static let glassContext = CIContext()

    /// Glass as the window shows it, near enough: inside each surface (window
    /// coordinates from the top), what lies behind blurred, under the surface's
    /// own content drawn mostly opaque over the panel's colour, and the
    /// material's tint: a little darker than the panel in light, lighter in dark.
    private static func glassed(_ drawn: CGImage, clean: CGImage, cleanOrigin: CGPoint, surfaces: [CGRect], scale: CGFloat,
                                dark: Bool) -> CGImage? {
        let width = drawn.width, height = drawn.height
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        cg.draw(drawn, in: whole)
        let context = glassContext
        let blur = 4 * scale
        for surface in surfaces {
            // Pixels from the top for cropping; from the bottom for drawing.
            let source = CGRect(x: surface.minX * scale, y: surface.minY * scale,
                                width: surface.width * scale, height: surface.height * scale).integral
            let target = CGRect(x: source.minX, y: CGFloat(height) - source.maxY, width: source.width, height: source.height)
            let margin = source.insetBy(dx: -3 * blur, dy: -3 * blur).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let inClean = source.offsetBy(dx: -cleanOrigin.x * scale, dy: -cleanOrigin.y * scale).integral
            guard let behind = drawn.cropping(to: margin), let surfaceOnly = clean.cropping(to: inClean) else { continue }
            let input = CIImage(cgImage: behind).clampedToExtent()
            guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: blur]),
                  let output = filter.outputImage,
                  let blurred = context.createCGImage(output, from: CGRect(x: 0, y: 0, width: behind.width, height: behind.height))
            else { continue }
            cg.saveGState()
            let radius = WovenMetrics.composerRadius * scale
            cg.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.clip()
            cg.draw(blurred, in: CGRect(x: margin.minX, y: CGFloat(height) - margin.maxY, width: margin.width, height: margin.height))
            cg.setAlpha(0.62)
            cg.draw(surfaceOnly, in: target)
            cg.setAlpha(1)
            cg.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.12 : 0.06))
            cg.fill(target)
            // The surface's own text and controls at full strength over that.
            cg.setBlendMode(dark ? .lighten : .darken)
            cg.draw(surfaceOnly, in: target)
            cg.restoreGState()
        }
        return cg.makeImage()
    }

    /// Keeps only what a transcript's mask shows of what was just drawn:
    /// nothing outside the transcript, faded across its top edge.
    private static func fade(_ cg: CGContext, to edges: ConversationEdgeSnapshot, height: CGFloat, width: CGFloat) {
        let frame = edges.frame
        let stops: [(y: CGFloat, alpha: CGFloat)] = [(frame.minY, 0), (frame.minY + edges.topFade, 1), (frame.maxY, 1)]
        // Window coordinates run down from the top; the bitmap's run up.
        cg.saveGState()
        cg.setBlendMode(.destinationIn)
        for (index, stop) in stops.enumerated().dropLast() {
            let next = stops[index + 1]
            let top = height - next.y, bottom = height - stop.y
            let band = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, bottom - top))
            guard band.height > 0 else { continue }
            if stop.alpha == next.alpha {
                cg.setFillColor(CGColor(gray: 0, alpha: stop.alpha))
                cg.fill(band)
            } else if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                                colors: [CGColor(gray: 0, alpha: stop.alpha), CGColor(gray: 0, alpha: next.alpha)] as CFArray,
                                                locations: [0, 1]) {
                cg.saveGState()
                cg.clip(to: band)
                cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bottom), end: CGPoint(x: 0, y: top), options: [])
                cg.restoreGState()
            }
        }
        // Outside the transcript: nothing.
        cg.setFillColor(CGColor(gray: 0, alpha: 0))
        cg.fill(CGRect(x: 0, y: height - frame.minY, width: width, height: frame.minY))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: max(0, height - frame.maxY)))
        cg.fill(CGRect(x: 0, y: 0, width: max(0, frame.minX), height: height))
        cg.fill(CGRect(x: frame.maxX, y: 0, width: max(0, width - frame.maxX), height: height))
        cg.restoreGState()
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
