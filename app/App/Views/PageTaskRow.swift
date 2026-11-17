import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// A task on a Page: what it asks for, who it is assigned to, where each of them
/// stands, and what they reported. Assigning picks a real agent in a real place,
/// a bot, or the person; Send starts each agent's or bot's own chat.
struct PageTaskRow: View {
    @Environment(\.wovenTheme) private var theme
    @Bindable var model: ApplicationModel
    @Binding var document: NoteDocument
    @Binding var viewState: CanvasViewState
    let componentID: String
    let pageFolderID: String?
    var onOpenSession: ((String) -> Void)?
    @State private var assigning = false
    @FocusState private var titleFocused: Bool

    private var page: NoteDocument { document.materializedPage() }
    private var item: BoardItem? { page.boardItems?[componentID] }
    private var task: BoardTask { item?.task ?? BoardTask() }
    private var waiting: [BoardTaskAssignee] { task.assignees.filter { $0.state == .assigned && $0.kind != .user } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { setStatus(task.status == .done ? .todo : .done) } label: {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(task.status == .done ? WovenPalette.success : WovenPalette.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.status == .done ? "Reopen task" : "Complete task")
                TextField("Task", text: textBinding, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                    .strikethrough(task.status == .done, color: WovenPalette.mutedForeground)
                    .focused($titleFocused)
                Spacer(minLength: 8)
                statusMenu
                PageComponentMenu(document: $document, viewState: $viewState, componentID: componentID)
            }
            TextField("Add details", text: detailsBinding, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(WovenPalette.mutedForeground)
                .padding(.leading, 23)
                .accessibilityLabel("Task details")
            assigneeRow.padding(.leading, 23)
            if !task.outcome.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Result").font(.system(size: 11, weight: .semibold)).foregroundStyle(WovenPalette.mutedForeground)
                    Text(task.outcome).font(.system(size: 12.5)).textSelection(.enabled)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.palette.workspace))
                .padding(.leading, 23)
            }
            if let added = item?.createdBy, added.kind != .user, let label = added.label, !label.isEmpty {
                Text("Added by \(label)").font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground)
                    .padding(.leading, 23)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(WovenPalette.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border, lineWidth: 1))
        .padding(.vertical, 4)
        .onAppear(perform: focusIfRequested)
        .onChange(of: viewState.revealCardID) { _, _ in focusIfRequested() }
    }

    // MARK: Parts

    private var statusMenu: some View {
        Menu {
            ForEach(BoardTaskStatus.current, id: \.self) { status in
                Button { setStatus(status) } label: {
                    if status == task.status { Label(status.displayName, systemImage: "checkmark") } else { Text(status.displayName) }
                }
            }
        } label: {
            Text(task.status.displayName).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(task.status == .blocked ? WovenPalette.warning : WovenPalette.mutedForeground)
        }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Task status: \(task.status.displayName)")
    }

    private var assigneeRow: some View {
        HStack(spacing: 6) {
            ForEach(task.assignees) { assignee in assigneeChip(assignee) }
            Button { assigning = true } label: {
                Label(task.assignees.isEmpty ? "Assign" : "Add", systemImage: "person.crop.circle.badge.plus")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(WovenQuietButtonStyle())
            .help(task.assignees.isEmpty ? "Assign this task" : "Add someone else to this task")
            .popover(isPresented: $assigning, arrowEdge: .bottom) {
                PageAssignPicker(model: model, pageFolderID: pageFolderID) { assignee in
                    assigning = false
                    apply(.init(action: .assign, id: componentID, assignee: assignee))
                }
            }
            Spacer(minLength: 0)
            if !waiting.isEmpty {
                Button(action: sendWaiting) {
                    Label("Send", systemImage: "paperplane").font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(WovenPrimaryButtonStyle())
                .help(waiting.count == 1 ? "Send this task to \(waiting[0].name)" : "Send this task to \(waiting.count) assignees")
            }
        }
    }

    private func assigneeChip(_ assignee: BoardTaskAssignee) -> some View {
        Menu {
            if let chat = chatLink(assignee) { Button("Open chat") { onOpenSession?(chat) } }
            if assignee.kind == .agent, assignee.state == .assigned { folderMenu(assignee) }
            if assignee.state == .failed { Button("Send again") { setState(assignee, .sending) } }
            if assignee.isActive { Button("Stop") { apply(.init(action: .stopAssignee, id: componentID, assigneeID: assignee.id)) } }
            if assignee.state == .assigned || assignee.state == .failed {
                Button("Unassign", role: .destructive) { apply(.init(action: .stopAssignee, id: componentID, assigneeID: assignee.id)) }
            }
            if let message = assignee.message { Divider(); Text(message) }
            if let by = assignee.assignedBy, by.kind != .user, let label = by.label { Text("Assigned by \(label)") }
        } label: {
            HStack(spacing: 5) {
                chipIcon(assignee)
                Text(chipTitle(assignee)).lineLimit(1)
                Text(stateLabel(assignee)).foregroundStyle(stateColor(assignee))
            }
            .font(.system(size: 11.5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(theme.palette.workspace))
        .help(assignee.message ?? chipTitle(assignee))
        .accessibilityLabel("\(chipTitle(assignee)), \(stateLabel(assignee))")
    }

    @ViewBuilder private func chipIcon(_ assignee: BoardTaskAssignee) -> some View {
        switch assignee.kind {
        case .agent:
            if let runtime = assignee.runtime.flatMap(AgentRuntimeKind.init(rawValue:)) {
                HarnessLogoIcon(logo: HarnessLogo(runtimeKind: runtime), size: 12)
            } else { Image(systemName: "cpu") }
        case .bot: Image(systemName: "bubble.left.and.bubble.right")
        case .user: Image(systemName: "person")
        }
    }

    private func folderMenu(_ assignee: BoardTaskAssignee) -> some View {
        let folders = PageAssignTarget.folders(for: assignee.workspaceID, owner: nil, in: model)
        return Menu("Folder") {
            Button { setFolder(assignee, nil) } label: { check("No folder", assignee.folderID == nil) }
            ForEach(folders) { folder in
                Button { setFolder(assignee, folder.id) } label: { check(folder.name, assignee.folderID == folder.id) }
            }
        }
    }

    private func check(_ title: String, _ on: Bool) -> some View {
        Group { if on { Label(title, systemImage: "checkmark") } else { Text(title) } }
    }

    // MARK: Labels

    private func chipTitle(_ assignee: BoardTaskAssignee) -> String {
        switch assignee.kind {
        case .user: return "Me"
        case .bot: return assignee.name
        case .agent:
            var parts = [assignee.name]
            if let place = assignee.place, !place.isEmpty { parts.append(place) }
            if let folder = assignee.folderID, let name = model.workspaceOverview?.folders.first(where: { $0.id == folder })?.name {
                parts.append(name)
            }
            return parts.joined(separator: " · ")
        }
    }

    private func stateLabel(_ assignee: BoardTaskAssignee) -> String {
        if assignee.kind == .user { return assignee.state == .stopped ? "Unassigned" : "" }
        switch assignee.state {
        case .assigned: return "Not sent"
        case .sending: return "Sending…"
        case .sent:
            if let chat = assignee.conversationID, model.localRunningConversationIDs.contains(chat) { return "Working" }
            return task.status == .done ? "Done" : "Sent"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case .failed: return "Didn't send"
        }
    }

    private func stateColor(_ assignee: BoardTaskAssignee) -> Color {
        switch assignee.state {
        case .failed: WovenPalette.danger
        case .sent: WovenPalette.success
        default: WovenPalette.mutedForeground
        }
    }

    /// An agent's chat, or a bot's thread, once it exists.
    private func chatLink(_ assignee: BoardTaskAssignee) -> String? {
        guard assignee.state != .assigned, assignee.state != .sending else { return nil }
        switch assignee.kind {
        case .agent:
            guard let chat = assignee.conversationID,
                  model.workspaceOverview?.conversations.contains(where: { $0.id == chat }) == true else { return nil }
            return chat
        case .bot:
            guard let machine = assignee.machineID, let bot = assignee.botID else { return nil }
            return BotTarget(machineID: machine, botID: bot, conversationID: assignee.conversationID.flatMap(Int.init)).pageTaskLink
        case .user: return nil
        }
    }

    // MARK: Edits

    private var textBinding: Binding<String> {
        Binding(get: { page.blocks.first { $0.id == componentID }?.plainText ?? "" }, set: { text in
            apply(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID), patch: .init(text: text)))
        })
    }

    private var detailsBinding: Binding<String> {
        Binding(get: { task.details }, set: { text in
            apply(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID), patch: .init(details: text)))
        })
    }

    private func setStatus(_ status: BoardTaskStatus) {
        apply(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID), patch: .init(status: status)))
    }

    private func setState(_ assignee: BoardTaskAssignee, _ state: BoardTaskAssignee.State) {
        var updated = assignee
        updated.state = state; updated.message = nil
        apply(.init(action: .updateAssignee, id: componentID, assignee: updated))
        if state == .sending { Task { _ = await model.flushNoteDrafts() } }
    }

    private func setFolder(_ assignee: BoardTaskAssignee, _ folderID: String?) {
        var updated = assignee
        updated.folderID = folderID
        apply(.init(action: .updateAssignee, id: componentID, assignee: updated))
    }

    private func sendWaiting() {
        for assignee in waiting {
            var updated = assignee
            updated.state = .sending
            apply(.init(action: .updateAssignee, id: componentID, assignee: updated))
        }
        // The background process sends it once the Page is saved.
        Task { _ = await model.flushNoteDrafts() }
    }

    private func apply(_ edit: PageEdit) {
        commitPage(document: $document, state: $viewState) { try $0.applyPageEdit(edit) }
    }

    private func focusIfRequested() {
        guard viewState.revealCardID == componentID else { return }
        DispatchQueue.main.async {
            titleFocused = true
            if viewState.revealCardID == componentID { viewState.revealCardID = nil }
        }
    }
}

/// Someone a task can be assigned to, as the assign picker lists them.
struct PageAssignTarget: Identifiable, Equatable {
    enum Group: Equatable { case me, place(String), bots }
    let id: String
    let group: Group
    let assignee: BoardTaskAssignee
    let ready: Bool
    let detail: String?
    /// The folder owner of the agent's workspace, to start its chat in the Page's folder.
    let folderOwner: String?

    /// Folders a new chat on this workspace may start in.
    @MainActor static func folders(for workspaceID: String?, owner: String?, in model: ApplicationModel) -> [WorkspaceFolderRecord] {
        let folders = model.workspaceOverview?.folders ?? []
        let owners = [owner, workspaceID, model.executionWorkspaceRegistry.first { $0.id == workspaceID }?.folderOwnerID]
            .compactMap { $0 }.map(PairedWorkspaceSidebarModel.canonicalID)
        return folders.filter { folder in folder.executionWorkspaceID.map { owners.contains(PairedWorkspaceSidebarModel.canonicalID($0)) } ?? false }
    }
}

struct PageAssignPicker: View {
    @Bindable var model: ApplicationModel
    let pageFolderID: String?
    var includesPerson = true
    let onPick: (BoardTaskAssignee) -> Void
    @State private var search = ""
    @State private var targets: [PageAssignTarget] = []
    @State private var loaded = false

    private var shown: [PageAssignTarget] {
        let terms = search.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return targets }
        return targets.filter { target in
            let text = [target.assignee.name, target.assignee.place ?? "", target.detail ?? ""].joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    private var groups: [PageAssignTarget.Group] {
        var seen: [PageAssignTarget.Group] = []
        for target in shown where !seen.contains(target.group) { seen.append(target.group) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WovenSearchField(text: $search, prompt: "Search agents and bots")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.title) { group in
                        if group != .me {
                            Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(WovenPalette.mutedForeground)
                                .padding(.top, 8).padding(.horizontal, 6)
                        }
                        ForEach(shown.filter { $0.group == group }) { target in
                            Button { onPick(target.assignee) } label: {
                                HStack(spacing: 8) {
                                    icon(target.assignee)
                                    Text(target.assignee.kind == .user ? "Me" : target.assignee.name)
                                    Spacer()
                                    if let detail = target.detail {
                                        Text(detail).font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(WovenQuietButtonStyle())
                            .disabled(!target.ready)
                        }
                    }
                    if loaded, shown.count <= (includesPerson ? 1 : 0) {
                        Text("Set up agents in Settings, or turn on Bots, to assign tasks to them.")
                            .font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground).padding(6)
                    }
                }
            }
            .frame(maxHeight: 360)
            if let folder = pageFolderID.flatMap({ id in model.workspaceOverview?.folders.first { $0.id == id } }) {
                Divider()
                Text("Agents on the folder's workspace start in \(folder.name). Change the folder on the assignee before sending.")
                    .font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 320)
        .task {
            targets = await model.pageAssignTargets(pageFolderID: pageFolderID).filter { includesPerson || $0.group != .me }
            loaded = true
        }
    }

    @ViewBuilder private func icon(_ assignee: BoardTaskAssignee) -> some View {
        switch assignee.kind {
        case .agent:
            if let runtime = assignee.runtime.flatMap(AgentRuntimeKind.init(rawValue:)) {
                HarnessLogoIcon(logo: HarnessLogo(runtimeKind: runtime), size: 14)
            } else { Image(systemName: "cpu") }
        case .bot: Image(systemName: "bubble.left.and.bubble.right")
        case .user: Image(systemName: "person")
        }
    }
}

extension PageAssignTarget.Group {
    var title: String {
        switch self {
        case .me: "Me"
        case .place(let name): name
        case .bots: "Bots"
        }
    }
}

extension BotTarget {
    private static let pageTaskPrefix = "woven-bot-thread:"
    /// A Page opens a bot's thread through the same callback it opens chats with.
    var pageTaskLink: String {
        Self.pageTaskPrefix + [machineID, botID, conversationID.map(String.init) ?? ""].joined(separator: "\n")
    }
    init?(pageTaskLink: String) {
        guard pageTaskLink.hasPrefix(Self.pageTaskPrefix) else { return nil }
        let parts = pageTaskLink.dropFirst(Self.pageTaskPrefix.count).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(machineID: parts[0], botID: parts[1], conversationID: Int(parts[2]))
    }
}

/// An App with no code yet: describe it, choose an agent, and send. The agent
/// builds it in place and can connect it to live data.
struct AppBuildPrompt: View {
    @Environment(\.wovenTheme) private var theme
    @Bindable var model: ApplicationModel
    let note: WorkspaceNoteRecord
    var onOpenSession: ((String) -> Void)?
    @State private var request = ""
    @State private var agent: BoardTaskAssignee?
    @State private var choosing = false
    @State private var sending = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(WovenPalette.mutedForeground)
            Text("Ask an agent to build this").font(.system(size: 17, weight: .semibold))
            Text("Describe the app. An agent builds it here, and can connect it to live data.")
                .font(.system(size: 12.5)).foregroundStyle(WovenPalette.mutedForeground).multilineTextAlignment(.center)
            TextField("What should this App do?", text: $request, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...8).font(.system(size: 13))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(WovenPalette.background))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border, lineWidth: 1))
            HStack {
                Button { choosing = true } label: {
                    Label(agent.map(label) ?? "Choose an agent", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(WovenQuietButtonStyle())
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    PageAssignPicker(model: model, pageFolderID: note.folderID, includesPerson: false) { picked in
                        agent = picked; choosing = false
                    }
                }
                Spacer()
                Button(action: send) { Label("Send", systemImage: "paperplane") }
                    .buttonStyle(WovenPrimaryButtonStyle())
                    .disabled(sending || agent == nil || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let status {
                Text(status).font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 460)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(_ assignee: BoardTaskAssignee) -> String {
        [assignee.name, assignee.place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func send() {
        guard let agent else { return }
        sending = true; status = "Sending to \(label(agent))…"
        let title = note.title.isEmpty ? "Untitled App" : note.title
        let text = """
        Build the App “\(title)” in Woven Matter (artifact ID \(note.id)).

        \(request.trimmingCharacters(in: .whitespacesAndNewlines))

        Read it with woven_notes_read, then write its HTML with woven_notes_set_html using that revision. If it needs live data, connect a database with woven_notes_link.
        """
        Task {
            defer { sending = false }
            do {
                let chat = try await model.startAgentChat(agent, title: "Build \(title)", text: text)
                status = "Sent to \(label(agent)). It builds the App here."
                request = ""
                onOpenSession?(chat)
            } catch { status = error.localizedDescription }
        }
    }
}
