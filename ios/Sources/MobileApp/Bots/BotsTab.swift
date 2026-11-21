import SwiftUI

/// The Bots tab: talking with your bots. Their chats come from the bots'
/// host, through `model.app.bots` (`BotsStore`, `BotChatStore`).
struct BotsTab: View {
    @Bindable var model: MobileModel

    var body: some View {
        VStack(spacing: 0) {
            TabRootHeader(title: "Bots")
            TabPlaceholder(glyph: .bot, title: "Bots")
        }
    }
}
