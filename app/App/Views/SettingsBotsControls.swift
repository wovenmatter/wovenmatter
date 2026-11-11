import AppKit
import SwiftUI
import WovenMatterClient

struct BotSettingsActionLabel: View {
    let title: String
    let glyph: DashboardLucideGlyph
    var body: some View {
        HStack(spacing: 6) {
            DashboardLucideIcon(glyph: glyph, size: 13)
            Text(title)
        }
    }
}

struct BotSettingsLink: View {
    let title: String
    let url: String
    let onOpenLink: (URL) -> Void
    var body: some View {
        Button { if let target = URL(string: url) { onOpenLink(target) } } label: {
            BotSettingsActionLabel(title: title, glyph: .externalLink)
                .foregroundStyle(DashboardPalette.success)
        }
        .buttonStyle(SettingsQuietButtonStyle())
    }
}

struct BotSettingsCopy: View {
    let title: String
    let text: String
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: { BotSettingsActionLabel(title: title, glyph: .copy) }
        .buttonStyle(SettingsQuietButtonStyle())
    }
}

struct BotSettingsTextEditor: View {
    @Environment(\.dashboardTheme) private var theme
    @Binding var text: String
    let label: String
    var placeholder = ""
    var height: CGFloat = 100
    var monospaced = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder).font(.settingsBody).foregroundStyle(DashboardPalette.mutedForeground)
                    .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .settingsText)
                .foregroundStyle(DashboardPalette.foreground)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .accessibilityLabel(label)
        }
        .padding(6)
        .frame(height: height)
        .background(theme.palette.themeWhisper)
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius))
    }
}

/// Models grouped by provider, styled like `SettingsPicker`, whose flat options cannot group them.
struct BotSettingsModelPicker: View {
    let providers: [PiBotProviderModels]
    @Binding var selection: String
    let label: String
    var emptyLabel: String?
    @State private var presented = false

    private var known: Bool {
        providers.contains { provider in provider.models.contains { "\(provider.id)/\($0.id)" == selection } }
    }
    private var selectedLabel: String {
        if selection.isEmpty { return emptyLabel ?? "Pick a model…" }
        for provider in providers {
            if let model = provider.models.first(where: { "\(provider.id)/\($0.id)" == selection }) { return model.name }
        }
        return "\(selection) (not signed in)"
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 8) {
                Text(selectedLabel)
                    .font(.settingsBody.weight(.medium))
                    .foregroundStyle(DashboardPalette.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .frame(maxWidth: 280, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(SettingsQuietButtonStyle(isActive: presented))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(label)
        .accessibilityValue(selectedLabel)
        .popover(isPresented: $presented) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let emptyLabel { option(emptyLabel, value: "") }
                    else if selection.isEmpty { option("Pick a model…", value: "") }
                    if !selection.isEmpty, !known { option("\(selection) (not signed in)", value: selection) }
                    ForEach(providers) { provider in
                        Text(provider.name).font(.settingsSecondary.weight(.semibold))
                            .foregroundStyle(DashboardPalette.mutedForeground).padding(.top, 8).padding(.horizontal, 10)
                        ForEach(provider.models) { model in
                            option(model.name, value: "\(provider.id)/\(model.id)")
                        }
                    }
                }.padding(6)
            }
            .scrollIndicators(.never)
            .frame(width: 340).frame(maxHeight: 420)
            .onExitCommand { presented = false }
        }
    }

    private func option(_ title: String, value: String) -> some View {
        Button { selection = value; presented = false } label: {
            HStack {
                Text(title).font(.settingsText).foregroundStyle(DashboardPalette.foreground)
                Spacer()
                if value == selection {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DashboardPalette.primary)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(SettingsMenuOptionButtonStyle())
    }
}

struct BotSettingsModelFacts: View {
    let providers: [PiBotProviderModels]
    let model: String
    var name: String?

    private var pricing: PiBotModelPricing? {
        for provider in providers {
            if let found = provider.models.first(where: { "\(provider.id)/\($0.id)" == model }) { return found.pricing }
        }
        return nil
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(model).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                SettingsNote(PiBotModelFacts.text(providers, model))
                ForEach(PiBotModelFacts.tierTexts(pricing), id: \.self) { SettingsNote($0) }
            }.padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                if let name { Text(name).fontWeight(.medium) }
                Text("Model details").foregroundStyle(DashboardPalette.mutedForeground)
            }.font(.settingsBody)
        }
        .accessibilityLabel("Model details for \(name ?? model)")
    }
}

/// For references whose visible names differ from their protocol identifiers.
struct BotSettingsReferencePicker: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        init(_ id: String, _ title: String) { self.id = id; self.title = title }
    }
    let selection: String
    let options: [Option]
    let label: String
    let onSelect: @MainActor (String) -> Void

    var body: some View {
        SettingsPicker(label, selection: Binding(get: { selection }, set: onSelect), options: options.map(\.id)) { id in
            options.first { $0.id == id }?.title ?? id
        }
    }
}
