import AppKit
import SwiftUI
import WovenMatterCore

struct DashboardBrowserPane: View {
    let page: WMBrowserPage
    let revision: Int
    @Environment(\.dashboardTheme) private var theme
    @State private var address = ""
    @State private var findText = ""
    @State private var showsFind = false
    @State private var showsClearData = false
    @State private var addressError: String?
    @State private var menuHovered = false
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                control("Back", symbol: "chevron.left", disabled: !page.canGoBack) { page.goBack() }
                control("Forward", symbol: "chevron.right", disabled: !page.canGoForward) { page.goForward() }
                control(page.loading ? "Stop loading" : "Reload", symbol: page.loading ? "xmark" : "arrow.clockwise") {
                    if page.loading { page.stop() } else { page.reload() }
                }
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .frame(height: DashboardMetrics.assetToolbarControlHeight)
                    .background(theme.palette.workspace)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .focused($addressFocused)
                    .onSubmit(navigate)
                    .accessibilityLabel("Browser address")
                    .help(page.url)
                Menu {
                    Button("Find in Page…") { showsFind = true; findFocused = true }
                    Button("Copy Page URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(page.url, forType: .string)
                    }.disabled(page.url == "about:blank")
                    if !page.passwordUsernames.isEmpty {
                        Menu("Fill Saved Password") {
                            ForEach(page.passwordUsernames, id: \.self) { username in
                                Button(username.isEmpty ? "Saved password" : username) {
                                    page.fillPassword(forUsername: username)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Clear Browser Data…") { showsClearData = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: DashboardMetrics.assetToolbarControlWidth,
                               height: DashboardMetrics.assetToolbarControlHeight)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: DashboardMetrics.assetToolbarControlWidth,
                       height: DashboardMetrics.assetToolbarControlHeight)
                .foregroundStyle(DashboardPalette.mutedForeground)
                .background(menuHovered ? theme.palette.themeWhisper : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { menuHovered = $0 }
                .help("Browser menu")
                .accessibilityLabel("Browser menu")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, DashboardMetrics.assetToolbarVerticalPadding)
            if let title = page.passwordOfferTitle {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(page.passwordOfferOrigin ?? "").font(.system(size: 11))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer(minLength: 8)
                    Button("Not Now") { page.dismissPasswordOffer() }.buttonStyle(SettingsQuietButtonStyle())
                    Button(title.hasPrefix("Update") ? "Update Password" : "Save Password") {
                        page.acceptPasswordOffer()
                    }.buttonStyle(DashboardPrimaryButtonStyle())
                }.padding(10)
            }
            if showsFind {
                HStack(spacing: 6) {
                    TextField("Find in page", text: $findText)
                        .textFieldStyle(.plain).focused($findFocused)
                        .onSubmit { page.find(findText, forward: true, next: true) }
                    control("Previous match", symbol: "chevron.up") { page.find(findText, forward: false, next: true) }
                    control("Next match", symbol: "chevron.down") { page.find(findText, forward: true, next: true) }
                    control("Close find", symbol: "xmark") { showsFind = false; page.stopFinding() }
                }.padding(.horizontal, 14).font(.system(size: 12))
                .onChange(of: findText) { _, text in
                    if text.isEmpty { page.stopFinding() } else { page.find(text, forward: true, next: false) }
                }
            }
            if let error = addressError ?? page.errorMessage {
                HStack {
                    Text(error).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Button("Reload") { page.reload() }
                }
                .foregroundStyle(DashboardPalette.warning)
                .padding(10)
            }
            Rectangle().fill(theme.palette.border).frame(height: 1)
            ZStack {
                DashboardChromiumView(page: page)
                // Opener-written popup content can keep an about:blank URL.
                if !page.popup && page.url == "about:blank" && !page.loading {
                    VStack(spacing: 9) {
                        Image(systemName: "globe").font(.system(size: 30, weight: .light))
                        Text("Browse alongside your work").font(.system(size: 15, weight: .medium))
                        Text("Enter an address or search above.").font(.system(size: 12))
                    }
                    .foregroundStyle(DashboardPalette.foreground.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.palette.workspace)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(theme.palette.workspace)
        .onAppear { updateAddress(); if !page.popup && page.url == "about:blank" { addressFocused = true } }
        .onChange(of: revision) { _, _ in if !addressFocused { updateAddress() } }
        .onChange(of: addressFocused) { _, focused in if !focused { updateAddress() } }
        .background {
            Group {
                Button("") { addressFocused = true }.keyboardShortcut("l", modifiers: .command)
                Button("") { page.reload() }.keyboardShortcut("r", modifiers: .command)
                Button("") { showsFind = true; findFocused = true }.keyboardShortcut("f", modifiers: .command)
            }.hidden().accessibilityHidden(true)
        }
        .alert("Clear browser data?", isPresented: $showsClearData) {
            Button("Clear on Next Launch", role: .destructive) {
                UserDefaults.standard.set(true, forKey: WorkspaceAssetSession.clearDataKey)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved web sessions, cookies, and site storage will be cleared the next time you open the browser after restarting Woven Matter. This signs you out of websites. Saved passwords are kept in Keychain.")
        }
    }

    private func updateAddress() { address = page.url == "about:blank" ? "" : page.url }
    private func navigate() {
        guard let url = BrowserAddress.destination(for: address) else {
            addressError = "Enter an HTTP or HTTPS address, or a search."
            return
        }
        addressError = nil
        page.loadURL(url.absoluteString)
        addressFocused = false
    }
    private func control(_ title: String, symbol: String, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: DashboardMetrics.assetToolbarControlWidth,
                       height: DashboardMetrics.assetToolbarControlHeight)
        }
        .buttonStyle(DashboardIconButtonStyle()).disabled(disabled).help(title).accessibilityLabel(title)
    }
}

private struct DashboardChromiumView: NSViewRepresentable {
    let page: WMBrowserPage
    func makeNSView(context: Context) -> NSView { page.view }
    func updateNSView(_ view: NSView, context: Context) {}
    // Deliberately no close in dismantleNSView: tab ownership outlives this view.
}
