import Foundation

// Every request a client or another server can make. A new one is a struct
// here and a handler in the server.

// MARK: Connections

/// Ends a subscription the caller opened. `subscription` is its request id.
public struct Unsubscribe: Request {
  public static let method = "unsubscribe"
  public typealias Reply = Done
  public var subscription: String
  public init(subscription: String) { self.subscription = subscription }
}

// MARK: Machines

/// Every machine in the library, with what this server knows of it now.
public struct ListMachines: Request {
  public static let method = "machines.list"
  public typealias Reply = [MachineStatus]
  public init() {}
}

/// Removes another machine: deletes it, its sessions and its folders from
/// every library. A machine cannot remove itself.
public struct RemoveMachine: Request {
  public static let method = "machines.remove"
  public typealias Reply = Done
  public var machineID: String
  public init(machineID: String) { self.machineID = machineID }
}

/// Renames a machine, the one of the server asked when `machineID` is nil.
/// The name syncs; the newest rename wins.
public struct RenameMachine: Request {
  public static let method = "machines.rename"
  public typealias Reply = Machine
  public var name: String
  public var machineID: String?
  public init(name: String, machineID: String? = nil) {
    self.name = name
    self.machineID = machineID
  }
}

// MARK: Sessions

/// Sessions in the library, newest first. `machineID` limits them to one machine.
public struct ListSessions: Request {
  public static let method = "sessions.list"
  public typealias Reply = [Session]
  public var machineID: String?
  public var includeArchived: Bool
  public init(machineID: String? = nil, includeArchived: Bool = false) {
    self.machineID = machineID
    self.includeArchived = includeArchived
  }
}

/// Starts a session on the machine of the server asked.
public struct CreateSession: Request {
  public static let method = "sessions.create"
  public typealias Reply = Session
  public var runtime: RuntimeKind
  public var title: String
  public var folderID: String?
  public init(runtime: RuntimeKind, title: String, folderID: String? = nil) {
    self.runtime = runtime
    self.title = title
    self.folderID = folderID
  }
}

/// Changes a session's title, folder, archived or pinned flag, or whether the
/// person has read it. Fields left nil stay.
public struct UpdateSession: Request {
  public static let method = "sessions.update"
  public typealias Reply = Session
  public var sessionID: String
  public var title: String?
  public var archived: Bool?
  public var pinned: Bool?
  /// True marks everything in it read; false marks it unread again.
  public var read: Bool?
  public var folderID: String?
  /// Takes the session out of its folder; wins over `folderID`.
  public var removeFromFolder: Bool?
  public init(sessionID: String, title: String? = nil, archived: Bool? = nil, pinned: Bool? = nil, read: Bool? = nil,
              folderID: String? = nil, removeFromFolder: Bool? = nil) {
    self.sessionID = sessionID
    self.title = title
    self.archived = archived
    self.pinned = pinned
    self.read = read
    self.folderID = folderID
    self.removeFromFolder = removeFromFolder
  }
}

/// Deletes a session and its transcript from every library.
public struct DeleteSession: Request {
  public static let method = "sessions.delete"
  public typealias Reply = Done
  public var sessionID: String
  public init(sessionID: String) { self.sessionID = sessionID }
}

/// A session's saved items from the library, in order. Any server can answer
/// for any machine's session. With `beforeSequence`, the newest items before
/// it instead, for paging back. A page with a limit or `beforeSequence` also
/// stops once its size is large, so it may hold fewer than `limit`.
public struct SessionItems: Request {
  public static let method = "sessions.items"
  public typealias Reply = [SessionItem]
  public var sessionID: String
  public var afterSequence: Int
  public var beforeSequence: Int?
  public var limit: Int?
  public init(sessionID: String, afterSequence: Int = 0, beforeSequence: Int? = nil, limit: Int? = nil) {
    self.sessionID = sessionID
    self.afterSequence = afterSequence
    self.beforeSequence = beforeSequence
    self.limit = limit
  }
}

/// The live view of a session, from its owning machine's server only. Replies
/// with a snapshot, then delivers live events.
public struct SubscribeSession: Subscription {
  public static let method = "session.subscribe"
  public typealias Reply = SessionSnapshot
  public typealias Event = SessionEvent
  public var sessionID: String
  public init(sessionID: String) { self.sessionID = sessionID }
}

/// What the sessions this machine owns are doing, for lists: replies with
/// every session that is not idle, then delivers each change.
public struct SubscribeRunStates: Subscription {
  public static let method = "sessions.runStates"
  public typealias Reply = [SessionRunState]
  public typealias Event = SessionRunState
  public init() {}
}

/// Sends a turn. Replies once the message is saved and the runtime took it.
/// Each attachment's content is already in the server's content store
/// (`PutContent`).
public struct SendTurn: Request {
  public static let method = "session.send"
  public typealias Reply = Done
  public var sessionID: String
  public var text: String
  public var attachments: [Attachment]
  public init(sessionID: String, text: String, attachments: [Attachment] = []) {
    self.sessionID = sessionID
    self.text = text
    self.attachments = attachments
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    text = try container.decode(String.self, forKey: .text)
    attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
  }
}

/// Changes a session's model, thinking level or permission mode. Fields left
/// nil stay. Starts the runtime's process if it is not running. Replies with
/// the configuration the runtime confirmed.
public struct ConfigureSession: Request {
  public static let method = "session.configure"
  public typealias Reply = SessionConfiguration
  public var sessionID: String
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public init(sessionID: String, model: String? = nil, thinking: String? = nil, permission: String? = nil) {
    self.sessionID = sessionID
    self.model = model
    self.thinking = thinking
    self.permission = permission
  }
}

/// Answers a prompt the runtime is waiting on.
public struct AnswerPrompt: Request {
  public static let method = "session.answer"
  public typealias Reply = Done
  public var sessionID: String
  public var promptID: String
  public var answer: PromptAnswer
  public init(sessionID: String, promptID: String, answer: PromptAnswer) {
    self.sessionID = sessionID
    self.promptID = promptID
    self.answer = answer
  }
}

/// Interrupts the running turn. The runtime's process stays.
public struct InterruptTurn: Request {
  public static let method = "session.interrupt"
  public typealias Reply = Done
  public var sessionID: String
  public init(sessionID: String) { self.sessionID = sessionID }
}

/// Stops the runtime's process for the session. The next turn resumes it.
public struct StopSession: Request {
  public static let method = "session.stop"
  public typealias Reply = Done
  public var sessionID: String
  public init(sessionID: String) { self.sessionID = sessionID }
}

// MARK: Folders

public struct ListFolders: Request {
  public static let method = "folders.list"
  public typealias Reply = [Folder]
  public var machineID: String?
  public init(machineID: String? = nil) { self.machineID = machineID }
}

/// Creates a folder on the machine of the server asked, for an existing
/// directory there, or with `path` nil for a new blank directory it makes.
public struct CreateFolder: Request {
  public static let method = "folders.create"
  public typealias Reply = Folder
  public var name: String
  public var path: String?
  public init(name: String, path: String? = nil) {
    self.name = name
    self.path = path
  }
}

/// Changes a folder's name, pinned flag or position. Fields left nil stay.
public struct UpdateFolder: Request {
  public static let method = "folders.update"
  public typealias Reply = Folder
  public var folderID: String
  public var name: String?
  public var pinned: Bool?
  public var position: Int?
  public init(folderID: String, name: String? = nil, pinned: Bool? = nil, position: Int? = nil) {
    self.folderID = folderID
    self.name = name
    self.pinned = pinned
    self.position = position
  }
}

/// Removes a folder from every library. With `deleteDirectory`, also deletes
/// the directory the server made for it; only the owning machine's server
/// does that, and never for a directory the person linked.
public struct DeleteFolder: Request {
  public static let method = "folders.delete"
  public typealias Reply = Done
  public var folderID: String
  public var deleteDirectory: Bool
  public init(folderID: String, deleteDirectory: Bool = false) {
    self.folderID = folderID
    self.deleteDirectory = deleteDirectory
  }
}

/// The directories directly inside `path` on the machine of the server asked
/// (its home directory when nil), for choosing a folder's location.
public struct ListDirectories: Request {
  public static let method = "folders.directories"
  public typealias Reply = DirectoryListing
  public var path: String?
  public init(path: String? = nil) { self.path = path }
}

// MARK: Settings

public struct ListSettings: Request {
  public static let method = "settings.list"
  public typealias Reply = [Setting]
  public init() {}
}

public struct SetSetting: Request {
  public static let method = "settings.set"
  public typealias Reply = Setting
  public var key: String
  public var value: JSONValue
  public init(key: String, value: JSONValue) {
    self.key = key
    self.value = value
  }
}

// MARK: Library and sync

/// Announces every change to the library the server holds. Other servers pull
/// when they hear it; a UI refreshes what it shows.
public struct SubscribeLibrary: Subscription {
  public static let method = "library.subscribe"
  public typealias Reply = LibraryEvent
  public typealias Event = LibraryEvent
  public init() {}
}

/// Rows of every synced table whose `changed` is above `after`.
public struct SyncPull: Request {
  public static let method = "sync.pull"
  public typealias Reply = SyncPage
  public var after: Int64
  public var limit: Int
  public init(after: Int64, limit: Int = 500) {
    self.after = after
    self.limit = limit
  }
}

/// Puts a file into the server's content store, for attaching to a turn.
public struct PutContent: Request {
  public static let method = "content.put"
  public typealias Reply = ContentRef
  public var data: Data
  public init(data: Data) { self.data = data }
}

/// Part of a file in the content store, by digest. A local caller may ask
/// for content another machine holds; the server fetches it first.
public struct FetchContent: Request {
  public static let method = "content.fetch"
  public typealias Reply = ContentChunk
  public var digest: String
  public var offset: Int64
  public var length: Int
  public init(digest: String, offset: Int64 = 0, length: Int = 4 << 20) {
    self.digest = digest
    self.offset = offset
    self.length = length
  }
}
