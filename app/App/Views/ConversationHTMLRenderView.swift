import SwiftUI
import WovenProtocol
import WebKit
import AppKit

/// Published visual replies are independent of the work disclosure and load
/// their content only when their row is mounted, by digest through this Mac's
/// server, which fetches it from another machine when it is not here. Theme
/// and zoom updates preserve their state.
struct ConversationHTMLRenderView: View {
    let reference: ConversationHTMLRenderReference
    @Environment(\.workspaceApplicationModel) private var model
    @Environment(\.wovenTheme) private var theme
    @State private var reply: ConversationVisualReply?
    @State private var failure: String?
    @State private var height: CGFloat
    @State private var expanded = false
    @State private var zoom = 1.0
    @State private var pendingLink: URL?
    @State private var hovering = false
    /// The page's leading heading or caption, as it reports it.
    @State private var pageLead = ""
    /// The page has reported its first measured height: until then the frame
    /// shows the loading label at the reserved height, never a blank page.
    @State private var measured = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case zoomOut, resetZoom, zoomIn, expand }

    private var title: String { reference.title.isEmpty ? "Visual reply" : reference.title }

    /// The page starts with the frame's own title, so the frame does not
    /// repeat it: the title row goes and its controls float over the page's
    /// top corner. It is known when the page first reports, which is when the
    /// page is revealed, so nothing changes height after that.
    private var titleRepeated: Bool {
        let own = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !own.isEmpty && reply != nil && measured
            && pageLead.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(own) == .orderedSame
    }

    init(reference: ConversationHTMLRenderReference) {
        self.reference = reference
        _height = State(initialValue: CGFloat(min(2000, max(80, reference.height))))
    }

    var body: some View {
        // One frame for loading, loaded and failed, with the title inside it.
        VStack(alignment: .leading, spacing: 0) {
            if !titleRepeated {
                HStack(spacing: ConversationMetrics.entryGap) {
                    Text(title).lineLimit(1)
                    Spacer()
                    frameControls
                }
                .modifier(TitleRowStyle())
            }
            if let reply {
                // The page lays out and measures hidden; it shows, at the height
                // it reported, in the same update as its first report.
                ZStack {
                    web(reply).opacity(measured ? 1 : 0)
                    if !measured { loadingLabel }
                }
                .frame(height: min(20_000, max(80, measured ? height * zoom : height)))
            } else if let failure {
                VStack(spacing: ConversationMetrics.rowGap) {
                    Text(failure).font(.system(size: 13)).foregroundStyle(WovenPalette.mutedForeground)
                        .multilineTextAlignment(.center)
                    ConversationTextButton("Retry") { self.failure = nil; Task { await load() } }
                }
                .padding(.horizontal, ConversationMetrics.entryGap)
                .frame(maxWidth: .infinity, minHeight: height)
            } else {
                loadingLabel.frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if titleRepeated {
                frameControls.modifier(TitleRowStyle())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ConversationMetrics.blockRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConversationMetrics.blockRadius, style: .continuous)
                .strokeBorder(WovenPalette.foreground.opacity(0.09), lineWidth: 1)
        }
        // The width it asked for, when narrower than the column; the hairline is
        // drawn over its edge, so its content lays out at exactly that width.
        .frame(maxWidth: reference.width.map { min(ConversationMetrics.column, CGFloat($0)) } ?? ConversationMetrics.column)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .task(id: reference.digest) { await load() }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    controls
                    Button("Done") { expanded = false }.keyboardShortcut(.cancelAction)
                }.padding(16)
                Divider()
                if let reply { web(reply, fitsHeight: false) }
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

    private var loadingLabel: some View {
        Text("Loading visual reply…")
            .font(.system(size: 13))
            .foregroundStyle(WovenPalette.mutedForeground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Zoom and expand: shown on hover, while zoomed or while one has focus.
    /// Nearly invisible rather than hidden, so VoiceOver and the keyboard still
    /// reach them and nothing shifts.
    private var frameControls: some View {
        HStack(spacing: ConversationMetrics.entryGap) {
            controls
            Button { expanded = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .focused($focusedControl, equals: .expand)
            .help("Expand visual reply")
            .accessibilityLabel("Expand visual reply")
            .disabled(reply == nil)
        }
        .opacity(hovering || zoom != 1 || focusedControl != nil ? 1 : 0.001)
    }

    private struct TitleRowStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(WovenPalette.mutedForeground)
                .buttonStyle(.plain)
                .padding(.horizontal, ConversationMetrics.entryGap)
                .frame(height: 32)
        }
    }

    private var expandedMinimumWidth: CGFloat? {
        760
    }

    private var controls: some View {
        HStack(spacing: ConversationMetrics.rowGap) {
            Button { zoom = max(0.5, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .focused($focusedControl, equals: .zoomOut)
                .disabled(zoom <= 0.5).accessibilityLabel("Zoom out")
            Button { zoom = 1 } label: { Text(zoom, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                .focused($focusedControl, equals: .resetZoom)
                .help("Reset zoom").accessibilityLabel("Reset zoom")
            Button { zoom = min(2, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .focused($focusedControl, equals: .zoomIn)
                .disabled(zoom >= 2).accessibilityLabel("Zoom in")
        }.buttonStyle(.plain)
    }

    private func web(_ reply: ConversationVisualReply, fitsHeight: Bool = true) -> some View {
        ConversationHTMLWebView(html: reply.html, theme: ConversationHTMLTheme.value(theme), zoom: zoom,
            forwardsConversationScroll: fitsHeight, startsFrame: fitsHeight && titleRepeated,
            onHeight: { value in
                guard fitsHeight, value.isFinite else { return }
                height = min(20_000, max(80, ceil(value)))
                if !measured { measured = true }
            }, onLead: { pageLead = $0 }, onLink: { pendingLink = $0 }, onFailure: { error in
                failure = error.localizedDescription; self.reply = nil; measured = false
            })
    }

    @MainActor private func load() async {
        guard reply == nil else { return }
        let unavailable = "This visual reply is unavailable. Reconnect to its workspace and try again."
        guard let server = model?.server else { failure = unavailable; return }
        do {
            var data = Data()
            while true {
                let chunk = try await server.call(FetchContent(digest: reference.digest, offset: Int64(data.count)))
                data.append(chunk.data)
                if Int64(data.count) >= chunk.size || chunk.data.isEmpty { break }
            }
            try Task.checkCancellation()
            reply = ConversationVisualReply(html: String(decoding: data, as: UTF8.self), title: reference.title,
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
    var startsFrame = false
    let onHeight: (CGFloat) -> Void
    let onLead: (String) -> Void
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
        (view as? ConversationHTMLNativeWebView)?.startsFrame = startsFrame
        coordinator.onHeight = onHeight; coordinator.onLead = onLead; coordinator.onLink = onLink; coordinator.onFailure = onFailure
        coordinator.apply(html: html, theme: theme, to: view)
        if view.pageZoom != zoom { view.pageZoom = zoom }
    }
}

@MainActor final class ConversationHTMLWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var html: String?
    private var themeJSON: String?
    var onHeight: (CGFloat) -> Void = { _ in }
    /// The page's leading heading or caption, empty when it starts otherwise.
    var onLead: (String) -> Void = { _ in }
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
        onHeight = { _ in }; onLead = { _ in }; onLink = { _ in }; onReady = {}; onFailure = { _ in }
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
            onLead(String((body["lead"] as? String ?? "").prefix(200)))
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
        onFailure(NSError(domain: "WovenHTML", code: 1, userInfo: [NSLocalizedDescriptionKey: "The visual reply stopped. Retry the preview."]))
    }
}

/// An inline visual reply fits its content, so ordinary vertical scrolling
/// belongs to the conversation. Expanded ones and modified/horizontal chart gestures
/// retain WebKit's normal handling; links, selection and magnification do too.
final class ConversationHTMLNativeWebView: WKWebView {
    var forwardsConversationScroll = false
    /// No title row above it: the page meets the frame's top edge (the debug
    /// still clips it to the frame's rounded top too).
    var startsFrame = false
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
