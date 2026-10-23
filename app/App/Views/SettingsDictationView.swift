import AppKit
import SwiftUI
import WovenMatterCompanion

struct SettingsDictationView: View {
    let model: ApplicationModel
    var client: CentralLibraryClientModel?
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var records: [DictationRecord] = []
    private let pageSize = 20
    @State private var page = 0
    @State private var hasNextPage = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        SettingsPage(title: "Dictation", detail: "Your completed dictations. Click on an entry to see it in full.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if let problem = DictationSession.shared.historyError {
                Text(problem).font(.system(size: 13)).foregroundStyle(DashboardPalette.danger)
                Button("Retry saving") { DictationSession.shared.retrySavingHistory() }.buttonStyle(SettingsQuietButtonStyle())
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(DashboardPalette.danger) }
            if !loaded { ProgressView() }
            else if records.isEmpty {
                SettingsCard(title: "No dictations yet") {
                    Text("Completed dictations will appear here when you stop recording.")
                        .font(.system(size: 13)).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
            LazyVStack(spacing: 8) {
                ForEach(records) { record in DictationHistoryRow(record: record) }
            }
            if !records.isEmpty || page > 0 {
                HStack(spacing: 8) {
                    if page > 0 {
                        Button { changePage(to: 0) } label: {
                            DashboardLucideIcon(glyph: .chevronsLeft, size: 16).frame(width: 32, height: 32)
                        }.accessibilityLabel("First page").help("First page")
                    } else {
                        Color.clear.frame(width: 32, height: 32).accessibilityHidden(true)
                    }
                    Button { changePage(to: page - 1) } label: {
                        DashboardLucideIcon(glyph: .arrowLeft, size: 16).frame(width: 32, height: 32)
                    }.disabled(page == 0).accessibilityLabel("Previous page").help("Previous page")
                    Text("Page \(page + 1)").font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(DashboardPalette.mutedForeground).fixedSize()
                    Button { changePage(to: page + 1) } label: {
                        DashboardLucideIcon(glyph: .arrowRight, size: 16).frame(width: 32, height: 32)
                    }.disabled(!hasNextPage).accessibilityLabel("Next page").help("Next page")
                    // Balance the first-page slot so the page number stays centered.
                    Color.clear.frame(width: 32, height: 32).accessibilityHidden(true)
                }.buttonStyle(DashboardIconButtonStyle()).frame(maxWidth: .infinity)
            }
        }
        .id(page)
        .task(id: page) {
            repeat {
                await reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: DictationSession.shared.historyRevision) { _, _ in Task { await reload() } }
    }
    private func changePage(to newPage: Int) {
        records = []; loaded = false; hasNextPage = false; error = nil
        page = newPage
    }
    private func reload() async {
        let requestedPage = page
        do {
            let fetched: [DictationRecord]
            if let client {
                guard let store = client.clientStore else { throw ApplicationModelError.dashboardStoreUnavailable }
                fetched = try await store.dictations.records(limit: pageSize + 1, offset: requestedPage * pageSize)
            } else {
                guard let database = model.dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
                fetched = try await database.dictationHistory(limit: pageSize + 1, offset: requestedPage * pageSize)
            }
            guard !Task.isCancelled, page == requestedPage else { return }
            records = Array(fetched.prefix(pageSize)); hasNextPage = fetched.count > pageSize
            loaded = true; error = nil
        } catch {
            guard !Task.isCancelled, page == requestedPage else { return }
            self.error = error.localizedDescription; loaded = true
        }
    }
}

private struct DictationHistoryRow: View {
    let record: DictationRecord
    @State private var expanded = false
    @State private var copied = false
    @Environment(\.dashboardTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
            if expanded {
                Text(record.text).font(.system(size: 13)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show less") { expanded = false }.buttonStyle(SettingsQuietButtonStyle())
            } else {
                Button { expanded = true } label: {
                    Text(record.text).font(.system(size: 13)).lineLimit(3)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Read full dictation")
                    .accessibilityHint("Show full dictation")
            }
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(record.text, forType: .string)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }.buttonStyle(DashboardIconButtonStyle())
                .help(copied ? "Copied" : "Copy dictation")
                .accessibilityLabel(copied ? "Copied dictation" : "Copy dictation")
                .task(id: copied) {
                    guard copied else { return }
                    do { try await Task.sleep(for: .seconds(2)); copied = false } catch { }
                }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(theme.palette.workspace).clipShape(DashboardShapes.card)
    }
}
