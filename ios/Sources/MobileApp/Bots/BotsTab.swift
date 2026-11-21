import SwiftUI

/// The Bots tab: the Forum and your bots, from the bots' host through the
/// shared `BotsStore`. A row opens that bot's main channel and a chevron shows
/// its threads; a channel, thread or the Forum opens as its own page. On iPad
/// the list sits beside the open channel.
struct BotsTab: View {
    @Bindable var model: MobileModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.wovenTheme) private var theme
    @State private var naming = false
    @State private var newName = ""
    /// On iPad, the channel beside the list; the Forum until another is chosen.
    @State private var selection: BotTarget?

    private var bots: BotsStore { model.app.bots }

    var body: some View {
        Group {
            if let host = bots.hostMachineID {
                if sizeClass == .regular {
                    HStack(spacing: 0) {
                        list.frame(width: 340)
                        Rectangle().fill(theme.palette.border).frame(width: 0.5).ignoresSafeArea(edges: .bottom)
                        let shown = selection.flatMap { $0.machineID == host ? $0 : nil } ?? .forum(machineID: host)
                        BotPage(model: model, target: shown, embedded: true)
                            .id(shown)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    list
                }
            } else {
                VStack(spacing: 0) {
                    TabRootHeader(title: "Bots")
                    BotsEmptyState(model: model)
                }
            }
        }
        .navigationDestination(for: BotTarget.self) { target in
            BotPage(model: model, target: target, embedded: false)
                .mobilePageSurface()
        }
        .alert("New bot", isPresented: $naming) {
            TextField("Bot name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create() }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Bots", isPresented: Binding(get: { bots.notice != nil }, set: { if !$0 { bots.notice = nil } })) {
            Button("OK", role: .cancel) { bots.notice = nil }
        } message: {
            Text(bots.notice ?? "")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            TabRootHeader(title: "Bots") {
                Button {
                    newName = ""
                    naming = true
                } label: {
                    LucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44)
                }
                .disabled(!bots.isConnected)
                .accessibilityLabel("New bot")
                .accessibilityIdentifier("bots-new")
            }
            BotsList(bots: bots, selected: sizeClass == .regular ? (selection ?? bots.hostMachineID.map { .forum(machineID: $0) }) : nil,
                     onOpen: open)
        }
    }

    /// Shows a channel: beside the list on iPad, as its own page on iPhone.
    private func open(_ target: BotTarget) {
        if sizeClass == .regular {
            selection = target
            model.paths[.bots] = NavigationPath()
        } else {
            model.paths[.bots, default: NavigationPath()].append(target)
        }
    }

    private func create() {
        let name = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, let host = bots.hostMachineID else { return }
        Task {
            if let bot = await bots.createBot(name: name) { open(BotTarget(machineID: host, botID: bot.id)) }
        }
    }
}

/// Before any machine runs bots: what they are, and that they are set up on a
/// Mac. With no machine connected yet, the way to connect one.
private struct BotsEmptyState: View {
    @Bindable var model: MobileModel

    private var hasMachine: Bool { model.app.machines.machines.contains { !$0.isThisMachine } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(WovenPalette.primaryFill).frame(width: 64, height: 64)
                    LucideIcon(glyph: .bot, size: 26).foregroundStyle(WovenPalette.primaryForeground)
                }
                .accessibilityHidden(true)
                Text("Your bots")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 18)
                Text("Bots are agents with their own memory and files that you talk with here, one to one and together in the Forum. You set them up in Woven Matter on a Mac, and they run on one of your machines.")
                    .font(.callout)
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .padding(.top, 8)
                if !hasMachine {
                    Button("Connect your Mac") { model.openSettings(.connectMachine) }
                        .buttonStyle(WovenPrimaryButtonStyle())
                        .padding(.top, 22)
                        .accessibilityIdentifier("bots-connect-mac")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .accessibilityIdentifier("bots-empty-state")
    }
}
