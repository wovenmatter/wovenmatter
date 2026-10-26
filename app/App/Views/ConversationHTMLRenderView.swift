import SwiftUI
import WebKit
#if os(macOS)
import AppKit
import WovenMatterCore
#else
import UIKit
import WovenMatterCompanion
#endif

/// Published pages are independent of the work disclosure and load full detail
/// only when their row is mounted. Theme and zoom updates preserve page state.
struct ConversationHTMLRenderView: View {
    let activity: AgentRunActivity
    let runID: String
    @Environment(\.conversationActivityDetails) private var loadDetails
    @Environment(\.dashboardTheme) private var theme
    @State private var page: ConversationHTMLPage?
    @State private var failure: String?
    @State private var height: CGFloat = 400
    @State private var expanded = false
    @State private var zoom = 1.0
    @State private var pendingLink: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(activity.htmlRender?.title ?? "Visual reply").lineLimit(1)
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
            .foregroundStyle(DashboardPalette.mutedForeground)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            if let page {
                web(page).frame(height: min(20_000, max(80, height * zoom)))
            } else if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(DashboardPalette.mutedForeground)
                    .padding(.vertical, 16)
                Button("Retry") { self.failure = nil; Task { await load() } }.buttonStyle(.plain)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: CGFloat(min(2000, max(80, activity.htmlRender?.height ?? 160))))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: activity.detailVersion) { await load() }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                HStack {
                    Text(activity.htmlRender?.title ?? "Visual reply").font(.headline)
                    Spacer()
                    controls
                    Button("Done") { expanded = false }.keyboardShortcut(.cancelAction)
                }.padding(16)
                Divider()
                if let page { web(page, fitsHeight: false) }
            }
            .frame(minWidth: expandedMinimumWidth, minHeight: 440)
            .environment(\.dashboardTheme, theme)
        }
        .alert("Open external link?", isPresented: Binding(
            get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }
        ), presenting: pendingLink) { url in
            Button("Cancel", role: .cancel) { pendingLink = nil }
            Button("Open") {
                pendingLink = nil
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
        } message: { Text($0.absoluteString) }
    }

    private var expandedMinimumWidth: CGFloat? {
        #if os(macOS)
        760
        #else
        nil
        #endif
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
            onHeight: { value in
                guard fitsHeight, value.isFinite else { return }
                height = min(20_000, max(80, ceil(value)))
            }, onLink: { pendingLink = $0 }, onFailure: { error in
                failure = error.localizedDescription; self.page = nil
            })
    }

    @MainActor private func load() async {
        guard page == nil else { return }
        do {
            let full = activity.rawOutputJSON != nil ? activity : try await loadDetails?(runID, activity.id)
            try Task.checkCancellation()
            guard let data = full?.rawOutputJSON?.data(using: .utf8) else {
                failure = "This page is unavailable. Reconnect to its workspace and try again."; return
            }
            let saved = try JSONDecoder().decode(ConversationHTMLPage.self, from: data)
            page = try ConversationHTMLPage(html: saved.html, title: saved.title, height: saved.height)
            height = CGFloat(saved.height)
            failure = nil
        } catch is CancellationError {} catch { failure = error.localizedDescription }
    }
}

enum ConversationHTMLTheme {
    static func value(_ theme: DashboardTheme) -> [String: Any] {
        let dark = theme == .dark
        let foreground = dark ? String(format: "#%06x", DashboardColors.darkForeground) : "#0a1f16"
        let muted = dark ? String(format: "#%06x", DashboardColors.darkMutedForeground) : "#5c6f64"
        let accent = hex(theme.palette.themeAccent)
        let success = dark ? String(format: "#%06x", DashboardColors.darkGreen) : "#0d8f5a"
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
        #if os(macOS)
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255), Int(rgb.alphaComponent * 255))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
        #endif
    }
}

#if os(macOS)
private typealias ConversationHTMLRepresentable = NSViewRepresentable
#else
private typealias ConversationHTMLRepresentable = UIViewRepresentable
#endif

private struct ConversationHTMLWebView: ConversationHTMLRepresentable {
    let html: String
    let theme: [String: Any]
    let zoom: Double
    let onHeight: (CGFloat) -> Void
    let onLink: (URL) -> Void
    let onFailure: (any Error) -> Void

    func makeCoordinator() -> ConversationHTMLWebCoordinator { ConversationHTMLWebCoordinator() }
    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: ConversationHTMLWebCoordinator) { coordinator.stop(view) }
    #else
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: ConversationHTMLWebCoordinator) { coordinator.stop(view) }
    #endif

    private func update(_ view: WKWebView, coordinator: ConversationHTMLWebCoordinator) {
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

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: "wovenHTML")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.showsVerticalScrollIndicator = false; view.scrollView.showsHorizontalScrollIndicator = false
        #endif
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
