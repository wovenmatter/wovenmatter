import SwiftUI
import WovenProtocol
import WebKit
import AppKit

/// Published pages are independent of the work disclosure and load their
/// content only when their row is mounted, by digest through this Mac's
/// server, which fetches it from another machine when it is not here. Theme
/// and zoom updates preserve page state.
struct ConversationHTMLRenderView: View {
    let reference: ConversationHTMLRenderReference
    @Environment(\.workspaceApplicationModel) private var model
    @Environment(\.wovenTheme) private var theme
    @State private var page: ConversationHTMLPage?
    @State private var failure: String?
    @State private var height: CGFloat
    @State private var expanded = false
    @State private var zoom = 1.0
    @State private var pendingLink: URL?

    init(reference: ConversationHTMLRenderReference) {
        self.reference = reference
        _height = State(initialValue: CGFloat(min(2000, max(80, reference.height))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(reference.title).lineLimit(1)
                Spacer()
                controls
                Button { expanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Expand visual reply")
                .accessibilityLabel("Expand visual reply")
                .disabled(page == nil)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(WovenPalette.mutedForeground)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            if let page {
                web(page).frame(height: min(20_000, max(80, height * zoom)))
            } else if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(WovenPalette.mutedForeground)
                    .padding(.vertical, 16)
                Button("Retry") { self.failure = nil; Task { await load() } }.buttonStyle(.plain)
            } else {
                Text("Loading visual reply…")
                    .font(.system(size: 13))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reference.digest) { await load() }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                HStack {
                    Text(reference.title).font(.headline)
                    Spacer()
                    controls
                    Button("Done") { expanded = false }.keyboardShortcut(.cancelAction)
                }.padding(16)
                Divider()
                if let page { web(page, fitsHeight: false) }
            }
            .frame(minWidth: expandedMinimumWidth, minHeight: 440)
            .environment(\.wovenTheme, theme)
        }
        .alert("Open external link?", isPresented: Binding(
            get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }
        ), presenting: pendingLink) { url in
            Button("Cancel", role: .cancel) { pendingLink = nil }
            Button("Open") {
                pendingLink = nil
                NSWorkspace.shared.open(url)
            }
        } message: { Text($0.absoluteString) }
    }

    private var expandedMinimumWidth: CGFloat? {
        760
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { zoom = max(0.5, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom <= 0.5).accessibilityLabel("Zoom out")
            Button { zoom = 1 } label: { Text(zoom, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                .help("Reset zoom").accessibilityLabel("Reset zoom")
            Button { zoom = min(2, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(zoom >= 2).accessibilityLabel("Zoom in")
        }.buttonStyle(.plain)
    }

    private func web(_ page: ConversationHTMLPage, fitsHeight: Bool = true) -> some View {
        ConversationHTMLWebView(html: page.html, theme: ConversationHTMLTheme.value(theme), zoom: zoom,
            forwardsConversationScroll: fitsHeight,
            onHeight: { value in
                guard fitsHeight, value.isFinite else { return }
                height = min(20_000, max(80, ceil(value)))
            }, onLink: { pendingLink = $0 }, onFailure: { error in
                failure = error.localizedDescription; self.page = nil
            })
    }

    @MainActor private func load() async {
        guard page == nil else { return }
        let unavailable = "This page is unavailable. Reconnect to its workspace and try again."
        guard let server = model?.server else { failure = unavailable; return }
        do {
            var data = Data()
            while true {
                let chunk = try await server.call(FetchContent(digest: reference.digest, offset: Int64(data.count)))
                data.append(chunk.data)
                if Int64(data.count) >= chunk.size || chunk.data.isEmpty { break }
            }
            try Task.checkCancellation()
            page = ConversationHTMLPage(html: String(decoding: data, as: UTF8.self), title: reference.title,
                                        height: reference.height)
            failure = nil
        } catch is CancellationError {
        } catch let error as ProtocolError where error.code == .notFound {
            failure = unavailable
        } catch { failure = error.localizedDescription }
    }
}

enum ConversationHTMLTheme {
    static func value(_ theme: WovenTheme) -> [String: Any] {
        let dark = theme == .dark
        let foreground = dark ? String(format: "#%06x", WovenColors.darkForeground) : "#0a1f16"
        let muted = dark ? String(format: "#%06x", WovenColors.darkMutedForeground) : "#5c6f64"
        let accent = hex(theme.palette.themeAccent)
        let success = dark ? String(format: "#%06x", WovenColors.darkGreen) : "#0d8f5a"
        let danger = dark ? "#ff8383" : "#ef4444"
        let warning = dark ? "#f5b84d" : "#f59e0b"
        let info = dark ? "#91a7ef" : "#4169e1"
        return ["appearance": dark ? "dark" : "light", "variables": [
            "--background": hex(theme.palette.workspace), "--foreground": foreground,
            "--primary": accent, "--primary-foreground": dark ? "#1b1d1a" : "#ffffff", "--accent": accent,
            "--accent-foreground": foreground, "--accent-surface": hex(theme.palette.themeSoft),
            "--accent-surface-foreground": foreground,
            "--muted": hex(theme.palette.themeSoft), "--muted-foreground": muted,
            "--secondary": hex(theme.palette.themeSoft), "--secondary-foreground": foreground,
            "--card": hex(theme.palette.workspace), "--card-foreground": foreground,
            "--popover": hex(theme.palette.workspace), "--popover-foreground": foreground,
            "--border": hex(theme.palette.border), "--input": hex(theme.palette.input), "--ring": accent,
            "--code-background": hex(theme.palette.themeSoft), "--code-foreground": foreground,
            "--success": success, "--success-foreground": success,
            "--destructive": danger, "--destructive-foreground": danger, "--destructive-surface": danger + "19",
            "--warning": warning, "--warning-foreground": warning, "--warning-surface": warning + "19",
            "--info": info, "--info-foreground": info,
            "--chart-1": accent, "--chart-2": "#3573c9", "--chart-3": "#9a5a2a",
            "--chart-4": "#8c62bd", "--chart-5": "#0d8f5a", "--chart-6": "#d79336",
            "--radius": "12px", "--font-sans": "-apple-system,system-ui,sans-serif",
            "--font-mono": "'SF Mono',Menlo,monospace"
        ]]
    }
    private static func hex(_ color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255), Int(rgb.alphaComponent * 255))
    }
}

private typealias ConversationHTMLRepresentable = NSViewRepresentable

private struct ConversationHTMLWebView: ConversationHTMLRepresentable {
    let html: String
    let theme: [String: Any]
    let zoom: Double
    let forwardsConversationScroll: Bool
    let onHeight: (CGFloat) -> Void
    let onLink: (URL) -> Void
    let onFailure: (any Error) -> Void

    func makeCoordinator() -> ConversationHTMLWebCoordinator { ConversationHTMLWebCoordinator() }
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(forwardsConversationScroll: forwardsConversationScroll)
    }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: ConversationHTMLWebCoordinator) { coordinator.stop(view) }

    private func update(_ view: WKWebView, coordinator: ConversationHTMLWebCoordinator) {
        (view as? ConversationHTMLNativeWebView)?.forwardsConversationScroll = forwardsConversationScroll
        coordinator.onHeight = onHeight; coordinator.onLink = onLink; coordinator.onFailure = onFailure
        coordinator.apply(html: html, theme: theme, to: view)
        if view.pageZoom != zoom { view.pageZoom = zoom }
    }
}

@MainActor final class ConversationHTMLWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var html: String?
    private var themeJSON: String?
    var onHeight: (CGFloat) -> Void = { _ in }
    var onLink: (URL) -> Void = { _ in }
    var onReady: () -> Void = {}
    var onFailure: (any Error) -> Void = { _ in }
    var consoleMessages: [[String: String]] = []
    private var consoleBytes = 0

    func makeWebView(forwardsConversationScroll: Bool = false) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: "wovenHTML")
        let view = ConversationHTMLNativeWebView(frame: .zero, configuration: configuration)
        view.forwardsConversationScroll = forwardsConversationScroll
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func apply(html: String, theme: [String: Any], to view: WKWebView) {
        let json = (try? JSONSerialization.data(withJSONObject: theme, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        let changed = themeJSON != json
        themeJSON = json
        if self.html != html {
            self.html = html
            view.loadHTMLString(ConversationHTMLDocument.render(html: html), baseURL: nil)
        } else if changed { updateTheme(view) }
    }

    func stop(_ view: WKWebView) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "wovenHTML")
        onHeight = { _ in }; onLink = { _ in }; onReady = {}; onFailure = { _ in }
        html = nil; themeJSON = nil; consoleMessages.removeAll(); consoleBytes = 0
    }

    private func updateTheme(_ view: WKWebView) {
        guard let themeJSON else { return }
        view.evaluateJavaScript("window.wovenSetTheme?.(\(themeJSON))", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            if let view = message.webView { updateTheme(view) }
            onReady()
        case "size":
            if let value = body["height"] as? Double, value.isFinite { onHeight(CGFloat(min(20_000, max(80, value)))) }
        case "link":
            if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onLink(url) }
        case "console":
            if consoleMessages.count < 100, let text = body["text"] as? String {
                let value = String(text.prefix(2000))
                guard consoleBytes + value.utf8.count <= 32_768 else { return }
                consoleBytes += value.utf8.count
                let level = body["level"] as? String ?? "log"
                consoleMessages.append(["level": ["log", "info", "warn", "warning", "error"].contains(level) ? level : "log", "text": value])
            }
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.targetFrame?.isMainFrame == false,
           ["http", "https"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "") { return .allow }
        guard let url = navigationAction.request.url, navigationAction.navigationType == .other,
              url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" else { return .cancel }
        return .allow
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { onFailure(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { onFailure(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onFailure(NSError(domain: "WovenHTML", code: 1, userInfo: [NSLocalizedDescriptionKey: "The page stopped. Retry the preview."]))
    }
}

/// An inline page fits its content, so ordinary vertical scrolling belongs to
/// the conversation. Expanded pages and modified/horizontal chart gestures
/// retain WebKit's normal handling; links, selection and magnification do too.
final class ConversationHTMLNativeWebView: WKWebView {
    var forwardsConversationScroll = false
    private var scrollGesture = ConversationHTMLScrollGesture()

    override func scrollWheel(with event: NSEvent) {
        let outer = enclosingScrollView
        let deliveries = scrollGesture.deliveries(for: event,
            canForward: forwardsConversationScroll && outer != nil)
        for (event, forward) in deliveries {
            if forward, let outer { outer.scrollWheel(with: event) }
            else { super.scrollWheel(with: event) }
        }
    }
}

/// Pick a destination once per trackpad gesture, including its momentum tail.
/// A zero-delta mayBegin/began cannot identify an axis, so retain those events
/// until the first movement and deliver the complete phase sequence together.
struct ConversationHTMLScrollGesture {
    private var forward: Bool?
    private var waitingForBegan = false
    private var pending: [NSEvent] = []

    mutating func deliveries(for event: NSEvent, canForward: Bool) -> [(NSEvent, Bool)] {
        var result: [(NSEvent, Bool)] = []
        let phase = event.phase
        let momentum = event.momentumPhase
        let discrete = phase.isEmpty && momentum.isEmpty
        let newGesture = phase.contains(.mayBegin) || (phase.contains(.began) && !waitingForBegan)
        if discrete || newGesture {
            // An abandoned directionless gesture belongs to WebKit; it must
            // not lend an unfinished begin phase to the next gesture.
            result += pending.map { ($0, false) }
            pending.removeAll(keepingCapacity: true)
            forward = nil
            waitingForBegan = phase.contains(.mayBegin)
        }
        if phase.contains(.began) { waitingForBegan = false }
        if forward == nil {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if !canForward || !modifiers.isEmpty {
                forward = false
            } else if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                forward = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            } else if discrete || phase.contains(.ended) || phase.contains(.cancelled)
                        || momentum.contains(.ended) || pending.count >= 16 {
                // Bound buffering even for a malformed stream with no motion.
                forward = false
            }
        }
        pending.append(event)
        if let forward {
            result += pending.map { ($0, forward) }
            pending.removeAll(keepingCapacity: true)
        }
        if discrete || phase.contains(.cancelled) || momentum.contains(.ended) {
            forward = nil
            waitingForBegan = false
        }
        // A touch-ended event deliberately keeps the destination: momentum
        // can begin in a later event with no touch phase or nonzero delta.
        return result
    }
}
