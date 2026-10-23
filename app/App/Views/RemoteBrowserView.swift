import SwiftUI
import WovenMatterClient

struct RemoteBrowserView: View {
    let workspaces: RemoteWorkspacesModel
    let configuration: RemoteWorkspaceConfiguration
    @State private var viewer: RemoteBrowserViewerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(workspaces: RemoteWorkspacesModel, configuration: RemoteWorkspaceConfiguration) {
        self.workspaces = workspaces; self.configuration = configuration
        _viewer = State(initialValue: RemoteBrowserViewerModel(
            loadTabs: { try await workspaces.browserTabs(for: configuration) },
            loadFrame: { try await workspaces.browserFrame(tabID: $0, for: configuration) },
            sendAction: { try await workspaces.browserAction($0, for: configuration) }))
    }

    var body: some View {
        RemoteBrowserContent(viewer: viewer, workspaceName: configuration.name, onClose: { dismiss() })
            .task(id: workspaces.browserIdentity(for: configuration)) {
                viewer.clear()
                while !Task.isCancelled {
                    if scenePhase == .active { await viewer.refresh() }
                    do { try await Task.sleep(for: .milliseconds(reduceMotion ? 1000 : 200)) }
                    catch { break }
                }
            }
            .onDisappear { viewer.clear() }
    }
}

struct RemoteBrowserContent: View {
    @Bindable var viewer: RemoteBrowserViewerModel
    let workspaceName: String
    let onClose: () -> Void
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workspace browser").font(.system(size: 14, weight: .semibold))
                    Text(workspaceName).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                Button("Done", action: onClose).buttonStyle(SettingsQuietButtonStyle())
            }
            .padding(16)
            Divider()
            if !viewer.tabs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(viewer.tabs) { tab in
                            Button { viewer.select(tab.id) } label: {
                                Text(tab.title.isEmpty ? "Untitled tab" : tab.title)
                                    .font(.system(size: 12)).lineLimit(1)
                                    .frame(maxWidth: 200).padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(viewer.selectedID == tab.id ? DashboardPalette.foreground.opacity(0.08) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(viewer.selectedID == tab.id ? .isSelected : [])
                            .help(tab.url)
                        }
                    }.padding(8)
                }.scrollIndicators(.never)
                Divider()
                HStack(spacing: 8) {
                    Button { viewer.enqueue(.init(kind: "back")) } label: { Image(systemName: "chevron.left") }.help("Back")
                    Button { viewer.enqueue(.init(kind: "forward")) } label: { Image(systemName: "chevron.right") }.help("Forward")
                    Button { viewer.enqueue(.init(kind: "reload")) } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                    TextField("Address", text: $address).textFieldStyle(.plain).dashboardQuietTextInput()
                        .focused($addressFocused)
                        .onSubmit {
                            var action = RemoteBrowserAction(kind: "navigate")
                            action.text = address.contains("://") ? address : "https://" + address
                            viewer.enqueue(action); addressFocused = false
                        }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 8)
                .onChange(of: viewer.selectedTab?.url, initial: true) { _, url in
                    if !addressFocused { address = url ?? "" }
                }
                .onChange(of: viewer.selectedID) { _, _ in address = viewer.selectedTab?.url ?? ""; addressFocused = false }
                Divider()
            }
            ZStack {
                DashboardPalette.foreground.opacity(0.025)
                if let error = viewer.error {
                    ContentUnavailableView("Browser unavailable", systemImage: "globe",
                        description: Text(error))
                } else if let image = viewer.image {
                    RemoteBrowserCanvas(image: image, tabID: viewer.selectedID ?? "", frameID: viewer.frameID, send: viewer.enqueue,
                        focusAddress: { addressFocused = true })
                        .accessibilityLabel("Shared remote browser: \(viewer.selectedTab?.title ?? "tab"). Click to interact.")
                } else if viewer.hasLoaded && viewer.tabs.isEmpty {
                    ContentUnavailableView("No shared browser tabs", systemImage: "globe",
                        description: Text("Ask your agent to use the shared workspace browser. Its tabs will appear here."))
                } else {
                    ProgressView("Loading browser…").controlSize(.small)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(viewer.inputError ?? "Shared with your agent · Click, type and scroll")
                    .lineLimit(2)
                Spacer()
                if let date = viewer.updatedAt { Text(date, style: .time).monospacedDigit() }
            }
            .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground).padding(12)
        }
        .foregroundStyle(DashboardPalette.foreground)
        .background(DashboardPalette.background)
        .frame(minWidth: 640, idealWidth: 1000, maxWidth: .infinity, minHeight: 480, idealHeight: 720, maxHeight: .infinity)
    }
}
