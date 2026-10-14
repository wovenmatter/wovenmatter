import SwiftUI
import CompanionInference
import CompanionClient
import WovenMatterCompanion

struct ChatPane: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CompanionModel
  @State private var referencesPresented = false
  @State private var filesPresented = false
  @State private var detailsPresented = false
  @State private var settingsPresented = false
  @State private var pendingPresented = false
  @FocusState private var composerFocused: Bool
  @State private var scrollState = DashboardConversationScrollState()
  @State private var isUserScrolling = false
  @State private var transcriptOwnsScroll = false
  @State private var scrollInteractionRevision = 0
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(model.selectedConversation?.title ?? "New chat").font(.headline).lineLimit(1)
          Text(model.executionName).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
        }.contextMenu {
          if model.selectedConversationID != nil {
            Button("Details and export") { detailsPresented = true }
            Button("Session settings") { settingsPresented = true }.disabled(!model.executionOnline)
          }
          if !model.allPending.isEmpty { Button("Pending requests") { pendingPresented = true } }
        }
        Spacer()
        Button { composerFocused = false; Task { await model.newChatWithCurrentAgent() } } label: {
          if model.startingChat { ProgressView().frame(width: 44, height: 44) }
          else { DashboardLucideIcon(glyph: .squarePen, size: 22).frame(width: 44, height: 44) }
        }.buttonStyle(DashboardIconButtonStyle()).disabled(model.startingChat || model.sending || model.chatSettingsBusy)
          .accessibilityLabel("New chat with this agent").accessibilityIdentifier("chat-new-session")
      }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 32) {
            if let id = model.selectedConversationID, model.historyPages[id] != nil {
              Button("Return to latest messages", systemImage: "arrow.down") { showLatest(using: proxy) }.font(.caption)
            }
            if model.transcript?.olderCursor != nil {
              Button(model.loadingHistory ? "Loading…" : "Load older messages", systemImage: "arrow.up") { takeScrollOwnership(); Task { await model.loadEarlierMessages() } }.font(.caption).disabled(!model.executionOnline || model.loadingHistory)
            }
            if model.selectedConversationID != nil && model.transcript == nil {
              Button("Load conversation") { Task { await model.refreshConversation() } }.buttonStyle(DashboardQuietButtonStyle())
                .disabled(!model.executionOnline)
            }
            if let transcript = model.transcript {
              MobileConversationTranscript(transcript: transcript, disclosureState: model.transcriptStates.state(for: transcript.conversationID)) { activityID in
                try await model.conversationActivityDetail(conversationID: transcript.conversationID, activityID: activityID)
              }
            }
            ForEach(model.currentPending) { interaction in
              PendingInteractionView(model: model, interaction: interaction)
            }
            if model.activeRunID != nil {
              HStack { ProgressView(); Text(model.executionOnline ? "Running on \(model.executionName.lowercased())" : "Workspace connection interrupted · execution stays there").font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
            }
            Color.clear.frame(height: 1).id("latest")
          }.padding(20)
        }.scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .environment(\.conversationTranscriptInteraction, takeScrollOwnership)
        .onScrollPhaseChange { _, phase in
          isUserScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
          if isUserScrolling {
            transcriptOwnsScroll = false
            scrollInteractionRevision += 1
          }
        }
        .onScrollGeometryChange(for: DashboardConversationGeometry.self) { geometry in
          DashboardConversationGeometry(contentHeight: geometry.contentSize.height,
            isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 80,
            viewportHeight: geometry.visibleRect.height)
        } action: { old, new in
          if scrollState.geometryChanged(from: old, to: new, isUserScrolling: isUserScrolling,
              transcriptOwnsScroll: transcriptOwnsScroll, isPrependingHistory: isViewingHistory || model.loadingHistory) {
            followBottom(using: proxy)
          }
        }
        .onChange(of: model.selectedConversationID, initial: true) { _, id in
          scrollInteractionRevision += 1
          isUserScrolling = false
          transcriptOwnsScroll = isViewingHistory
          scrollState.conversationChanged(to: id)
          if isViewingHistory, let id { scrollState.sourceMessagePositioned(in: id) }
          else { contentChanged(using: proxy) }
        }
        .onChange(of: model.transcript?.messages.last?.id) { _, _ in contentChanged(using: proxy) }
        .overlay(alignment: .bottomTrailing) {
          if !scrollState.isNearBottom, model.selectedConversationID != nil, !isViewingHistory {
            Button("Latest reply", systemImage: "arrow.down") { showLatest(using: proxy) }
              .buttonStyle(DashboardQuietButtonStyle()).padding(16)
          }
        }
      }
      if model.canResumeLocalRun {
        HStack {
          Button("Resume saved run") { Task { await model.resumeDeviceRun() } }.buttonStyle(DashboardPrimaryButtonStyle()).disabled(model.sending)
          Button("Stop", role: .destructive) { Task { await model.stopOnDevice() } }.buttonStyle(DashboardQuietButtonStyle())
        }.padding(.horizontal, 18)
      }
      composer
    }
    .navigationDestination(isPresented: $pendingPresented) {
      List(model.allPending) { request in
        Button { Task { await model.selectConversation(request.conversationID); pendingPresented = false } } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(request.title)
            Text(model.state.conversations[request.conversationID]?.title ?? "Conversation").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
          }
        }
      }.mobileNavigationPage("Pending requests")
    }
    .navigationDestination(isPresented: $filesPresented) {
      if let id = model.selectedConversationID { DeviceWorkspaceFiles(model: model, conversationID: id) }
    }
    .navigationDestination(isPresented: $detailsPresented) {
      if let item = model.selectedConversation { ItemManagementSheet(model: model, id: item.id, isNote: false, title: item.title, folderID: item.folderID ?? "") }
    }
    .navigationDestination(isPresented: $settingsPresented) {
      if let id = model.selectedConversationID { SessionSettingsSheet(model: model, id: id) }
    }
    .navigationDestination(isPresented: $referencesPresented) {
      Group {
        List {
          Button("No note reference") { model.referencedNoteID = nil; referencesPresented = false }
          ForEach(model.notes.filter { !model.state.uncachedNoteIDs.contains($0.id) }) { note in
            Button { model.referencedNoteID = note.id; referencesPresented = false } label: {
              VStack(alignment: .leading) { Text(note.title); Text(model.state.isDirty(note.id) ? "Will sync before sending" : "Revision \(note.revision)").font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
            }.disabled(model.state.conflicts[note.id] != nil)
          }
        }.mobileNavigationPage("Reference a note")
      }
    }
  }
  private var isViewingHistory: Bool {
    model.selectedConversationID.flatMap { model.historyPages[$0] } != nil
  }
  private func takeScrollOwnership() {
    transcriptOwnsScroll = true
    scrollInteractionRevision += 1
    scrollState.setNearBottom(false)
  }
  private func contentChanged(using proxy: ScrollViewProxy) {
    guard !isViewingHistory, !isUserScrolling else { return }
    let action = scrollState.contentChanged(conversationID: model.selectedConversationID,
      hasMessages: model.transcript?.messages.isEmpty == false || model.transcript?.activities.isEmpty == false,
      isPrependingHistory: model.loadingHistory)
    if action != .none { followBottom(using: proxy) }
  }
  private func showLatest(using proxy: ScrollViewProxy) {
    model.showLatestMessages()
    transcriptOwnsScroll = false
    scrollInteractionRevision += 1
    scrollState.setNearBottom(true)
    followBottom(using: proxy)
  }
  private func followBottom(using proxy: ScrollViewProxy) {
    let revision = scrollInteractionRevision
    let conversationID = model.selectedConversationID
    Task { @MainActor in
      await Task.yield()
      guard revision == scrollInteractionRevision, conversationID == model.selectedConversationID,
            !isUserScrolling, !isViewingHistory, !model.loadingHistory else { return }
      scrollState.setNearBottom(true)
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) { proxy.scrollTo("latest", anchor: .bottom) }
    }
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let id = model.referencedNoteID, let note = model.state.notes[id] {
        HStack { Label(note.title, glyph: .fileText).font(.caption); Spacer(); Button { model.referencedNoteID = nil } label: { DashboardLucideIcon(glyph: .close, size: 16).frame(width: 44, height: 44) }.accessibilityLabel("Remove note reference") }
      }
      TextField(model.activeRunID == nil ? "Chat…" : "Steer this run…", text: $model.composer, axis: .vertical)
        .lineLimit(2...6).focused($composerFocused).accessibilityIdentifier("chat-composer")
      HStack(spacing: 8) {
        Menu {
          Button("Reference a note", glyph: .fileText) { composerFocused = false; referencesPresented = true }
          if model.selectedExecutionWorkspaceID == "local", model.selectedConversationID != nil {
            Button("Workspace files", glyph: .folder) { composerFocused = false; filesPresented = true }
          }
        } label: { DashboardLucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44) }
          .buttonStyle(DashboardIconButtonStyle()).accessibilityLabel("Add to chat")
        ChatComposerSettings(model: model)
        if model.activeRunID != nil && model.activeProvider?.canStop == true {
          Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }
            .buttonStyle(DashboardIconButtonStyle()).accessibilityLabel("Stop run").disabled(!model.executionOnline)
        }
        if model.activeRunID == nil || model.activeProvider?.canSteer == true {
          Button { Task { await model.send() } } label: {
            Group { if model.sending { ProgressView().tint(.white) } else { DashboardLucideIcon(glyph: .arrowUp, size: 20) } }
              .frame(width: 44, height: 44).foregroundStyle(.white).background(canSend ? DashboardPalette.primary : Color.gray.opacity(0.35), in: Circle())
          }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel(model.activeRunID == nil ? "Send message" : "Steer run")
        }
      }
    }.padding(15).background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.composerRadius, style: .continuous)).padding(.horizontal, 18).padding(.vertical, 12)
  }
  private var canSend: Bool {
    model.executionOnline && model.activeProvider?.available == true && !model.canResumeLocalRun && !model.sending && !model.startingChat && !model.chatSettingsBusy && model.configuringDeviceSessions.isEmpty && !model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      (model.activeRunID == nil || model.activeProvider?.canSteer == true)
  }
}


struct PendingInteractionView: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CompanionModel
  var interaction: CompanionPendingInteraction
  @State private var answers: [String: Set<String>] = [:]
  @State private var freeText: [String: String] = [:]
  @State private var responding = false
  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Label(interaction.title, systemImage: interaction.kind == .approval ? "hand.raised" : "questionmark.bubble").font(.headline)
      if let detail = interaction.detail { Text(detail).font(.subheadline).textSelection(.enabled) }
      if interaction.kind == .approval {
        ForEach(interaction.options) { option in
          Button { respond(.init(optionID: option.id)) } label: {
            VStack(alignment: .leading) { Text(option.label); if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) } }.frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(DashboardQuietButtonStyle())
        }
      } else {
        ForEach(interaction.questions) { question in
          VStack(alignment: .leading, spacing: 8) {
            Text(question.prompt).font(.subheadline.weight(.medium))
            ForEach(question.options) { option in
              Button {
                var selected = answers[question.id] ?? []
                if selected.contains(option.id) { selected.remove(option.id) }
                else if question.allowsMultiple { selected.insert(option.id) }
                else { selected = [option.id] }
                answers[question.id] = selected
                if !question.allowsMultiple { freeText[question.id] = "" }
              } label: { Label(option.label, systemImage: answers[question.id]?.contains(option.id) == true ? "checkmark.circle.fill" : "circle").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).frame(minHeight: 44)
            }
            if question.allowsFreeText {
              TextField("Your answer", text: Binding(get: { freeText[question.id] ?? "" }, set: { freeText[question.id] = $0; if !question.allowsMultiple { answers[question.id] = [] } }), axis: .vertical).dashboardInput()
            }
          }
        }
        Button("Send answers") {
          var result = answers.mapValues { Array($0).sorted() }
          for (id, text) in freeText where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[id, default: []].append(text) }
          respond(.init(answers: result))
        }.buttonStyle(DashboardPrimaryButtonStyle()).disabled(!interaction.questions.allSatisfy { !$0.isRequired || !(answers[$0.id] ?? []).isEmpty || !(freeText[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      }
      Button("Cancel request", role: .cancel) { respond(.init(cancelled: true)) }.font(.caption).frame(minHeight: 44)
      Text(model.selectedExecutionWorkspaceID == "local" ? "This action runs on this device." : "The first valid answer on any authorized device wins.").font(.caption2).foregroundStyle(DashboardPalette.mutedForeground)
    }.disabled(!model.executionOnline || responding).padding(16).background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
  }
  private func respond(_ response: CompanionInteractionResponse) {
    responding = true
    Task { await model.respond(interaction, response: response); responding = false }
  }
}
