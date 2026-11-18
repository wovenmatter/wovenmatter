import LibraryClient
import SwiftUI
import UIKit
import WovenMatterShared

/// Every bot on the machine that runs them, laid out as on the Mac: Admin Bot and
/// the orchestrator first, then groups, then everyone else, team members under
/// their manager. A bot opens straight into its main conversation.
struct BotsPane: View {
  @Bindable var model: MobileModel
  var body: some View {
    let bots = model.bots
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        switch bots.placement {
        case .unpaired: unpaired
        case .searching:
          ProgressView("Looking for your bots…").frame(maxWidth: .infinity).padding(.vertical, 40)
            .accessibilityIdentifier("bots-searching")
        case .off(let checked): off(checked)
        case .unavailable(let name, let message):
          GroupLabel(text: "Bots on \(name)")
          caption(message).accessibilityIdentifier("bots-unavailable")
        case .ready:
          if let session = bots.session { BotsList(model: model, session: session) }
        }
      }.padding(.horizontal, 18).padding(.bottom, 24)
    }
    .refreshable { await model.refreshBots() }
    .task {
      // A fresh look each visit, at most once a minute; the socket keeps the list live.
      if bots.lastChecked.map({ Date().timeIntervalSince($0) > 60 }) ?? true || bots.session == nil { await model.refreshBots() }
    }
    .mobileNavigationPage("Bots")
  }

  @ViewBuilder private var unpaired: some View {
    caption("Pair with Woven Matter on your Mac to talk to your bots here. Your bots keep running on your computer; this \(model.deviceNoun) connects to them.")
      .padding(.top, 12).accessibilityIdentifier("bots-unpaired")
    if model.credential == nil || model.needsMemberPairing {
      SettingsNavigationRow(title: model.needsMemberPairing ? "Pair again" : "Connect your Mac", icon: .monitor) { PairingPane(model: model) }
    }
  }

  @ViewBuilder private func off(_ checked: [MobileBotsCheck]) -> some View {
    caption(checked.isEmpty
      ? "None of your computers can be reached right now. Bots appear here when the computer running them is online."
      : "None of your reachable computers is running bots. Turn them on in Woven Matter on your Mac: Settings → Bots.")
      .padding(.top, 12).accessibilityIdentifier("bots-off")
    if !checked.isEmpty {
      GroupLabel(text: "Your computers")
      ForEach(checked) { check in
        VStack(alignment: .leading, spacing: 3) {
          Text(check.name)
          Text(check.detail).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
      }
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(WovenPalette.mutedForeground)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
  }
}

private struct BotsList: View {
  @Bindable var model: MobileModel
  let session: MobileBotSession
  var body: some View {
    Text(session.isConnected ? "Running on \(session.machine.name)" : "Connecting to \(session.machine.name)…")
      .font(.caption).foregroundStyle(WovenPalette.mutedForeground)
      .padding(.horizontal, 14).padding(.top, 8).accessibilityIdentifier("bots-machine")
    if let error = session.loadError, !session.hasLoadedBots {
      Text(error).font(.caption).foregroundStyle(WovenPalette.danger).padding(.horizontal, 14).padding(.top, 8)
    }
    if !session.hasLoadedBots {
      ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
    } else if session.bots.isEmpty {
      Text("No bots yet. Create one in Woven Matter on your Mac.").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
        .padding(.horizontal, 14).padding(.top, 16)
    } else {
      // As in the Mac's sidebar: Admin Bot and the orchestrator lead, then groups.
      let layout = session.layout, grouped = layout.groups.filter { !$0.rows.isEmpty }
      ForEach(layout.pinned) { row in BotRow(model: model, session: session, row: row) }
      ForEach(grouped) { group in
        GroupLabel(text: group.group.name)
        ForEach(group.rows) { row in BotRow(model: model, session: session, row: row) }
      }
      if !layout.ungrouped.isEmpty {
        if !grouped.isEmpty { GroupLabel(text: "Other bots") }
        ForEach(layout.ungrouped) { row in BotRow(model: model, session: session, row: row) }
      }
    }
  }
}

private struct BotRow: View {
  @Bindable var model: MobileModel
  let session: MobileBotSession
  let row: PiBotSidebarLayout.Row
  var body: some View {
    NavigationLink {
      BotConversationPane(model: model, session: session, botID: row.bot.id, conversationID: nil)
    } label: {
      HStack(spacing: 14) {
        LucideIcon(glyph: .bot, size: 22).frame(width: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(row.bot.name).lineLimit(1)
          if let detail = Self.detail(row.bot) {
            Text(detail).font(.caption).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        LucideIcon(glyph: .chevronDown, size: 16).rotationEffect(.degrees(-90)).foregroundStyle(WovenPalette.mutedForeground)
      }.padding(.leading, row.isTeamMember ? 34 : 14).padding(.trailing, 14).padding(.vertical, 11)
        .frame(minHeight: 52).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityIdentifier("bot-\(row.bot.id)")
  }

  /// The role first (Admin Bot, orchestrator, manager), then the model profile.
  static func detail(_ bot: PiBotSummary) -> String? {
    let role = bot.isAdmin ? "Admin" : bot.orchestrator ? "Orchestrator" : bot.manager ? "Manager" : nil
    let parts = [role, bot.profileName].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// A bot's main conversation or one of its threads: history, the live reply, and a
/// composer. The bot's runtime owns the conversation; this is Woven's chat over its
/// protocol, with Pi Bot's thread behavior (a thread shows only what was said in it).
struct BotConversationPane: View {
  @Bindable var model: MobileModel
  let session: MobileBotSession
  let botID: String
  let conversationID: Int?
  @State private var controller: PiBotConversationController?
  @State private var text = ""
  @State private var threadsPresented = false
  @State private var openedThread: Int?
  /// The sheet's choice, applied once it has closed so the two animations don't overlap.
  @State private var chosen: Int??
  @Environment(\.dismiss) private var dismissPane
  @State private var composerFocused = false
  @State private var dictationEditor = MobileDictationEditor()
  @Environment(\.wovenTheme) private var theme

  private var bot: PiBotSummary? { session.bot(botID) }
  private var key: PiBotConversationKey { .init(machineID: session.machine.deviceID, botID: botID, conversationID: conversationID) }
  private var thread: PiBotThread? { conversationID.flatMap { id in session.threads(for: botID).first { $0.conversationId == id } } }
  private var title: String { conversationID == nil ? (bot?.name ?? "Bot") : (thread?.label ?? "Thread") }

  var body: some View {
    VStack(spacing: 0) {
      if let controller { transcript(controller) } else { Spacer() }
      if let error = controller?.error {
        Text(error).font(.caption).foregroundStyle(WovenPalette.danger).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20).padding(.top, 6).accessibilityIdentifier("bot-error")
      }
      composer
    }
    .mobileNavigationPage(title)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { threadsPresented = true } label: { LucideIcon(glyph: .gitBranch, size: 18) }
          .accessibilityLabel("Threads").accessibilityIdentifier("bot-threads")
      }
    }
    .sheet(isPresented: $threadsPresented, onDismiss: {
      guard let choice = chosen else { return }
      chosen = nil
      // The main conversation is where every thread was opened from.
      if let id = choice { openedThread = id } else if conversationID != nil { dismissPane() }
    }) {
      BotThreadsSheet(session: session, botID: botID, botName: bot?.name ?? "Bot", current: conversationID) { id in
        chosen = .some(id); threadsPresented = false
      }.environment(\.wovenTheme, theme)
    }
    .navigationDestination(item: $openedThread) { id in
      BotConversationPane(model: model, session: session, botID: botID, conversationID: id)
    }
    .onAppear {
      let next = session.conversation(botID: botID, conversationID: conversationID)
      controller = next
      next.attach()
      text = model.bots.draft(key)
    }
    .onDisappear {
      controller?.detach()
      model.bots.setDraft(text, for: key)
    }
    .onChange(of: text) { _, value in model.bots.setDraft(value, for: key) }
  }

  @ViewBuilder private func transcript(_ controller: PiBotConversationController) -> some View {
    let name = bot?.name ?? "Bot"
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          if controller.isThread, let origin = controller.origin { BotThreadOriginCard(entry: origin, botName: name) }
          if controller.loading && controller.state.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
          } else if controller.visibleEntries.isEmpty && controller.state.pending.isEmpty && controller.state.streaming == nil && !controller.state.running {
            Text(controller.isThread ? "Nothing in this thread yet." : "Say hello to \(name).")
              .font(.callout).foregroundStyle(WovenPalette.mutedForeground).frame(maxWidth: .infinity).padding(.vertical, 40)
          }
          ForEach(controller.visibleEntries) { entry in
            BotEntryView(entry: entry, botName: name,
              replies: controller.isThread ? [] : session.threads(for: botID).filter { $0.forkedAt == entry.id && $0.parentConversationId == controller.viewedID },
              openThread: { openedThread = $0 },
              startThread: controller.isThread || entry.isUser ? nil : {
                Task { if let thread = await controller.startThread(from: entry) { openedThread = thread.conversationId } }
              })
            .id(entry.id)
          }
          ForEach(controller.state.pending) { pending in
            HStack(spacing: 0) {
              Spacer(minLength: 56)
              ConversationUserBubble(content: pending.text) { EmptyView() }.opacity(0.6)
            }
          }
          if controller.state.running || controller.state.streaming != nil {
            BotStreamingView(botName: name, text: controller.state.streaming).id("streaming")
          }
          Color.clear.frame(height: 1).id("end")
        }.padding(.horizontal, 18).padding(.vertical, 16)
      }
      .onChange(of: controller.visibleEntries.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
      .onChange(of: controller.state.streaming) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
      .onChange(of: controller.loading) { _, loading in if !loading { proxy.scrollTo("end", anchor: .bottom) } }
      .onAppear { proxy.scrollTo("end", anchor: .bottom) }
    }
  }

  private var composer: some View {
    let ready = controller?.isReady == true
    let running = controller?.state.running == true || controller?.state.streaming != nil
    let prompt = !ready ? "Connecting…" : (controller?.isThread == true ? "Reply in thread…" : "Message \(bot?.name ?? "the bot")…")
    return HStack(alignment: .bottom, spacing: 8) {
      MobileDictationComposer(text: $text, focused: $composerFocused, editor: dictationEditor,
        identity: "bot:\(session.machine.deviceID):\(botID):\(conversationID.map(String.init) ?? "main")", prompt: prompt)
        .overlay(alignment: .topLeading) {
          if text.isEmpty { Text(prompt).foregroundStyle(WovenPalette.mutedForeground).allowsHitTesting(false).accessibilityHidden(true) }
        }.accessibilityIdentifier("bot-composer")
      MobileDictationMicrophone(editor: dictationEditor)
      if running {
        Button { Task { await controller?.stop() } } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }
          .buttonStyle(WovenIconButtonStyle()).accessibilityLabel("Stop reply").disabled(controller?.stopping == true || !ready)
      }
      Button { send() } label: {
        Group {
          if controller?.sending == true { ProgressView().tint(WovenPalette.primaryForeground) } else { LucideIcon(glyph: .arrowUp, size: 20) }
        }.frame(width: 44, height: 44).foregroundStyle(WovenPalette.primaryForeground)
          .background(canSend ? WovenPalette.primaryFill : Color.gray.opacity(0.35), in: Circle())
      }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel("Send message").accessibilityIdentifier("bot-send")
    }.padding(15).background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: WovenMetrics.composerRadius, style: .continuous))
      .padding(.horizontal, 18).padding(.vertical, 12)
  }

  private var canSend: Bool {
    controller?.isReady == true && controller?.sending == false && !DictationSession.shared.isBusy
      && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func send() {
    guard let controller, canSend else { return }
    let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
    text = ""
    Task {
      // The server didn't take it: put it back so nothing is lost.
      if await controller.send(text: message, context: nil) == false, text.isEmpty { text = message }
    }
  }
}

private struct BotEntryView: View {
  let entry: PiBotDisplayEntry
  let botName: String
  let replies: [PiBotThread]
  let openThread: (Int) -> Void
  let startThread: (() -> Void)?
  var body: some View {
    HStack(spacing: 0) {
      if entry.isUser { Spacer(minLength: 56) }
      VStack(alignment: entry.isUser ? .trailing : .leading, spacing: 6) {
        if !entry.isUser {
          Text(botName).font(.caption.weight(.medium)).foregroundStyle(WovenPalette.foreground).padding(.horizontal, 4)
        }
        if !entry.text.isEmpty {
          if entry.isUser {
            ConversationUserBubble(content: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)) { EmptyView() }
          } else {
            ConversationResponse(content: entry.text, isStreaming: false, showsCopyButton: false).padding(.horizontal, 4)
          }
        }
        if entry.isStopped { Text("Stopped").font(.caption2).foregroundStyle(WovenPalette.mutedForeground).padding(.horizontal, 4) }
        if let error = entry.error {
          Text(error).font(.caption).foregroundStyle(WovenPalette.danger).padding(.horizontal, 4)
          if entry.needsSignIn || entry.hitLimit {
            Text(entry.needsSignIn
              ? "Sign in to its model provider in Woven Matter on your Mac: Settings → Subscriptions & API Keys."
              : "Change its model in Woven Matter on your Mac: Settings → Bots.")
              .font(.caption).foregroundStyle(WovenPalette.mutedForeground).padding(.horizontal, 4)
          }
        }
        ForEach(replies) { reply in
          Button { openThread(reply.conversationId) } label: {
            Label(reply.label, glyph: .messageSquareReply).font(.caption.weight(.medium)).lineLimit(1)
          }.buttonStyle(.plain).foregroundStyle(WovenPalette.success).padding(.horizontal, 4)
            .accessibilityLabel("Open thread: \(reply.label)")
        }
      }.frame(maxWidth: entry.isUser ? nil : .infinity, alignment: entry.isUser ? .trailing : .leading)
    }
    .contextMenu {
      Button("Copy", glyph: .copy) { UIPasteboard.general.string = entry.text }
      if let startThread { Button("Start a thread", glyph: .gitBranch, action: startThread) }
    }
  }
}

private struct BotStreamingView: View {
  let botName: String
  let text: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(botName).font(.caption.weight(.medium)).foregroundStyle(WovenPalette.foreground).padding(.horizontal, 4)
      if let text, !text.isEmpty {
        ConversationResponse(content: text, isStreaming: true, showsCopyButton: false).padding(.horizontal, 4)
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Thinking…").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
        }.padding(.horizontal, 4)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("bot-streaming")
  }
}

private struct BotThreadOriginCard: View {
  let entry: PiBotDisplayEntry
  let botName: String
  @Environment(\.wovenTheme) private var theme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Started from").font(.caption.weight(.medium)).foregroundStyle(WovenPalette.mutedForeground)
      if entry.isUser { Text(entry.text).font(.callout).lineLimit(6) }
      else {
        Text(botName).font(.caption.weight(.medium))
        ConversationResponse(content: entry.text, isStreaming: false, showsCopyButton: false)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: WovenMetrics.cardRadius, style: .continuous))
  }
}

/// The bot's main conversation and its threads, pinned first, then newest.
private struct BotThreadsSheet: View {
  let session: MobileBotSession
  let botID: String
  let botName: String
  let current: Int?
  let open: (Int?) -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        Section {
          Button { current == nil ? dismiss() : open(nil) } label: {
            Label("Main conversation", glyph: .messageSquare)
          }.disabled(current == nil)
        }
        Section("Threads") {
          let threads = session.threads(for: botID)
          if threads.isEmpty {
            Text("No threads yet. Touch and hold a reply to start one.").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
          }
          ForEach(threads) { thread in
            Button { thread.conversationId == current ? dismiss() : open(thread.conversationId) } label: {
              HStack {
                Label(thread.label, glyph: thread.isPinned ? .pin : .messageSquareReply).lineLimit(1)
                Spacer()
                if thread.conversationId == current { LucideIcon(glyph: .check, size: 16) }
              }
            }
            .swipeActions {
              Button(thread.isPinned ? "Unpin" : "Pin") {
                Task { await session.setPinned(botID: botID, conversationID: thread.conversationId, pinned: !thread.isPinned) }
              }.tint(WovenPalette.primaryFill)
            }
          }
        }
      }
      .navigationTitle(botName).navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
      .task { await session.loadThreads(botID: botID) }
    }.presentationDetents([.medium, .large])
  }
}
