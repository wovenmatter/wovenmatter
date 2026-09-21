import SwiftUI
import CompanionClient
import WovenMatterCompanion

struct ChatPane: View {
  @Bindable var model: CompanionModel
  @State private var referencesPresented = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(model.selectedConversation?.title ?? "New chat").font(.headline).lineLimit(1)
          Text(model.online ? (model.activeProvider?.displayName ?? "Choose an agent") : "Offline · saved transcript").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          Button("New chat", systemImage: "square.and.pencil") { model.newChat() }
          if model.activeRunID != nil { Button("Stop this run", systemImage: "stop.fill", role: .destructive) { Task { await model.stop() } }.disabled(!model.online || model.activeProvider?.canStop != true) }
          Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(!model.online)
        } label: { Image(systemName: "ellipsis").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("Conversation actions")
      }.padding(.horizontal, 20).padding(.top, 8)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 22) {
            if let id = model.selectedConversationID, model.historyPages[id] != nil {
              Button("Return to latest messages", systemImage: "arrow.down") { model.showLatestMessages() }.font(.caption)
            }
            if model.transcript?.olderCursor != nil {
              Button(model.loadingHistory ? "Loading…" : "Load older messages", systemImage: "arrow.up") { Task { await model.loadEarlierMessages() } }.font(.caption).disabled(!model.online || model.loadingHistory)
            }
            if model.selectedConversationID == nil {
              VStack(alignment: .leading, spacing: 12) {
                Text("Continue the work from here.").font(.title2.weight(.semibold))
                Text("Your Mac runs the agent. Reference a synced note, start a conversation, and come back to the same session on either device.").foregroundStyle(.secondary)
              }.padding(.vertical, 30)
            } else if model.transcript == nil {
              ContentUnavailableView("Transcript isn’t saved here", systemImage: "bubble.left", description: Text("Connect to your Mac to load this conversation."))
            }
            ForEach(model.transcript?.messages ?? []) { message in MessageView(message: message) }
            ForEach(model.transcript?.activities ?? []) { activity in
              DisclosureGroup {
                Text(activity.detail ?? activity.status).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
              } label: {
                Label(activity.title, systemImage: activity.status == "completed" ? "checkmark.circle.fill" : "circle.dotted").font(.subheadline.weight(.medium))
              }.padding(14).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(model.currentPending) { interaction in
              PendingInteractionView(model: model, interaction: interaction)
            }
            if model.activeRunID != nil {
              HStack { ProgressView(); Text(model.online ? "Running on your Mac" : "Mac connection interrupted · run continues there").font(.caption).foregroundStyle(.secondary) }
            }
            Color.clear.frame(height: 1).id("latest")
          }.padding(20)
        }
        .onChange(of: model.transcript?.messages.last?.content) { _, _ in
          if UIAccessibility.isReduceMotionEnabled { proxy.scrollTo("latest", anchor: .bottom) }
          else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) } }
        }
      }
      composer
    }
    .sheet(isPresented: $referencesPresented) {
      NavigationStack {
        List {
          Button("No note reference") { model.referencedNoteID = nil; referencesPresented = false }
          ForEach(model.notes.filter { !model.state.uncachedNoteIDs.contains($0.id) }) { note in
            Button { model.referencedNoteID = note.id; referencesPresented = false } label: {
              VStack(alignment: .leading) { Text(note.title); Text(model.state.isDirty(note.id) ? "Will sync before sending" : "Revision \(note.revision)").font(.caption).foregroundStyle(.secondary) }
            }.disabled(model.state.conflicts[note.id] != nil)
          }
        }.navigationTitle("Reference a note").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { referencesPresented = false } } }
      }
    }
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let id = model.referencedNoteID, let note = model.state.notes[id] {
        HStack { Label(note.title, systemImage: "doc.text").font(.caption); Spacer(); Button { model.referencedNoteID = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove note reference") }
      }
      TextField(model.activeRunID == nil ? "Message your Mac…" : "Steer this run…", text: $model.composer, axis: .vertical)
        .lineLimit(2...6).accessibilityIdentifier("chat-composer")
        .disabled(!model.online)
      HStack(spacing: 14) {
        Button { referencesPresented = true } label: { Image(systemName: "plus").font(.title2).frame(width: 32, height: 38) }.accessibilityLabel("Reference a note")
        if model.selectedConversationID == nil {
          Menu {
            ForEach(model.providers) { provider in
              Button { model.providerID = provider.id } label: {
                Label(provider.displayName + " · " + provider.routeName + (provider.available ? "" : " · unavailable"), systemImage: model.providerID == provider.id ? "checkmark" : "cpu")
              }.disabled(!provider.available || !provider.canStart)
            }
          } label: {
            HStack(spacing: 5) { Text(model.activeProvider?.displayName ?? "Agent").lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }.font(.subheadline.weight(.medium))
          }.disabled(!model.online || model.providers.isEmpty)
        } else { Text(model.activeProvider?.displayName ?? model.selectedConversation?.runtimeKind ?? "Agent").font(.caption).foregroundStyle(.secondary) }
        Spacer()
        if model.activeRunID != nil && model.activeProvider?.canStop == true {
          Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").frame(width: 38, height: 38) }.accessibilityLabel("Stop run").disabled(!model.online)
        }
        Button { Task { await model.send() } } label: {
          Group { if model.sending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.title3.weight(.semibold)) } }
            .frame(width: 42, height: 42).foregroundStyle(.white).background(canSend ? MobileTheme.green : Color.gray.opacity(0.35), in: Circle())
        }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel(model.activeRunID == nil ? "Send message" : "Steer run")
      }
      if !model.online { Text("Connect to your running Mac to send. Agent messages are never queued offline.").font(.caption2).foregroundStyle(.secondary) }
      else if model.activeRunID != nil && model.activeProvider?.canSteer != true { Text("This agent can’t accept input during this run. You can stop it or wait.").font(.caption2).foregroundStyle(.secondary) }
    }.padding(15).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 22)).padding(.horizontal, 18).padding(.vertical, 12)
  }
  private var canSend: Bool {
    model.online && !model.sending && !model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      (model.activeRunID == nil || model.activeProvider?.canSteer == true)
  }
}

private struct MessageView: View {
  let message: CompanionMessage
  var body: some View {
    VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 8) {
      Text(message.role == "user" ? "You" : message.role == "assistant" ? "Computer" : message.role.capitalized)
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Text(.init(message.content)).font(.body).lineSpacing(4).textSelection(.enabled)
        .padding(message.role == "user" ? 14 : 0)
        .background(message.role == "user" ? MobileTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 16))
    }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
  }
}

struct PendingInteractionView: View {
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
            VStack(alignment: .leading) { Text(option.label); if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(.bordered)
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
              } label: { Label(option.label, systemImage: answers[question.id]?.contains(option.id) == true ? "checkmark.circle.fill" : "circle").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(.vertical, 5)
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
        }.buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(!interaction.questions.allSatisfy { !(answers[$0.id] ?? []).isEmpty || !(freeText[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      }
      Button("Cancel request", role: .cancel) { respond(.init(cancelled: true)) }.font(.caption)
      Text("The first valid answer on either device wins.").font(.caption2).foregroundStyle(.secondary)
    }.disabled(!model.online || responding).padding(16).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 16))
  }
  private func respond(_ response: CompanionInteractionResponse) {
    responding = true
    Task { await model.respond(interaction, response: response); responding = false }
  }
}
