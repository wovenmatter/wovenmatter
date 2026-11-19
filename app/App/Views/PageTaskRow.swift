import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// A task on a Page is one line: a title, optional instructions, and who it
/// is assigned to. Assigning never sends; Send starts each agent's or bot's own
/// chat. Whoever works on it sets its status, and writes back what they need or
/// what they did below it.
struct PageTaskRow: View {
    @Environment(\.wovenTheme) private var theme
    @Bindable var model: ApplicationModel
    @Binding var document: NoteDocument
    @Binding var viewState: CanvasViewState
    let componentID: String
    let pageFolderID: String?
    var onOpenSession: ((String) -> Void)?
    @FocusState private var focus: Field?
    enum Field { case title, instructions }

    private var item: BoardItem? { document.boardItems?[componentID] }
    private var task: BoardTask { item?.task ?? BoardTask() }
    private var assignees: [BoardTaskAssignee] { task.assignees }
    /// Agents and bots that are assigned but not sent yet.
    private var waiting: [BoardTaskAssignee] { assignees.filter { $0.state == .assigned && $0.kind != .user } }
    private var assignedToMe: Bool { assignees.contains { $0.kind == .user && $0.state != .stopped } }
    private var selected: Bool { viewState.selected.first == componentID }
    private var showsInstructions: Bool { focus != nil || selected || !task.details.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon
                TextField("Task", text: textBinding, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                    .strikethrough(task.status == .done, color: WovenPalette.mutedForeground)
                    .focused($focus, equals: .title)
                    .onSubmit { focus = .instructions }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                statusLabel
                PageAssignMenu(model: model, pageFolderID: pageFolderID, assignees: assignees,
                               chatLink: chatLink, onAssign: assign, onChange: change, onRemove: remove,
                               onOpenSession: onOpenSession)
                if !waiting.isEmpty {
                    Button(action: sendWaiting) {
                        Label("Send", systemImage: "paperplane").font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(WovenPrimaryButtonStyle())
                    .fixedSize()
                    .help(waiting.count == 1 ? "Send this task to \(waiting[0].name)" : "Send this task to \(waiting.count) assignees")
                }
                PageComponentMenu(document: $document, viewState: $viewState, componentID: componentID)
            }
            if showsInstructions {
                TextField("Instructions (optional)", text: detailsBinding, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(WovenPalette.mutedForeground)
                    .focused($focus, equals: .instructions)
                    .padding(.leading, 23)
                    .accessibilityLabel("Task instructions")
            }
            if !task.outcome.isEmpty {
                Text(task.outcome)
                    .font(.system(size: 12.5))
                    .foregroundStyle(task.status == .blocked ? WovenPalette.warning : WovenPalette.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23).padding(.top, 2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? theme.palette.workspace : Color.clear))
        .onAppear(perform: focusIfRequested)
        .onChange(of: viewState.revealCardID) { _, _ in focusIfRequested() }
    }

    // MARK: Status

    /// Shows where the task stands. It is set by whoever it is assigned to,
    /// so it is never a control here.
    private var statusIcon: some View {
        let (name, color): (String, Color) = switch task.status {
        case .done: ("checkmark.circle.fill", WovenPalette.success)
        case .doing: ("circle.lefthalf.filled", WovenPalette.primary)
        case .blocked: ("exclamationmark.circle.fill", WovenPalette.warning)
        default: ("circle", WovenPalette.mutedForeground)
        }
        return Image(systemName: name).font(.system(size: 15)).foregroundStyle(color)
            .accessibilityLabel(task.status.displayName)
    }

    /// Sending problems first, then the status the assignee set. When the task
    /// is assigned to the person, they set it here.
    @ViewBuilder private var statusLabel: some View {
        if let failed = assignees.first(where: { $0.state == .failed }) {
            Text("Didn't send").font(.system(size: 11.5, weight: .medium)).foregroundStyle(WovenPalette.danger)
                .fixedSize().help(failed.message ?? "The task could not be sent to \(failed.name).")
        } else if assignees.contains(where: { $0.state == .sending || $0.state == .stopping }) {
            Text(assignees.contains { $0.state == .sending } ? "Sending…" : "Stopping…")
                .font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground).fixedSize()
        } else if assignedToMe {
            Menu {
                ForEach([BoardTaskStatus.todo, .doing, .done], id: \.self) { status in
                    Button { setStatus(status) } label: {
                        if status == task.status { Label(status.displayName, systemImage: "checkmark") } else { Text(status.displayName) }
                    }
                }
            } label: { statusText }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Task status: \(task.status.displayName)")
        } else if task.status != .todo || assignees.contains(where: { $0.state == .sent }) {
            statusText.fixedSize()
        }
    }

    private var statusText: some View {
        let color: Color = switch task.status {
        case .done: WovenPalette.success
        case .blocked: WovenPalette.warning
        default: WovenPalette.mutedForeground
        }
        let sentOnly = task.status == .todo && !assignedToMe
        return Text(sentOnly ? "Sent" : task.status.displayName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
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
        Binding(get: { document.blocks.first { $0.id == componentID }?.plainText ?? "" }, set: { text in
            apply(.init(action: .update, id: componentID, expectedRevision: document.boardItemRevision(for: componentID), patch: .init(text: text)))
        })
    }

    private var detailsBinding: Binding<String> {
        Binding(get: { task.details }, set: { text in
            apply(.init(action: .update, id: componentID, expectedRevision: document.boardItemRevision(for: componentID), patch: .init(details: text)))
        })
    }

    private func setStatus(_ status: BoardTaskStatus) {
        apply(.init(action: .update, id: componentID, expectedRevision: document.boardItemRevision(for: componentID), patch: .init(status: status)))
    }

    private func assign(_ assignee: BoardTaskAssignee) { apply(.init(action: .assign, id: componentID, assignee: assignee)) }

    private func change(_ assignee: BoardTaskAssignee) {
        apply(.init(action: .updateAssignee, id: componentID, assignee: assignee))
        // The background process sends or stops it once the Page is saved.
        if assignee.state == .sending { Task { _ = await model.flushNoteDrafts() } }
    }

    /// Unassigns someone not sent yet, or stops someone working on it.
    private func remove(_ assignee: BoardTaskAssignee) {
        apply(.init(action: .stopAssignee, id: componentID, assigneeID: assignee.id))
        if assignee.isActive { Task { _ = await model.flushNoteDrafts() } }
    }

    private func sendWaiting() {
        for assignee in waiting {
            var updated = assignee
            updated.state = .sending
            apply(.init(action: .updateAssignee, id: componentID, assignee: updated))
        }
        Task { _ = await model.flushNoteDrafts() }
    }

    private func apply(_ edit: PageEdit) {
        commitPage(document: $document, state: $viewState) { try $0.applyPageEdit(edit) }
    }

    private func focusIfRequested() {
        guard viewState.revealCardID == componentID else { return }
        DispatchQueue.main.async {
            focus = .title
            if viewState.revealCardID == componentID { viewState.revealCardID = nil }
        }
    }
}

/// The task's Assign dropdown: who it is assigned to, with what each can do,
/// then everyone it can be assigned to, by workspace and then bots.
struct PageAssignMenu: View {
    @Bindable var model: ApplicationModel
    let pageFolderID: String?
    let assignees: [BoardTaskAssignee]
    let chatLink: (BoardTaskAssignee) -> String?
    let onAssign: (BoardTaskAssignee) -> Void
    let onChange: (BoardTaskAssignee) -> Void
    let onRemove: (BoardTaskAssignee) -> Void
    var onOpenSession: ((String) -> Void)?
    @State private var targets: [PageAssignTarget] = []

    private var listed: [BoardTaskAssignee] { assignees.filter { $0.state != .stopped || $0.kind != .user } }

    var body: some View {
        Menu {
            if !listed.isEmpty {
                Section("Assigned") {
                    ForEach(listed) { assignee in
                        Menu(title(assignee)) { actions(assignee) }
                    }
                }
            }
            // Me needs no heading of its own.
            ForEach(targets.filter { $0.group == .me }) { target in targetButton(target) }
            ForEach(groupTitles, id: \.self) { group in
                Section(group) {
                    ForEach(targets.filter { $0.group != .me && $0.group.title == group }) { target in targetButton(target) }
                }
            }
            if targets.count <= 1 {
                Text("Set up agents in Settings, or turn on Bots, to assign tasks to them.")
            }
        } label: { label }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(WovenPalette.muted))
        .help(listed.isEmpty ? "Assign this task" : "Assigned to \(listed.map(\.name).joined(separator: ", "))")
        .task(id: refreshKey) {
            targets = await model.pageAssignTargets(pageFolderID: pageFolderID)
        }
    }

    private var label: some View {
        let active = listed.filter { $0.state != .stopped }
        return HStack(spacing: 5) {
            if let first = active.first { PageAssigneeIcon(assignee: first, size: 12) } else {
                Image(systemName: "person.crop.circle.badge.plus")
            }
            Text(active.isEmpty ? "Assign" : active.count == 1 ? name(active[0]) : "\(name(active[0])) +\(active.count - 1)")
                .lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11.5, weight: .medium))
        .frame(maxWidth: 180)
    }

    /// Reloads the list when harness readiness, workspaces, folders or bot
    /// connections change. Edits to the Page itself never reload it.
    private var refreshKey: String {
        let ready = model.orderedLocalACPRuntimeDefinitions.filter { model.canStartCanonicalLocalSession($0.runtimeKind) }
            .map(\.runtimeKind.rawValue)
        let bots = model.bots.orderedSessions.map { "\($0.machineID):\($0.bots.count):\($0.connectedClient != nil)" }
        let folders = (model.workspaceOverview?.folders ?? []).map { "\($0.id):\($0.executionWorkspaceID ?? "")" }
        let places = model.remoteWorkspaces.readyChatTargets.map { "\($0.configuration.id):\($0.harness.id.rawValue)" }
            + model.remoteWorkspaceAgents.map(\.id.uuidString)
        // Agents are grouped under their workspace's name, which a rename changes.
        let names = model.workspaceNameOverrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return (ready + bots + folders + places + names).joined(separator: "|")
    }

    private var groupTitles: [String] {
        var seen: [String] = []
        for target in targets where target.group != .me && !seen.contains(target.group.title) { seen.append(target.group.title) }
        return seen
    }

    private func targetButton(_ target: PageAssignTarget) -> some View {
        Button(target.detail.map { "\(name(target.assignee)) — \($0)" } ?? name(target.assignee)) {
            onAssign(target.assignee)
        }
        .disabled(!target.ready || assignees.contains { $0.isActive && $0.isSameTarget(as: target.assignee) })
    }

    private func name(_ assignee: BoardTaskAssignee) -> String { assignee.kind == .user ? "Me" : assignee.name }

    private func title(_ assignee: BoardTaskAssignee) -> String {
        var parts = [name(assignee)]
        if assignee.kind != .user, let place = assignee.place, !place.isEmpty { parts.append(place) }
        let state: String? = switch assignee.state {
        case .assigned: assignee.kind == .user ? nil : "not sent"
        case .sending: "sending"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .failed: "didn't send"
        case .sent: nil
        }
        return parts.joined(separator: " · ") + (state.map { " (\($0))" } ?? "")
    }

    @ViewBuilder private func actions(_ assignee: BoardTaskAssignee) -> some View {
        if let chat = chatLink(assignee) { Button(assignee.kind == .bot ? "Open thread" : "Open chat") { onOpenSession?(chat) } }
        if assignee.kind == .agent, assignee.state == .assigned {
            let folders = PageAssignTarget.folders(for: assignee.workspaceID, owner: nil, in: model)
            Menu("Start in folder") {
                Button { setFolder(assignee, nil) } label: { check("No folder", assignee.folderID == nil) }
                ForEach(folders) { folder in
                    Button { setFolder(assignee, folder.id) } label: { check(folder.name, assignee.folderID == folder.id) }
                }
            }
        }
        if assignee.state == .failed {
            Button("Send again") { var updated = assignee; updated.state = .sending; updated.message = nil; onChange(updated) }
        }
        if assignee.isActive && assignee.kind != .user { Button("Stop") { onRemove(assignee) } }
        if assignee.state == .assigned || assignee.state == .failed || (assignee.kind == .user && assignee.state != .stopped) {
            Button("Unassign", role: .destructive) { onRemove(assignee) }
        }
        if let message = assignee.message { Divider(); Text(message) }
        if let by = assignee.assignedBy, by.kind != .user, let label = by.label { Text("Assigned by \(label)") }
    }

    private func setFolder(_ assignee: BoardTaskAssignee, _ folderID: String?) {
        var updated = assignee
        updated.folderID = folderID
        onChange(updated)
    }

    private func check(_ title: String, _ on: Bool) -> some View {
        Group { if on { Label(title, systemImage: "checkmark") } else { Text(title) } }
    }
}

struct PageAssigneeIcon: View {
    let assignee: BoardTaskAssignee
    var size: CGFloat = 12

    var body: some View {
        switch assignee.kind {
        case .agent:
            if let runtime = assignee.runtime.flatMap(AgentRuntimeKind.init(rawValue:)) {
                HarnessLogoIcon(logo: HarnessLogo(runtimeKind: runtime), size: size)
            } else { Image(systemName: "cpu") }
        case .bot: Image(systemName: "bubble.left.and.bubble.right")
        case .user: Image(systemName: "person")
        }
    }
}

/// Someone a task can be assigned to, as the Assign dropdown lists them.
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

/// An App with no code yet. It is built from the chat beside it, like any
/// other edit: the open App is shared with whichever agent the chat uses.
struct AppBuildPrompt: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Ask an agent to build this").font(.system(size: 17, weight: .semibold))
            Text("Describe the app in the chat. The agent you have open builds it here and can connect it to live data.")
                .font(.system(size: 12.5)).foregroundStyle(WovenPalette.mutedForeground)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
