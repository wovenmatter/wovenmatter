import SwiftUI

/// One page of the Bots tab: a bot's channel or thread, or the Forum or one of
/// its threads.
struct BotPage: View {
    @Bindable var model: MobileModel
    let target: BotTarget
    /// Beside the list on iPad, with its own header; otherwise a pushed page.
    let embedded: Bool

    private var bots: BotsStore { model.app.bots }
    /// A target left from a former host belongs to no bot shown here.
    private var isOnHost: Bool { bots.hostMachineID == target.machineID }

    var body: some View {
        Group {
            if isOnHost, bots.onboarding?.needed == true {
                BotPageFrame(title: target.isForum ? "Forum" : "Bots", embedded: embedded) {
                    BotsNotice(glyph: .bot, title: "Finish setting up your bots",
                               detail: "Choose their model in Settings → Bots in Woven Matter on a Mac.")
                }
            } else if isOnHost, target.isForum {
                ForumChannel(model: model, roomID: target.conversationID, embedded: embedded)
            } else if isOnHost, let bot = bots.bots.first(where: { $0.id == target.botID }) {
                BotChannel(model: model, bot: bot, conversationID: target.conversationID, embedded: embedded)
            } else {
                BotPageFrame(title: "Bots", embedded: embedded) {
                    if bots.hasLoadedBots || !isOnHost {
                        BotsNotice(glyph: .bot, title: "This bot was deleted",
                                   detail: "Restore it from Settings → Bots on a Mac, or choose another bot.")
                    } else {
                        Text("Loading…").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        // A provider connected on the Mac ends first-run setup here.
        .task(id: target.botID) { await bots.refreshOnboarding() }
    }
}

/// A page's header: inline in the navigation bar when pushed, its own row
/// when it sits beside the list.
struct BotPageFrame<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    /// An untitled thread's placeholder name.
    var titleIsPlaceholder = false
    let embedded: Bool
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    init(title: String, subtitle: String? = nil, titleIsPlaceholder: Bool = false, embedded: Bool,
         @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.titleIsPlaceholder = titleIsPlaceholder
        self.embedded = embedded
        self.actions = actions
        self.content = content
    }

    var body: some View {
        if embedded {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    titleBlock(alignment: .leading)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) { actions() }
                        .buttonStyle(WovenIconButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)
                content()
            }
        } else {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { titleBlock(alignment: .center) }
                    ToolbarItemGroup(placement: .topBarTrailing) { actions() }
                }
        }
    }

    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.headline)
                .foregroundStyle(titleIsPlaceholder ? WovenPalette.mutedForeground : WovenPalette.foreground)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("bot-page-title")
    }
}

extension BotPageFrame where Actions == EmptyView {
    init(title: String, embedded: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, embedded: embedded, actions: { EmptyView() }, content: content)
    }
}

/// A calm page in place of a conversation: its mark, a title and one line.
struct BotsNotice: View {
    let glyph: LucideGlyph
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(WovenPalette.primaryFill).frame(width: 56, height: 56)
                LucideIcon(glyph: glyph, size: 22).foregroundStyle(WovenPalette.primaryForeground)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
