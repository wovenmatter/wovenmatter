import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import WovenMatterClient
import WovenMatterCore

/// Pi Bot's own client in a retained web view, so drafts, streams and scroll survive
/// moving between bots, chats and utility screens. The bridge carries navigation,
/// theme and link events only: no RPC, no files, no credentials.
@MainActor
final class BotWebSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    struct Route: Equatable {
        var hash: String
        var target: DashboardBotTarget?
    }

    let webView: WKWebView
    private(set) var loadedBase: URL?
    private(set) var ready = false
    private(set) var lastRoute: String?
    private var pendingHash: String?
    private var pendingTheme: String?
    private var pendingContext: String??
    private var pendingFocus = false
    private var headerInsets: (left: CGFloat, right: CGFloat)?
    private var theme = DashboardTheme.green.rawValue
    var onRoute: ((Route) -> Void)?
    var onOpenExternal: ((URL) -> Void)?
    var onConnectionState: ((String) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakBridge(self), name: "wovenBots")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func show(base: URL, hash: String, theme: String) {
        self.theme = theme
        if loadedBase != base {
            load(base: base, hash: hash)
            return
        }
        setTheme(theme)
        navigate(hash)
    }

    func reload() {
        guard let loadedBase else { return }
        load(base: loadedBase, hash: lastRoute ?? pendingHash ?? "#/")
    }

    func unload() {
        ready = false
        loadedBase = nil
        lastRoute = nil
        pendingHash = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func load(base: URL, hash: String) {
        ready = false
        loadedBase = base
        lastRoute = nil
        pendingHash = nil
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        components.path = "/"
        components.queryItems = [.init(name: "host", value: "woven"), .init(name: "theme", value: theme)]
        components.fragment = hash.hasPrefix("#") ? String(hash.dropFirst()) : hash
        if let url = components.url { webView.load(URLRequest(url: url)) }
    }

    func navigate(_ hash: String) {
        guard ready else { pendingHash = hash; return }
        guard hash != lastRoute else { return }
        call("navigate", argument: hash)
    }

    func setTheme(_ value: String) {
        theme = value
        guard ready else { pendingTheme = value; return }
        call("setTheme", argument: value)
    }

    func setContext(_ context: String?) {
        guard ready else { pendingContext = .some(context); return }
        call("setContext", argument: context)
    }

    func setHeaderInsets(left: CGFloat, right: CGFloat) {
        headerInsets = (left, right)
        guard ready else { return }
        webView.evaluateJavaScript("window.wovenPiBotHost?.setHeaderInsets?.(\(Int(left)),\(Int(right)))", completionHandler: nil)
    }

    func focusComposer() {
        guard ready else { pendingFocus = true; return }
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.wovenPiBotHost?.focusComposer?.()", completionHandler: nil)
    }

    private func call(_ method: String, argument: String?) {
        let encoded = argument.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "null"
        webView.evaluateJavaScript("window.wovenPiBotHost?.\(method)?.(\(encoded))", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, isTrusted(origin: message.frameInfo.securityOrigin),
              let body = message.body as? [String: Any], body["v"] as? Int == 1, let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            ready = true
            if let hash = pendingHash { pendingHash = nil; navigate(hash) }
            if let value = pendingTheme { pendingTheme = nil; setTheme(value) }
            if let context = pendingContext { pendingContext = nil; setContext(context) }
            if pendingFocus { pendingFocus = false; focusComposer() }
            if let headerInsets { setHeaderInsets(left: headerInsets.left, right: headerInsets.right) }
        case "route":
            let hash = body["hash"] as? String ?? ""
            lastRoute = hash
            onRoute?(Route(hash: hash, target: Self.target(from: body)))
        case "openExternal":
            if let raw = body["url"] as? String, let url = URL(string: raw),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onOpenExternal?(url) }
        case "connection":
            if let state = body["state"] as? String { onConnectionState?(state) }
        default: break
        }
    }

    static func target(from body: [String: Any]) -> DashboardBotTarget? {
        guard body["settings"] as? Bool != true, let botID = body["botId"] as? String, !botID.isEmpty else { return nil }
        return DashboardBotTarget(botID: botID, conversationID: body["conversationId"] as? Int,
                                  showsThreadBesideMain: body["threadView"] as? String == "split")
    }

    static func hash(for target: DashboardBotTarget) -> String {
        guard let conversation = target.conversationID else { return "#/\(target.botID)" }
        return "#/\(target.botID)/\(conversation)" + (target.showsThreadBesideMain ? "?view=split" : "")
    }

    private func isTrusted(origin: WKSecurityOrigin) -> Bool {
        guard let loadedBase else { return false }
        return origin.protocol == loadedBase.scheme && origin.host == loadedBase.host && origin.port == loadedBase.port ?? 0
    }

    private func isOwnOrigin(_ url: URL) -> Bool {
        guard let loadedBase else { return false }
        return url.scheme == loadedBase.scheme && url.host == loadedBase.host && url.port == loadedBase.port
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "about" || isOwnOrigin(url) { return .allow }
        if navigationAction.targetFrame?.isMainFrame == true,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onOpenExternal?(url) }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onOpenExternal?(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }

    // Pi Bot asks before deleting; WebKit shows nothing unless the host presents it.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    private final class WeakBridge: NSObject, WKScriptMessageHandler {
        weak var target: BotWebSession?
        init(_ target: BotWebSession) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
        }
    }
}

/// One web view per panel, plus one for Settings, all retained across navigation.
@MainActor
final class BotWebSessionStore {
    private var panels: [DashboardChatPanelID: BotWebSession] = [:]
    let settings = BotWebSession()

    func session(for panelID: DashboardChatPanelID) -> BotWebSession {
        if let existing = panels[panelID] { return existing }
        let created = BotWebSession()
        panels[panelID] = created
        return created
    }

    func release(panelID: DashboardChatPanelID) {
        panels.removeValue(forKey: panelID)?.unload()
    }

    func unloadAll() {
        for session in panels.values { session.unload() }
        settings.unload()
    }
}

struct BotWebView: NSViewRepresentable {
    let session: BotWebSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let view = session.webView
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = container.bounds
        container.addSubview(view)
    }
}

struct BotConversationSurface: View {
    @Bindable var bots: BotsModel
    let panelID: DashboardChatPanelID
    let target: DashboardBotTarget
    let context: String?
    let headerInsets: BotHeaderInsets
    let focusGeneration: Int?
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let onActivate: () -> Void
    let onClosePanel: () -> Void
    let onAddPanel: () -> Void
    let onRoute: (DashboardBotTarget) -> Void
    let onOpenLink: (URL) -> Void
    let onOpenSettings: () -> Void
    @Environment(\.dashboardTheme) private var theme

    private var session: BotWebSession { bots.webSessions.session(for: panelID) }
    private var base: URL? { bots.runtime.phase == .ready ? bots.runtime.baseURL : nil }

    var body: some View {
        ZStack {
            if base != nil {
                BotWebView(session: session)
            } else {
                BotsUnavailableView(runtime: bots.runtime, onOpenSettings: onOpenSettings)
            }
            controls
        }
        .simultaneousGesture(TapGesture().onEnded { onActivate() })
        .task(id: BotSurfaceTask(base: base, target: target, theme: theme.rawValue)) { present() }
        .onChange(of: context) { _, value in session.setContext(value) }
        .onChange(of: headerInsets) { _, value in session.setHeaderInsets(left: value.left, right: value.right) }
        .onChange(of: focusGeneration) { _, value in if value != nil { session.focusComposer() } }
    }

    private func present() {
        let session = self.session
        session.onRoute = { route in
            if let next = route.target, next != target { onRoute(next) }
        }
        session.onOpenExternal = { onOpenLink($0) }
        session.setHeaderInsets(left: headerInsets.left, right: headerInsets.right)
        guard let base else { return }
        session.show(base: base, hash: BotWebSession.hash(for: target), theme: theme.rawValue)
        session.setContext(context)
    }

    /// The same side-of-composer placement regular chats use for panel controls.
    @ViewBuilder private var controls: some View {
        if showsClosePanel || showsAddPanel {
            VStack {
                Spacer()
                HStack {
                    if showsClosePanel {
                        DashboardPanelControlButton(glyph: .close, accessibilityLabel: "Close panel", help: "Close panel", action: onClosePanel)
                    }
                    Spacer()
                    if showsAddPanel {
                        DashboardPanelControlButton(glyph: .panelLeftOpen, accessibilityLabel: "Add panel", help: "Add panel", action: onAddPanel)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, DashboardComposer.verticalPadding)
            }
        }
    }
}

/// Room for native controls floating over Pi Bot's conversation header.
struct BotHeaderInsets: Equatable {
    var left: CGFloat
    var right: CGFloat
}

private struct BotSurfaceTask: Hashable {
    let base: URL?
    let target: DashboardBotTarget
    let theme: String
}

struct BotsUnavailableView: View {
    let runtime: PiBotRuntimeSnapshot
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch runtime.phase {
            case .installing, .starting, .reconnecting:
                ProgressView().controlSize(.small)
            default:
                DashboardLucideIcon(glyph: .bot, size: 20)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button("Open Bot Settings", action: onOpenSettings).buttonStyle(SettingsQuietButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch runtime.phase {
        case .notConfigured: "Choose where your bots run"
        case .installing: "Installing Pi Bot"
        case .starting: "Starting Pi Bot"
        case .reconnecting: "Reconnecting to your bots"
        case .stopped: "Pi Bot is stopped"
        case .failed: "Pi Bot could not start"
        case .ready: "Connecting…"
        }
    }

    private var detail: String? {
        switch runtime.phase {
        case .notConfigured: "Bots run on one device: this Mac, or a Mac or Linux box on your Tailscale network."
        case .failed, .reconnecting: runtime.error ?? runtime.message
        default: runtime.message
        }
    }
}
