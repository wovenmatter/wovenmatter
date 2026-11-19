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

/// Renames the machine of the server asked.
public struct RenameMachine: Request {
  public static let method = "machines.rename"
  public typealias Reply = Machine
  public var name: String
  public init(name: String) { self.name = name }
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

/// Changes a session's title, folder or archived flag. Fields left nil stay.
public struct UpdateSession: Request {
  public static let method = "sessions.update"
  public typealias Reply = Session
  public var sessionID: String
  public var title: String?
  public var archived: Bool?
  public var folderID: String?
  /// Takes the session out of its folder; wins over `folderID`.
  public var removeFromFolder: Bool?
  public init(sessionID: String, title: String? = nil, archived: Bool? = nil, folderID: String? = nil,
              removeFromFolder: Bool? = nil) {
    self.sessionID = sessionID
    self.title = title
    self.archived = archived
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
/// for any machine's session.
public struct SessionItems: Request {
  public static let method = "sessions.items"
  public typealias Reply = [SessionItem]
  public var sessionID: String
  public var afterSequence: Int
  public var limit: Int?
  public init(sessionID: String, afterSequence: Int = 0, limit: Int? = nil) {
    self.sessionID = sessionID
    self.afterSequence = afterSequence
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

/// Sends a turn. Replies once the message is saved and the runtime took it.
public struct SendTurn: Request {
  public static let method = "session.send"
  public typealias Reply = Done
  public var sessionID: String
  public var text: String
  public init(sessionID: String, text: String) {
    self.sessionID = sessionID
    self.text = text
  }
}

/// Answers a question or approval the runtime is waiting on.
public struct AnswerPrompt: Request {
  public static let method = "session.answer"
  public typealias Reply = Done
  public var sessionID: String
  public var promptID: String
  public var answer: String
  public init(sessionID: String, promptID: String, answer: String) {
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

/// Creates a folder on the machine of the server asked.
public struct CreateFolder: Request {
  public static let method = "folders.create"
  public typealias Reply = Folder
  public var name: String
  public var path: String
  public init(name: String, path: String) {
    self.name = name
    self.path = path
  }
}

public struct RenameFolder: Request {
  public static let method = "folders.rename"
  public typealias Reply = Folder
  public var folderID: String
  public var name: String
  public init(folderID: String, name: String) {
    self.folderID = folderID
    self.name = name
  }
}

public struct DeleteFolder: Request {
  public static let method = "folders.delete"
  public typealias Reply = Done
  public var folderID: String
  public init(folderID: String) { self.folderID = folderID }
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

/// Part of a file in the content store, by digest.
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
