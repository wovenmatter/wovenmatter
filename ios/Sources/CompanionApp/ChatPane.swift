import SwiftUI
import CompanionClient
import WovenMatterCompanion

struct ChatPane: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CompanionModel
  @State private var referencesPresented = false
  @State private var detailsPresented = false
  @State private var settingsPresented = false
  @State private var filesPresented = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(model.selectedConversation?.title ?? "New chat").font(.headline).lineLimit(1)
          Text(model.executionStatus).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
        }
        Spacer()
        Menu {
          if model.selectedConversationID != nil {
            if model.selectedExecutionWorkspaceID == "local" {
              Button("Workspace files") { filesPresented = true }
            }
            Button("Details and export") { detailsPresented = true }
            Button("Session settings and tools") { settingsPresented = true }.disabled(!model.executionOnline)
          }
          Button("New chat", glyph: .squarePen) { model.newChat() }
          if model.activeRunID != nil { Button("Stop this run", systemImage: "stop.fill", role: .destructive) { Task { await model.stop() } }.disabled(!model.executionOnline || model.activeProvider?.canStop != true) }
          Button("Refresh", glyph: .rotate) { Task { await model.refreshConversation() } }
        } label: { Image(systemName: "ellipsis").font(.title2).frame(width: 44, height: 44) }.buttonStyle(DashboardIconButtonStyle()).accessibilityLabel("Conversation actions")
      }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 22) {
            if let id = model.selectedConversationID, model.historyPages[id] != nil {
              Button("Return to latest messages", systemImage: "arrow.down") { model.showLatestMessages() }.font(.caption)
            }
            if model.transcript?.olderCursor != nil {
              Button(model.loadingHistory ? "Loading…" : "Load older messages", systemImage: "arrow.up") { Task { await model.loadEarlierMessages() } }.font(.caption).disabled(!model.executionOnline || model.loadingHistory)
            }
            if model.selectedConversationID == nil {
              VStack(alignment: .leading, spacing: 12) {
                Text("Continue the work from here.").font(.title2.weight(.semibold))
                Text("Choose a workspace and inference connection. Pi Durable can run on this device, or you can control agents in another workspace over Tailscale.").foregroundStyle(DashboardPalette.mutedForeground)
              }.padding(.vertical, 30)
            } else if model.transcript == nil {
              ContentUnavailableView { Label("Transcript isn’t saved here", glyph: .messageSquare) } description: { Text("Connect to the conversation’s execution workspace or your central library to load its history.") }
            }
            ForEach(model.transcript?.messages ?? []) { message in MessageView(message: message) }
            ForEach(model.transcript?.activities ?? []) { activity in
              DisclosureGroup {
                Text(activity.detail ?? activity.status).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
              } label: {
                Label(activity.title, systemImage: activity.status == "completed" ? "checkmark.circle.fill" : "circle.dotted").font(.subheadline.weight(.medium))
              }.padding(14).background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
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
        .onChange(of: model.transcript?.messages.last?.content) { _, _ in
          if UIAccessibility.isReduceMotionEnabled { proxy.scrollTo("latest", anchor: .bottom) }
          else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) } }
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
    .sheet(isPresented: $filesPresented) {
      if let id = model.selectedConversationID { DeviceWorkspaceFiles(model: model, conversationID: id) }
    }
    .sheet(isPresented: $detailsPresented) {
      if let item = model.selectedConversation { ItemManagementSheet(model: model, id: item.id, isNote: false, title: item.title, folderID: item.folderID ?? "") }
    }
    .sheet(isPresented: $settingsPresented) {
      if let id = model.selectedConversationID { SessionSettingsSheet(model: model, id: id) }
    }
    .sheet(isPresented: $referencesPresented) {
      NavigationStack {
        List {
          Button("No note reference") { model.referencedNoteID = nil; referencesPresented = false }
          ForEach(model.notes.filter { !model.state.uncachedNoteIDs.contains($0.id) }) { note in
            Button { model.referencedNoteID = note.id; referencesPresented = false } label: {
              VStack(alignment: .leading) { Text(note.title); Text(model.state.isDirty(note.id) ? "Will sync before sending" : "Revision \(note.revision)").font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
            }.disabled(model.state.conflicts[note.id] != nil)
          }
        }.navigationTitle("Reference a note").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { referencesPresented = false } } }
      }
    }
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let id = model.referencedNoteID, let note = model.state.notes[id] {
        HStack { Label(note.title, glyph: .fileText).font(.caption); Spacer(); Button { model.referencedNoteID = nil } label: { DashboardLucideIcon(glyph: .close, size: 16).frame(width: 44, height: 44) }.accessibilityLabel("Remove note reference") }
      }
      TextField(model.activeRunID == nil ? "Message…" : "Steer this run…", text: $model.composer, axis: .vertical)
        .lineLimit(2...6).accessibilityIdentifier("chat-composer")
      HStack {
        ExecutionWorkspaceMenu(model: model)
        Spacer()
        if model.selectedExecutionWorkspaceID == "local" {
          Menu {
            ForEach(model.inferenceConnections) { connection in
              Button(connection.name + " · " + connection.modelID) { model.selectInferenceConnection(connection.id) }
            }
            Button("Manage inference connections") { model.executionSettingsPresented = true }
          } label: { Text(model.selectedInferenceConnection?.modelID ?? "Choose model").font(.caption).lineLimit(1).frame(minHeight: 44) }
            .disabled(model.selectedConversationID != nil)
        }
      }
      HStack(spacing: 14) {
        Button { referencesPresented = true } label: { DashboardLucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44) }.buttonStyle(DashboardIconButtonStyle()).accessibilityLabel("Reference a note")
        if model.selectedConversationID == nil {
          Menu {
            ForEach(model.availableExecutionProviders) { provider in
              Button { model.providerID = provider.id } label: {
                Label {
                  Text(provider.displayName + " · " + provider.routeName + (provider.available ? "" : " · unavailable"))
                } icon: {
                  if model.providerID == provider.id { Image(DashboardLucideGlyph.check.rawValue) }
                  else { MobileAgentIcon(runtimeKind: provider.runtimeKind, size: 20) }
                }
              }.disabled(!provider.available || !provider.canStart)
            }
          } label: {
            HStack(spacing: 6) {
              MobileAgentIcon(runtimeKind: model.activeProvider?.runtimeKind, size: 20)
              Text(model.activeProvider?.displayName ?? "Agent").lineLimit(1)
              DashboardLucideIcon(glyph: .chevronDown, size: 14)
            }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
          }.disabled(!model.executionOnline || model.availableExecutionProviders.isEmpty)
        } else {
          HStack(spacing: 6) {
            MobileAgentIcon(runtimeKind: model.activeProvider?.runtimeKind ?? model.selectedConversation?.runtimeKind, size: 20)
            Text(model.activeProvider?.displayName ?? model.selectedConversation?.runtimeKind ?? "Agent").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
          }
        }
        Spacer()
        if model.activeRunID != nil && model.activeProvider?.canStop == true {
          Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }.buttonStyle(DashboardIconButtonStyle()).accessibilityLabel("Stop run").disabled(!model.executionOnline)
        }
        Button { Task { await model.send() } } label: {
          Group { if model.sending { ProgressView().tint(.white) } else { DashboardLucideIcon(glyph: .arrowUp, size: 20) } }
            .frame(width: 44, height: 44).foregroundStyle(.white).background(canSend ? DashboardPalette.primary : Color.gray.opacity(0.35), in: Circle())
        }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel(model.activeRunID == nil ? "Send message" : "Steer run")
      }
      if let help = model.composerHelp { Text(help).font(.caption2).foregroundStyle(DashboardPalette.mutedForeground) }
    }.padding(15).background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.composerRadius, style: .continuous)).padding(.horizontal, 18).padding(.vertical, 12)
  }
  private var canSend: Bool {
    model.executionOnline && model.activeProvider?.available == true && !model.canResumeLocalRun && !model.sending && !model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      (model.activeRunID == nil || model.activeProvider?.canSteer == true)
  }
}

private struct MessageView: View {
  @Environment(\.dashboardTheme) private var theme
  let message: CompanionMessage
  var body: some View {
    VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 8) {
      Text(message.role == "user" ? "You" : message.role == "assistant" ? "Assistant" : message.role.capitalized)
        .font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.mutedForeground)
      Text(.init(message.content)).tint(DashboardPalette.success).font(.body).lineSpacing(4).textSelection(.enabled)
        .padding(message.role == "user" ? 14 : 0)
        .background(message.role == "user" ? theme.palette.themeWhisper : .clear, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
    }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
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
              TextField("Your answer", text: Binding(get: { freeText[question.id] ?? "" }, set: { freeText[question.id] = $0; if !question.allowsMultiple { answers[question.id] = [] } }), axis: .vertical).textFieldStyle(.roundedBorder)
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
