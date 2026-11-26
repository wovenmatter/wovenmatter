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
    /// The reveal backstop for the page now loaded; any other load's is cancelled.
    @State private var revealTimer: Task<Void, Never>?
    /// This transcript's own copy of the page (two panels can show one chat).
    @Environment(\.conversationCopyScope) private var copyScope
    /// The page's leading heading or caption, as it reports it.
    @State private var pageLead = ""
    /// The page has reported its first measured height: until then the frame
    /// shows the loading label at the reserved height, never a blank page.
    @State private var measured = false
    /// The caption above the frame, decided once, when the page is first
    /// revealed, and kept through a failure and its retry.
    @State private var caption: String?
    @State private var captionDecided = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case zoomOut, resetZoom, zoomIn, expand }

    private var title: String { reference.title.isEmpty ? "Visual reply" : reference.title }

    /// The reply's title as a caption above the frame, unless the page starts
    /// with it itself, or there is none: decided from what the inline page had
    /// reported when it was revealed, and never changed afterwards.
    private func decideCaption() -> String? {
        let own = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty else { return nil }
        return pageLead.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(own) == .orderedSame ? nil : own
    }

    /// Shows the page: at the height it reported, or the reserved one when it
    /// never reports; the caption is settled in the same update.
    private func reveal() {
        guard !measured else { return }
        if !captionDecided { caption = decideCaption(); captionDecided = true }
        measured = true
    }

    init(reference: ConversationHTMLRenderReference) {
        self.reference = reference
        _height = State(initialValue: CGFloat(min(2000, max(80, reference.height))))
    }

    var body: some View {
        // The frame holds the page and nothing else, loading, loaded or failed;
        // the title, when the page does not start with it, is a caption above.
        VStack(alignment: .leading, spacing: ConversationMetrics.labelGap) {
            if captionDecided, let caption {
                Text(caption)
                    // The visual's title.
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WovenPalette.foreground.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            frame
        }
        // The width it asked for, when narrower than the column; the hairline is
        // drawn over its edge, so its content lays out at exactly that width.
        .frame(maxWidth: reference.width.map { min(ConversationMetrics.column, CGFloat($0)) } ?? ConversationMetrics.column)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reference.digest) { await load() }
        .onDisappear { revealTimer?.cancel() }
        // `visual:expand`, `visual:close`, `visual:zoom:N` and `visual:fail` act on
        // every mounted visual reply, as its controls would (debug builds only).
        .debugCommand("visual:") { action in
            switch action {
            case "expand": expanded = true
            case "close": expanded = false
            case "fail": revealTimer?.cancel(); failure = "The visual reply stopped. Retry the preview."; reply = nil; measured = false
            default:
                if action.hasPrefix("zoom:"), let value = Double(action.dropFirst(5)) { zoom = min(2, max(0.5, value)) }
            }
        }
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

    private var frame: some View {
        Group {
            if let reply {
                // The page lays out, measures and paints under the loading label;
                // it shows, at the height it reported, in the same update as its
                // first report. (Hidden instead, WebKit may not paint it in time.)
                ZStack {
                    web(reply)
                    if !measured { loadingLabel.background(theme.palette.workspace) }
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
        .clipShape(RoundedRectangle(cornerRadius: ConversationMetrics.blockRadius, style: .continuous))
        .overlay {
            // A step stronger in Dark, where the hairline otherwise all but vanishes.
            RoundedRectangle(cornerRadius: ConversationMetrics.blockRadius, style: .continuous)
                .strokeBorder(WovenPalette.foreground.opacity(theme == .dark ? 0.14 : 0.09), lineWidth: 1)
        }
        // Zoom and expand float in the frame's top corner, over the page.
        .overlay(alignment: .topTrailing) {
            frameControls.padding(ConversationMetrics.rowGap)
        }
        .onHover { hovering = $0 }
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
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(WovenPalette.mutedForeground)
        .buttonStyle(.plain)
        .padding(.horizontal, ConversationMetrics.rowGap)
        .frame(height: 24)
        .background(theme.palette.workspace, in: Capsule())
        .overlay { Capsule().strokeBorder(WovenPalette.foreground.opacity(0.09), lineWidth: 1) }
        .opacity(controlsShowing ? 1 : 0.001)
        .background {
            #if DEBUG
            // Debug stills draw the controls over the page's picture while they show.
            Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                ConversationHTMLControlsSnapshot.frames[reference.digest] = rect
            }
            .onChange(of: controlsShowing, initial: true) { _, showing in
                if showing { ConversationHTMLControlsSnapshot.showing.insert(reference.digest) }
                else { ConversationHTMLControlsSnapshot.showing.remove(reference.digest) }
            }
            .onDisappear {
                ConversationHTMLControlsSnapshot.showing.remove(reference.digest)
                ConversationHTMLControlsSnapshot.frames[reference.digest] = nil
            }
            #endif
        }
    }

    private var controlsShowing: Bool { hovering || zoom != 1 || focusedControl != nil }

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
        // Only the inline page sizes the frame and says how it starts; the
        // expanded sheet's page lays out at its own width and writes neither.
        ConversationHTMLWebView(html: reply.html, theme: ConversationHTMLTheme.value(theme), zoom: zoom,
            forwardsConversationScroll: fitsHeight,
            textKey: fitsHeight ? ConversationVisualReplyText.key(scope: copyScope, item: reference.id) : nil,
            covered: fitsHeight && !measured,
            onHeight: { value in
                guard fitsHeight, value.isFinite else { return }
                height = min(20_000, max(80, ceil(value)))
                reveal()
            }, onLead: { lead in
                if fitsHeight { pageLead = lead }
            }, onLoaded: {
                // A page that loads but never reports shows at the reserved
                // height after a second, rather than loading forever.
                guard fitsHeight else { return }
                revealTimer?.cancel()
                revealTimer = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled, self.reply != nil { reveal() }
                }
            }, onLink: { pendingLink = $0 }, onFailure: { error in
                if fitsHeight { revealTimer?.cancel() }
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

extension EnvironmentValues {
    /// Which transcript a view belongs to, so Copy reads the visual reply
    /// mounted in its own transcript, never another panel's copy of it.
    @Entry var conversationCopyScope: UUID?
    /// Text Copy puts before a response's own (an answer's visual replies);
    /// nil from it copies the response alone.
    @Entry var conversationCopyLead: (@MainActor @Sendable () async -> String?)?
}

/// Reads an inline visual reply's text while its page is mounted.
@MainActor enum ConversationVisualReplyText {
    /// A mounted inline page's key: its transcript and its item.
    static func key(scope: UUID?, item: String) -> String { "\(scope?.uuidString ?? "-")/\(item)" }

    /// The mounted inline pages, each with the coordinator that registered it.
    static var readers: [String: (owner: ObjectIdentifier, read: @MainActor () async -> String?)] = [:]

    static func text(of key: String) async -> String? {
        await readers[key]?.read()
    }

    /// Several pages' text in order, a blank line apart, read together under
    /// one deadline (each read's own second, all started at once); a page that
    /// does not answer is left out; nil when none answers.
    static func text(of keys: [String]) async -> String? {
        let reads = keys.compactMap { readers[$0]?.read }.map { read in Task { @MainActor in await read() } }
        var parts: [String] = []
        for read in reads { if let text = await read.value { parts.append(text) } }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The newest Copy press anywhere; only it may write the pasteboard.
    private static var latestPress = 0

    /// Starts a Copy press; pass what it returns to `isLatest` before writing.
    static func press() -> Int {
        latestPress += 1
        return latestPress
    }

    static func isLatest(_ press: Int) -> Bool { press == latestPress }

    /// What the page answered, tidied: trailing spaces off, at most one blank line in a row.
    static func tidy(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.components(separatedBy: "\n").map { line in
            String(line.reversed().drop(while: { $0.isWhitespace }).reversed())
        }
        let result = lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

#if DEBUG
/// Where each visual reply's floating controls are, and whether they show, so
/// a debug still draws them over the page's picture as the window does.
@MainActor enum ConversationHTMLControlsSnapshot {
    static var frames: [String: CGRect] = [:]
    static var showing: Set<String> = []
    static var shown: [CGRect] { showing.compactMap { frames[$0] } }
}
#endif

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
    /// The inline page's key for reading its text (a visual-only answer's Copy).
    var textKey: String?
    /// The loading label covers the page.
    var covered = false
    let onHeight: (CGFloat) -> Void
    let onLead: (String) -> Void
    var onLoaded: () -> Void = {}
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
        coordinator.onHeight = onHeight; coordinator.onLead = onLead; coordinator.onLink = onLink; coordinator.onFailure = onFailure
        coordinator.onLoaded = onLoaded
        (view as? ConversationHTMLNativeWebView)?.isCovered = covered
        coordinator.register(textKey: textKey, view: view)
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
    var onLoaded: () -> Void = {}
    var onFailure: (any Error) -> Void = { _ in }
    var consoleMessages: [[String: String]] = []
    private var consoleBytes = 0
    /// The inline page's key, while this page answers Copy for it.
    private var textKey: String?
    /// Reads waiting for the page's text, by request.
    private var textWaiters: [Int: CheckedContinuation<String?, Never>] = [:]
    private var nextTextRequest = 0

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
            answerAllText()
            view.loadHTMLString(ConversationHTMLDocument.render(html: html), baseURL: nil)
        } else if changed { updateTheme(view) }
    }

    func register(textKey key: String?, view: WKWebView) {
        guard key != textKey else { return }
        unregisterText()
        textKey = key
        guard let key else { return }
        ConversationVisualReplyText.readers[key] = (ObjectIdentifier(self), { [weak self, weak view] in
            guard let self, let view else { return nil }
            return await self.readText(view)
        })
    }

    private func unregisterText() {
        if let key = textKey, ConversationVisualReplyText.readers[key]?.owner == ObjectIdentifier(self) {
            ConversationVisualReplyText.readers[key] = nil
        }
        textKey = nil
    }

    /// The page's text as it shows, read inside its frame; nil when it does
    /// not answer within a second. Each read has its own request: only its own
    /// answer or its own timeout ends it.
    func readText(_ view: WKWebView) async -> String? {
        nextTextRequest += 1
        let request = nextTextRequest
        let text = await withCheckedContinuation { (waiter: CheckedContinuation<String?, Never>) in
            textWaiters[request] = waiter
            view.evaluateJavaScript("window.wovenReadText?.(\(request))", completionHandler: nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.answerText(nil, request: request)
            }
        }
        return ConversationVisualReplyText.tidy(text)
    }

    private func answerText(_ text: String?, request: Int) {
        textWaiters.removeValue(forKey: request)?.resume(returning: text)
    }

    /// A new page or none: reads of the old one end with nothing.
    private func answerAllText() {
        let waiting = textWaiters.values
        textWaiters.removeAll()
        waiting.forEach { $0.resume(returning: nil) }
    }

    func stop(_ view: WKWebView) {
        answerAllText(); unregisterText()
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "wovenHTML")
        onHeight = { _ in }; onLead = { _ in }; onLink = { _ in }; onReady = {}; onLoaded = {}; onFailure = { _ in }
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
            // The lead first: the first height reveals the page, and settles its caption from it.
            onLead(String((body["lead"] as? String ?? "").prefix(200)))
            if let value = body["height"] as? Double, value.isFinite { onHeight(CGFloat(min(20_000, max(80, value)))) }
        case "text":
            if let request = (body["id"] as? NSNumber)?.intValue {
                answerText((body["text"] as? String).map { String($0.prefix(200_000)) }, request: request)
            }
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoaded() }
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
    /// The frame's loading label covers the page (debug stills leave it out).
    var isCovered = false

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
