import SwiftUI
import UIKit
import WovenProtocol

/// The pages the Folders tab pushes onto its stack.
enum FoldersRoute: Hashable {
    /// Every chat and artifact, folderless ones included.
    case all
    case folder(String)
    case trash
}

/// Who owns a folder about to be made: this device, or one machine.
struct FolderOwner: Identifiable, Hashable {
    let id: String
    let name: String
    let isDevice: Bool
}

/// Where things are, as the Folders pages name them: this device, each
/// machine's workspace, and another device's Quick Chats.
@MainActor
struct FolderPlaces {
    let model: MobileModel

    private var app: ApplicationModel { model.app }

    /// "This iPhone" or "This iPad": the device itself, as "This Mac" is the Mac.
    static var deviceTitle: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
    }

    var deviceID: String? { model.deviceID }

    var overview: WorkspaceOverview { app.workspace.workspaceOverview ?? .empty }

    func isDevice(_ machineID: String) -> Bool { machineID == deviceID }

    /// The workspace's name: this device, a machine, or another device.
    func title(of machineID: String) -> String {
        if isDevice(machineID) { return Self.deviceTitle }
        if let machine = app.machines.machine(id: machineID) { return machine.name }
        return app.devices.names[machineID] ?? "Another device"
    }

    /// Whether the owner can carry out a change now: this device always, a
    /// machine while its server is connected.
    func isReachable(_ machineID: String) -> Bool {
        isDevice(machineID) || app.machines.machine(id: machineID)?.isOnline == true
    }

    /// The owner of a folder that is about to be made there.
    func owner(_ machineID: String) -> FolderOwner {
        FolderOwner(id: machineID, name: title(of: machineID), isDevice: isDevice(machineID))
    }

    /// A machine's or this device's folders, pinned first, each part in its saved order.
    func folders(on machineID: String) -> [WorkspaceFolderRecord] {
        let sections = FolderSections(folders: app.workspace.folders(on: machineID))
        return sections.pinned + sections.unpinned
    }

    /// Every folder by its workspace: this device first, then each machine.
    var folderGroups: [(owner: FolderOwner, folders: [WorkspaceFolderRecord])] {
        let owners = (deviceID.map { [$0] } ?? []) + app.machines.machines.map(\.id)
        return owners.map { (owner($0), folders(on: $0)) }.filter { !$0.folders.isEmpty }
    }

    /// Where a chat runs, for lists that mix workspaces: its agent and its
    /// workspace, or Quick Chat with the device that owns it.
    func place(of conversation: WorkspaceConversationRecord) -> String {
        if isDevice(conversation.machineID) { return "Quick Chat" }
        if let machine = app.machines.machine(id: conversation.machineID) {
            return "\(conversation.runtimeName) · \(machine.name)"
        }
        return "Quick Chat · \(title(of: conversation.machineID))"
    }

    /// Chats, pinned first, then the newest.
    func sorted(_ conversations: [WorkspaceConversationRecord]) -> [WorkspaceConversationRecord] {
        conversations.filter { !$0.isArchived }.sorted {
            ($0.isPinned ? 1 : 0, $0.lastMessageAt ?? .distantPast, $0.id) > ($1.isPinned ? 1 : 0, $1.lastMessageAt ?? .distantPast, $1.id)
        }
    }

    /// Artifacts, pinned first, then the most recently changed.
    func sorted(_ notes: [WorkspaceNoteRecord]) -> [WorkspaceNoteRecord] {
        notes.sorted {
            ($0.isPinned ? 1 : 0, $0.updatedAt ?? $0.createdAt ?? .distantPast, $0.id)
                > ($1.isPinned ? 1 : 0, $1.updatedAt ?? $1.createdAt ?? .distantPast, $1.id)
        }
    }

    /// How many chats and artifacts each folder holds.
    var counts: [String: (chats: Int, artifacts: Int)] {
        var counts: [String: (chats: Int, artifacts: Int)] = [:]
        for conversation in overview.conversations where !conversation.isArchived {
            if let id = conversation.folderID { counts[id, default: (0, 0)].chats += 1 }
        }
        for note in overview.notes {
            if let id = note.folderID { counts[id, default: (0, 0)].artifacts += 1 }
        }
        return counts
    }

    /// The newest chats and artifacts across every workspace, as the Mac's Recents shows them.
    var recents: [FolderRecentItem] {
        let items = overview.conversations.filter { !$0.isArchived }.map(FolderRecentItem.chat)
            + overview.notes.map(FolderRecentItem.artifact)
        return Array(items.sorted { ($0.date, $0.id) > ($1.date, $1.id) }.prefix(14))
    }
}

enum FolderRecentItem: Identifiable {
    case chat(WorkspaceConversationRecord)
    case artifact(WorkspaceNoteRecord)

    var id: String {
        switch self {
        case .chat(let chat): "chat:" + chat.id
        case .artifact(let note): "artifact:" + note.id
        }
    }

    var date: Date {
        switch self {
        case .chat(let chat): chat.lastMessageAt ?? .distantPast
        case .artifact(let note): note.updatedAt ?? note.createdAt ?? .distantPast
        }
    }
}

/// A list row's time: the time today, else the day.
func folderRowTime(_ date: Date?) -> String {
    guard let date, date > .distantPast else { return "" }
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

extension View {
    /// A sheet opened from the Folders tab, in the app's theme.
    func folderSheetTheme(_ theme: WovenTheme) -> some View {
        environment(\.wovenTheme, theme)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.palette.themeAccent)
    }
}
