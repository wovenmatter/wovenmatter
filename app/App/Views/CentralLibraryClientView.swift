import AppKit
import CompanionClient
import SwiftUI
import WovenMatterCompanion
import WovenMatterCore

struct CentralLibraryClientView: View {
    @Bindable var model: CentralLibraryClientModel
    let application: ApplicationModel
    @Environment(\.dashboardTheme) private var theme
    @State private var folderName = ""
    @State private var newFolderPresented = false
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Woven Matter").font(.system(size: 21, weight: .semibold)).padding(.horizontal, 12).padding(.top, 24)
                ForEach(CentralLibraryClientModel.Section.allCases) { section in
                    Button {
                        model.section = section
                        if section == .browser, application.workspaceAssets.tabs.browserIDs.isEmpty {
                            application.workspaceAssets.openBrowser()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            DashboardLucideIcon(glyph: section.icon, size: 16)
                            Text(section.rawValue); Spacer()
                        }.padding(.horizontal, 12).padding(.vertical, 9)
                            .background(model.section == section ? theme.palette.themeWhisper : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Divider().padding(.vertical, 8)
                HStack { Text("Folders").font(.system(size: 11, weight: .semibold)); Spacer()
                    Button { newFolderPresented = true } label: { DashboardLucideIcon(glyph: .plus, size: 13) }
                        .buttonStyle(DashboardIconButtonStyle()).help("New folder")
                }.padding(.horizontal, 12)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.folders) { folder in
                            Button {
                                model.selectedFolderID = folder.id; model.section = .folders
                            } label: {
                                HStack { DashboardLucideIcon(glyph: .folder, size: 14); Text(folder.name).lineLimit(1); Spacer() }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button { Task { await model.refresh() } } label: {
                    HStack(alignment: .top, spacing: 8) {
                        DashboardLucideIcon(glyph: model.online ? .check : .rotate, size: 14)
                        Text(model.status).font(.system(size: 11)).multilineTextAlignment(.leading)
                    }.padding(12)
                }.buttonStyle(.plain).disabled(model.refreshing)
            }.padding(.horizontal, 8).foregroundStyle(DashboardPalette.foreground)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.palette.workspace)
        }
        .environment(\.openDocumentPreview) { url, identity in
            do {
                try application.workspaceAssets.openDocument(url, identity: identity)
                model.section = .browser
            } catch { model.errorMessage = error.localizedDescription }
        }
        .focusedSceneValue(\.workspaceMenuActions, model.preparingTransition ? nil : WorkspaceMenuActions(
            newChat: { Task { await model.selectConversation(nil) } },
            newNote: { Task { await model.createNote() } },
            newBrowserTab: {
                if application.workspaceAssets.openBrowser() != nil { model.section = .browser }
            },
            refresh: { Task { await model.refresh() } }
        ))
        .navigationSplitViewStyle(.balanced)
        .disabled(model.preparingTransition)
        .task {
            await model.initialize()
            await model.analytics.openInterface()
            await model.configureUpdateAnalytics(application.analytics)
            await model.run()
        }
        .onChange(of: application.workspaceAssets.tabs.selected) { _, tab in
            if case .browser = tab { model.section = .browser }
        }
        .onChange(of: application.workspaceAssets.browserPresentationRevision) { _, _ in model.section = .browser }
        .onChange(of: application.workspaceAssets.tabs.isPresented) { _, presented in
            if !presented, model.section == .browser { model.section = .chats }
        }
        .alert("Woven Matter", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("New folder", isPresented: $newFolderPresented) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = "" }
            Button("Create") { let name = folderName; folderName = ""; Task { await model.createFolder(name) } }
        }
    }
    @ViewBuilder private var detail: some View {
        switch model.section {
        case .home: home
        case .folders: folderContents
        case .notes: notes
        case .chats: chats
        case .library: LibraryClientLibraryPane(model: model)
        case .calendar: LibraryClientCalendarPane(model: model)
        case .browser:
            if application.workspaceAssets.tabs.tabs.isEmpty {
                ContentUnavailableView("Browser unavailable", systemImage: "globe",
                    description: Text(application.workspaceAssets.notice ?? "Open a browser tab to browse alongside your work."))
            } else {
                DashboardAssetPane(model: application, assets: application.workspaceAssets,
                    compact: true, noteOnLeft: .constant(false), focused: .constant(false),
                    reservesLeadingRailControlSpace: false, reservesTrailingRailControlSpace: false,
                    newlyCreatedNoteID: nil, onNewNoteFocusHandled: { _ in }, onBack: { model.section = .chats })
            }
        case .trash: LibraryClientTrashPane(model: model)
        case .settings: CentralLibraryClientSettings(model: model, application: application)
        }
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Home").font(.system(size: 26, weight: .semibold))
                HStack(spacing: 12) {
                    Button("New chat") { Task { await model.selectConversation(nil) } }.buttonStyle(DashboardPrimaryButtonStyle())
                    Button("New note") { Task { await model.createNote() } }.buttonStyle(DashboardQuietButtonStyle())
                }
                if !model.state.conflicts.isEmpty {
                    Text("Saved conflicts").font(.headline)
                    ForEach(model.state.conflicts.keys.sorted(), id: \.self) { id in
                        if let conflict = model.state.conflicts[id] {
                            HStack {
                                VStack(alignment: .leading) { Text(conflict.local.title); Text(conflict.reason).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
                                Spacer()
                                Button("Keep as copy") { Task { await model.preserveConflict(id) } }.buttonStyle(DashboardQuietButtonStyle())
                            }
                        }
                    }
                }
                if !model.pendingLaunches.isEmpty || !model.uncertainCommands.isEmpty {
                    Text("Unconfirmed requests").font(.headline)
                    ForEach(model.pendingLaunches) { launch in
                        HStack { Text(launch.initialSend.text ?? "New conversation").lineLimit(2); Spacer()
                            Button("Check and continue") { Task { await model.continueLaunch(launch) } }.disabled(model.sending)
                        }
                    }
                    ForEach(model.uncertainCommands) { command in
                        HStack { Text(command.command.text ?? command.command.kind.rawValue).lineLimit(2); Spacer()
                            Button("Check and retry") { Task { await model.retryCommand(command.command) } }.disabled(!model.canControl(workspaceID: command.command.workspaceID))
                        }
                    }
                }
                Text("Recent notes").font(.headline)
                ForEach(model.notes.prefix(8)) { note in noteRow(note) }
                Text("Recent chats").font(.headline)
                ForEach(model.conversations.prefix(8)) { conversation in conversationRow(conversation) }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.never)
    }
    private var folderContents: some View {
        VStack(spacing: 0) {
            LibraryClientPaneHeader(title: model.selectedFolderID.flatMap { model.state.folders[$0]?.name } ?? "Folders") {
                Button("New folder") { newFolderPresented = true }
                Button("New note") { Task { await model.createNote() } }
            }
            List {
                if model.selectedFolderID == nil {
                    ForEach(model.folders) { folder in
                        Button { model.selectedFolderID = folder.id } label: {
                            HStack { DashboardLucideIcon(glyph: .folder, size: 16); Text(folder.name); Spacer() }
                        }.buttonStyle(.plain)
                    }
                } else {
                    Button("All folders") { model.selectedFolderID = nil }
                    ForEach(model.notes.filter { $0.folderID == model.selectedFolderID }) { note in noteRow(note) }
                    ForEach(model.conversations.filter { $0.folderID == model.selectedFolderID }) { conversation in conversationRow(conversation) }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }
    private var notes: some View {
        HSplitView {
            VStack(spacing: 12) {
                HStack { Text("Notes").font(.headline); Spacer()
                    Menu { ForEach(NoteArtifactKind.allCases, id: \.self) { kind in Button(kind.displayName) { Task { await model.createNote(kind: kind) } } } } label: { DashboardLucideIcon(glyph: .plus, size: 15) }.menuStyle(.borderlessButton).frame(width: 28)
                }
                DashboardSearchField(text: $search, prompt: "Search notes")
                List(model.notes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { note in noteRow(note) }
                    .listStyle(.plain).scrollContentBackground(.hidden)
            }.padding(16).frame(minWidth: 190, idealWidth: 250, maxWidth: 350)
            if let note = model.selectedNote {
                LibraryClientNotePane(model: model, note: note).id(note.id).frame(minWidth: 360)
            } else { ContentUnavailableView("Select a note", systemImage: "doc.text", description: Text("Your downloaded notes are available offline.")) }
        }
    }
    private var chats: some View {
        HSplitView {
            VStack(spacing: 12) {
                HStack { Text("Chats").font(.headline); Spacer(); Button { Task { await model.selectConversation(nil) } } label: { DashboardLucideIcon(glyph: .plus, size: 15) }.buttonStyle(DashboardIconButtonStyle()).help("New chat") }
                List(model.conversations) { conversation in conversationRow(conversation) }.listStyle(.plain).scrollContentBackground(.hidden)
            }.padding(16).frame(minWidth: 190, idealWidth: 250, maxWidth: 350)
            LibraryClientChatPane(model: model).frame(minWidth: 360)
        }
    }
    private func noteRow(_ note: CompanionNote) -> some View {
        Button { Task { await model.selectNote(note.id) } } label: {
            HStack { DashboardLucideIcon(glyph: .fileText, size: 15); Text(note.title.isEmpty ? "Untitled note" : note.title).lineLimit(1); Spacer()
                if model.state.isDirty(note.id) { Image(systemName: "circle.fill").font(.system(size: 5)).accessibilityLabel("Changes saved locally") }
            }.padding(.vertical, 6)
        }.buttonStyle(.plain)
    }
    private func conversationRow(_ conversation: CompanionConversation) -> some View {
        Button { Task { await model.selectConversation(conversation.id) } } label: {
            HStack { DashboardLucideIcon(glyph: .messageSquare, size: 15)
                VStack(alignment: .leading, spacing: 3) { Text(conversation.title).lineLimit(1); Text(conversation.preview).font(.caption).foregroundStyle(DashboardPalette.mutedForeground).lineLimit(1) }
                Spacer(); if conversation.activeRunID != nil { ProgressView().controlSize(.mini) }
            }.padding(.vertical, 5)
        }.buttonStyle(.plain)

    }
}

struct LibraryClientPaneHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack { Text(title).font(.system(size: 21, weight: .semibold)).lineLimit(1); Spacer(); actions() }
            .buttonStyle(DashboardQuietButtonStyle()).padding(22)
    }
}

struct LibraryClientNotePane: View {
    @Bindable var model: CentralLibraryClientModel
    let note: CompanionNote
    @State private var editor = DashboardNoteEditorController()
    @State private var cache = DashboardNoteDocumentCache()
    @State private var details = false
    @State private var canvasViewState = DashboardCanvasViewState()
    private var source: CompanionNote { model.draftNotes[note.id] ?? model.state.notes[note.id] ?? note }
    private var document: Binding<NoteDocument> {
        Binding(get: { cache.value(noteID: note.id, source: source.content) }, set: { document in
            do { model.editNote(source, content: try cache.encode(document, noteID: note.id)) }
            catch { model.errorMessage = error.localizedDescription }
        })
    }
    private var hasLinkedData: Bool {
        document.wrappedValue.databaseLink != nil || document.wrappedValue.blocks.contains {
            if case .table(let table) = $0 { return table.databaseLink != nil }; return false
        }
    }
    @ViewBuilder private var linkedPreview: some View {
        let value = document.wrappedValue
        if value.kind == .html {
            LibraryClientLinkedPreview(model: model, note: source, tableID: nil, html: value.html)
        } else if value.kind == .spreadsheet, value.databaseLink != nil {
            LibraryClientLinkedPreview(model: model, note: source, tableID: nil, html: nil)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(value.blocks, id: \.id) { block in
                        if case .table(let table) = block, table.databaseLink != nil || value.databaseLink != nil {
                            LibraryClientLinkedPreview(model: model, note: source, tableID: table.id, html: nil)
                        } else { Text(block.plainText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.padding(22)
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Untitled note", text: Binding(get: { source.title }, set: { model.editNote(source, title: $0) }))
                    .textFieldStyle(.plain).font(.system(size: 21, weight: .semibold))
                Spacer()
                if document.wrappedValue.kind == .canvas,
                   cache.isEditable(noteID: note.id, source: source.content),
                   !model.state.uncachedNoteIDs.contains(note.id), !hasLinkedData {
                    DashboardCanvasControls(document: document, viewState: $canvasViewState)
                }
                Text(model.state.isDirty(note.id) ? "Saved on this Mac" : "Synchronized").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                Button { details = true } label: { Image(systemName: "ellipsis") }.buttonStyle(DashboardIconButtonStyle()).help("Note details")
            }.padding(22)
            if model.state.uncachedNoteIDs.contains(note.id) {
                ContentUnavailableView("Not downloaded", systemImage: "arrow.down.circle", description: Text("Reconnect to the central database to download this note."))
            } else if !cache.isEditable(noteID: note.id, source: source.content) {
                Text("This document uses a newer format. Update Woven Matter to edit it.").padding()
            } else if hasLinkedData {
                linkedPreview
            } else {
                switch document.wrappedValue.kind {
                case .note:
                    HStack(spacing: 12) {
                        Button("Bold") { editor.toggleBold() }; Button("Italic") { editor.toggleItalic() }; Button("Underline") { editor.toggleUnderline() }
                        Button("Insert table") { editor.insertTable() }; Spacer()
                    }.buttonStyle(DashboardQuietButtonStyle()).padding(.horizontal, 22)
                    DashboardNoteEditor(document: document, controller: editor).padding(.horizontal, 22)
                case .canvas: DashboardCanvasEditor(document: document, viewState: $canvasViewState)
                case .spreadsheet: DashboardSpreadsheetEditor(document: document)
                case .html:
                    VSplitView {
                        TextEditor(text: Binding(get: { document.wrappedValue.html }, set: { var value = document.wrappedValue; value.html = $0; document.wrappedValue = value }))
                            .font(.system(size: 12, design: .monospaced)).frame(minHeight: 150)
                        DashboardHTMLArtifactView(html: document.wrappedValue.html, linkedDataJSON: nil).frame(minHeight: 150)
                    }.padding(.horizontal, 22)
                }
            }
        }
        .sheet(isPresented: $details) {
            LibraryClientItemManagementSheet(model: model, id: note.id, isNote: true, title: source.title, folderID: source.folderID ?? "").frame(minWidth: 440, minHeight: 430)
        }
    }
}

private struct LibraryClientChatPane: View {
    @Bindable var model: CentralLibraryClientModel
    @State private var settings = false
    @State private var details = false
    var body: some View {
        VStack(spacing: 0) {
            LibraryClientPaneHeader(title: model.selectedConversation?.title ?? "New chat") {
                if model.selectedConversationID != nil {
                    Button("Session settings") { settings = true }
                    Button { details = true } label: { Image(systemName: "ellipsis") }.help("Conversation details")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.transcript?.olderCursor != nil { Button("Load older messages") { Task { await model.olderMessages() } }.disabled(!model.canControl) }
                    ForEach(model.transcript?.messages ?? []) { message in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(message.role == "user" ? "You" : message.role.capitalized).font(.system(size: 11, weight: .semibold)).foregroundStyle(DashboardPalette.mutedForeground)
                            ConversationMarkdown(document: .init(message.content), isStreaming: message.status == "streaming").textSelection(.enabled)
                            if message.role == "assistant", message.status != "streaming" {
                                ConversationFilePreviews(content: message.content, messageID: message.id) { source in
                                    let id = WorkspaceLibraryItem.identifier(messageID: message.id, source: source)
                                    return try await model.exportFile(.libraryFile(id: id))
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.transcript?.activities ?? []) { activity in
                        DisclosureGroup(activity.title) { Text(activity.detail ?? activity.status).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    }
                    ForEach(model.currentPending) { interaction in LibraryClientInteraction(model: model, interaction: interaction) }
                }.padding(24)
            }.scrollIndicators(.never)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if model.selectedConversationID == nil {
                    Picker("Execution workspace", selection: Binding(get: { model.selectedExecutionWorkspaceID }, set: { id in Task { await model.selectExecutionWorkspace(id) } })) {
                        Text("Central database").tag("central")
                        ForEach(model.executionWorkspaces) { workspace in Text(workspace.name).tag(workspace.id) }
                    }
                    Picker("Agent workspace", selection: $model.selectedProviderID) {
                        Text("Select agent").tag("")
                        ForEach(model.providers) { provider in Text(provider.displayName + " · " + provider.routeName).tag(provider.id).disabled(!provider.available || !provider.canStart) }
                    }.labelsHidden()
                } else if let provider = model.activeProvider { Text(provider.displayName + " · " + provider.routeName).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
                if model.canAttachNote {
                    Picker("Note context", selection: $model.contextNoteID) {
                        Text("No attached note").tag("")
                        ForEach(model.notes) { note in Text(note.title).tag(note.id).disabled(!note.contentIncluded || model.state.conflicts[note.id] != nil) }
                    }.disabled(model.activeRunID != nil)
                }
                if let id = model.selectedConversationID { LibraryClientGoalControls(model: model, id: id).id(id) }
                TextEditor(text: $model.composer).font(.system(size: 14)).frame(minHeight: 64, maxHeight: 130).scrollContentBackground(.hidden)
                HStack {
                    if !model.canControl { Text("Draft saved on this Mac").font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
                    Spacer()
                    if model.activeRunID != nil { Button("Stop") { Task { await model.stop() } }.buttonStyle(DashboardQuietButtonStyle()).disabled(!model.canControl) }
                    Button(model.activeRunID == nil ? "Send" : "Steer") { Task { await model.send() } }
                        .buttonStyle(DashboardPrimaryButtonStyle()).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canControl || model.sending || model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.activeRunID != nil && model.activeProvider?.canSteer != true))
                }
            }.padding(20)
        }
        .sheet(isPresented: $settings) {
            if let id = model.selectedConversationID { LibraryClientSessionSettingsSheet(model: model, id: id).frame(minWidth: 500, minHeight: 440) }
        }
        .sheet(isPresented: $details) {
            if let conversation = model.selectedConversation {
                LibraryClientItemManagementSheet(model: model, id: conversation.id, isNote: false, title: conversation.title, folderID: conversation.folderID ?? "").frame(minWidth: 440, minHeight: 430)
            }
        }
    }
}

private struct LibraryClientLinkedPreview: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: CentralLibraryClientModel
    let note: CompanionNote
    let tableID: String?
    let html: String?
    @State private var data: CompanionLinkedData?
    @State private var error: String?
    @State private var loading = false
    private var requestKey: String { "\(note.id):\(note.revision):\(tableID ?? "document"):\(model.online)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DashboardLucideIcon(glyph: .database, size: 14)
                Text("Live linked data · read only").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                else { Button("Refresh") { Task { await load() } }.disabled(!model.online) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
            if let html { DashboardHTMLArtifactView(html: html, linkedDataJSON: data?.json).frame(minHeight: 250) }
            else if let data {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        row(data.columns, header: true)
                        ForEach(Array(data.rows.enumerated()), id: \.offset) { _, cells in row(cells, header: false) }
                    }
                }.accessibilityLabel("Live linked table, read only")
            }
        }.padding(22).task(id: requestKey) { await load() }
    }
    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, text in
                Text(text).font(.system(size: 13, weight: header ? .semibold : .regular)).textSelection(.enabled)
                    .frame(width: 150, alignment: .leading).padding(8)
                    .background(header ? theme.palette.themeWhisper : .clear)
                    .overlay(Rectangle().stroke(theme.palette.border, lineWidth: 0.5))
            }
        }
    }
    private func load() async {
        let key = requestKey
        data = nil; error = nil; loading = true
        defer { if requestKey == key { loading = false } }
        guard model.online else { error = "Connect to your central database to preview this linked data."; return }
        do {
            let result = try await model.linkedData(note: note, tableID: tableID)
            guard !Task.isCancelled, requestKey == key else { return }
            data = result
        } catch is CancellationError {} catch { if requestKey == key { self.error = error.localizedDescription } }
    }
}

private struct LibraryClientGoalControls: View {
    @Bindable var model: CentralLibraryClientModel
    let id: String
    @State private var goal: WorkspaceGoal?
    var body: some View {
        ConversationGoalControls(goal: goal, sessionID: id) { mutation in
            guard await model.perform(.goal(id: id, mutation: mutation)) else { throw WorkspaceToolError.invalid(model.errorMessage ?? "The execution owner did not confirm this goal change.") }
            await load()
        }.disabled(!model.canControl)
        .task(id: id) {
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func load() async {
        if case .session(let settings) = try? await model.workspace(.session(id: id)), !Task.isCancelled { goal = settings.goal }
    }
}
