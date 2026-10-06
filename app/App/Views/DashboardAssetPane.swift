import SwiftUI
import WovenMatterCore

struct DashboardAssetPane: View {
    @Bindable var model: ApplicationModel
    @Bindable var assets: WorkspaceAssetSession
    let compact: Bool
    @Binding var noteOnLeft: Bool
    @Binding var focused: Bool
    let reservesLeadingRailControlSpace: Bool
    let reservesTrailingRailControlSpace: Bool
    let newlyCreatedNoteID: String?
    let onNewNoteFocusHandled: (String) -> Void
    let onBack: () -> Void
    @Environment(\.dashboardTheme) private var theme

    private var notes: [WorkspaceNoteRecord] { model.workspaceOverview?.notes ?? [] }
    var body: some View {
        let _ = assets.pageRevision
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if compact { control("Back to chat", symbol: "chevron.left", action: onBack) }
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(assets.tabs.tabs) { tab in
                            HStack(spacing: 4) {
                                Button {
                                    assets.tabs.select(tab)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: icon(tab))
                                        Text(assets.title(for: tab, notes: notes)).lineLimit(1)
                                    }
                                    .padding(.leading, 9).frame(maxWidth: 140, alignment: .leading)
                                    .frame(height: DashboardMetrics.assetToolbarControlHeight)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { close(tab) } label: {
                                    Image(systemName: "xmark").font(.system(size: 12))
                                        .frame(width: DashboardMetrics.assetToolbarControlWidth,
                                               height: DashboardMetrics.assetToolbarControlHeight)
                                }
                                .buttonStyle(DashboardIconButtonStyle())
                                .help("Close tab")
                                .accessibilityLabel("Close \(assets.title(for: tab, notes: notes))")
                            }
                            .font(.system(size: 11.5, weight: assets.tabs.selected == tab ? .medium : .regular))
                            .background(assets.tabs.selected == tab ? theme.palette.workspace : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .help(assets.title(for: tab, notes: notes))
                            .accessibilityAddTraits(assets.tabs.selected == tab ? .isSelected : [])
                        }
                    }
                }.scrollIndicators(.never)
                control("New browser tab", symbol: "plus") { assets.openBrowser() }
                if !compact {
                    control(noteOnLeft ? "Move assets right" : "Move assets left",
                            symbol: noteOnLeft ? "arrow.right" : "arrow.left") { noteOnLeft.toggle() }
                    control(focused ? "Restore chat and assets" : "Focus assets",
                            symbol: focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        focused.toggle()
                    }
                }
                control("Hide assets", symbol: "rectangle.righthalf.inset.filled") { assets.tabs.hide() }
            }
            .padding(.leading, reservesLeadingRailControlSpace ? 56 : 10)
            .padding(.trailing, reservesTrailingRailControlSpace ? 56 : 10)
            .frame(height: DashboardMetrics.assetToolbarControlHeight)
            .padding(.vertical, DashboardMetrics.assetToolbarVerticalPadding)
            Rectangle().fill(theme.palette.border).frame(height: 1)
            Group {
                switch assets.tabs.selected {
                case .note(let id):
                    if let note = notes.first(where: { $0.id == id }) {
                        DashboardNotePane(
                            model: model, note: note, embeddedInTabs: true,
                            showBack: false, noteOnLeft: noteOnLeft, isFocused: focused,
                            reservesLeadingRailControlSpace: false, reservesTrailingRailControlSpace: false,
                            focusesTitleOnAppear: note.id == newlyCreatedNoteID,
                            onInitialFocusHandled: { onNewNoteFocusHandled(note.id) },
                            onBack: {}, onMove: {}, onToggleFocus: {}, onClose: { close(.note(id)) }
                        ).id(id)
                    } else {
                        ContentUnavailableView("Asset unavailable", systemImage: "doc")
                    }
                case .browser(let id):
                    if let page = assets.pages[id] {
                        DashboardBrowserPane(page: page, revision: assets.pageRevision).id(id)
                    }
                case nil: EmptyView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.palette.workspace)
        .background {
            Group {
                Button("") { assets.openBrowser() }.keyboardShortcut("t", modifiers: .command)
                Button("") {
                    if let selected = assets.tabs.selected { close(selected) }
                }.keyboardShortcut("w", modifiers: .command)
            }.hidden().accessibilityHidden(true)
        }
    }

    private func icon(_ tab: WorkspaceAssetTabs.Tab) -> String {
        if case .browser = tab { "globe" } else { "doc.text" }
    }
    private func close(_ tab: WorkspaceAssetTabs.Tab) {
        if case .note = tab {
            Task { if await model.flushNoteDrafts() { assets.close(tab) } }
        } else { assets.close(tab) }
    }
    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: DashboardMetrics.assetToolbarControlWidth,
                       height: DashboardMetrics.assetToolbarControlHeight)
        }
            .buttonStyle(DashboardIconButtonStyle()).help(title).accessibilityLabel(title)
    }
}
