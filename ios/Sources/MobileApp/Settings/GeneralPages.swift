import SwiftUI
import UIKit

/// This iPhone or iPad: its name, as the person's Macs list it.
struct DevicePage: View {
    @Bindable var model: MobileModel
    let deviceID: String
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var savedName: String { model.app.devices.device(id: deviceID)?.device.name ?? "" }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(save)
                    .wovenInput()
                    .settingsFieldRow()
                    .accessibilityLabel("\(ThisDevice.kind) name")
                    .accessibilityIdentifier("device-name")
                if let error { SettingsCaption(error, isError: true) }
            } header: {
                SettingsHeader(title: "Name")
            }
        }
        .settingsPage("This \(ThisDevice.kind)")
        .onAppear { name = savedName }
        .onChange(of: savedName) { _, saved in if !focused { name = saved } }
        .onChange(of: focused) { _, focused in if !focused { save() } }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name = savedName }
        guard trimmed != savedName else { return }
        Task {
            do {
                try await model.app.machines.rename(deviceID, to: trimmed)
                await model.app.devices.reload()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The theme, which also sets light or dark appearance.
struct AppearancePage: View {
    @AppStorage(WovenTheme.storageKey) private var storedTheme = WovenTheme.green.rawValue

    var body: some View {
        List {
            Section {
                WovenSegmentedSelector(options: WovenTheme.allCases.map(\.rawValue), selection: $storedTheme) {
                    WovenTheme(rawValue: $0)?.title ?? $0
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Theme")
                .accessibilityIdentifier("appearance-theme")
                .settingsFieldRow()
            } header: {
                SettingsHeader(title: "Theme")
            }
        }
        .settingsPage("Appearance")
    }
}

/// Completed dictations from every machine and device, newest first, a page
/// at a time, and the language dictation listens for.
struct DictationPage: View {
    @Bindable var model: MobileModel
    @State private var records: [DictationRecord] = []
    @State private var page = 0
    @State private var hasNextPage = false
    @State private var loaded = false
    @State private var error: String?
    private let pageSize = 20

    private var session: DictationSession { DictationSession.shared }

    var body: some View {
        List {
            Section {
                Picker(selection: Binding(get: { session.languageIdentifier }, set: { session.languageIdentifier = $0 })) {
                    Text("Automatic").tag("")
                    ForEach(session.availableLanguages, id: \.self) { identifier in
                        Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                    }
                } label: {
                    Text("Language").foregroundStyle(WovenPalette.foreground)
                }
                .tint(WovenPalette.mutedForeground)
                .disabled(session.isBusy)
                .frame(minHeight: 44)
                .settingsRow()
                .accessibilityIdentifier("dictation-language")
            }
            Section {
                if let problem = session.historyError {
                    SettingsCaption(problem, isError: true)
                    SettingsActionRow(title: "Retry saving") { session.retrySavingHistory() }
                }
                if let error { SettingsCaption(error, isError: true) }
                if loaded && records.isEmpty && page == 0 {
                    SettingsCaption("Completed dictations appear here when you stop recording.")
                }
                ForEach(records) { record in DictationRow(record: record) }
                if page > 0 || hasNextPage { pager }
            } header: {
                SettingsHeader(title: "History")
            }
        }
        .settingsPage("Dictation")
        .task { await session.loadLanguages() }
        .task(id: page) {
            // Dictations made on other machines arrive as the library syncs.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: session.historyRevision) { _, _ in Task { await reload() } }
    }

    private var pager: some View {
        HStack {
            Button { change(to: page - 1) } label: {
                LucideIcon(glyph: .arrowLeft, size: 18).frame(width: 44, height: 44)
            }
            .disabled(page == 0)
            .accessibilityLabel("Previous page")
            Spacer()
            Text("Page \(page + 1)").font(.subheadline).monospacedDigit().foregroundStyle(WovenPalette.mutedForeground)
            Spacer()
            Button { change(to: page + 1) } label: {
                LucideIcon(glyph: .arrowRight, size: 18).frame(width: 44, height: 44)
            }
            .disabled(!hasNextPage)
            .accessibilityLabel("Next page")
        }
        .buttonStyle(WovenIconButtonStyle())
        .settingsFieldRow()
    }

    private func change(to newPage: Int) {
        records = []
        loaded = false
        hasNextPage = false
        page = newPage
    }

    private func reload() async {
        let requested = page
        do {
            let fetched = try await model.app.settings.dictationHistory(limit: pageSize + 1, offset: requested * pageSize)
            guard page == requested else { return }
            records = Array(fetched.prefix(pageSize))
            hasNextPage = fetched.count > pageSize
            error = nil
        } catch {
            guard page == requested else { return }
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

private struct DictationRow: View {
    let record: DictationRecord
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(WovenPalette.mutedForeground)
            Text(record.text)
                .foregroundStyle(WovenPalette.foreground)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
                .accessibilityHint(expanded ? "Shows less" : "Shows the full dictation")
            HStack {
                Spacer()
                CopyButton(title: "Copy", value: record.text)
            }
        }
        .padding(.vertical, 6)
        .settingsRow()
    }
}
