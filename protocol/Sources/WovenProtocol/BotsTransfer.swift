import Foundation

// Transfer: the bots move from their host to another Woven machine.
// The host's server runs it with the target machine's server over
// their server-to-server connection: it stops the bots, writes each bot's
// files out as archives, sends them and the bots folder, and asks the target
// to start the bots. Only once the target has every bot and chat does the
// target become the host (`bots.host`); the old host then removes its copy.
// Until that switch, a failure leaves the bots on the old host, started again.

/// Moves the bots to `targetMachineID`. Sent to the host's server;
/// replies once the bots run there, or fails with what went wrong (the bots
/// then run on the old host again). Progress is in `BotsStatus.transfer`.
public struct TransferBots: Request {
  public static let method = "bots.transfer"
  public typealias Reply = Done
  public var targetMachineID: String
  public init(targetMachineID: String) { self.targetMachineID = targetMachineID }
}

public enum BotsTransferPhase: String, Codable, Sendable, Hashable {
  /// Stopping the bots on the old host.
  case stopping
  /// Writing each bot's files out of the container engine.
  case exporting
  /// Sending the bots folder and the files.
  case copying
  /// The target reads them in, starts its engine and the bots, and checks it has every bot and chat.
  case starting
  /// The old host removes its copy.
  case removing
}

public struct BotsTransferProgress: Codable, Sendable, Hashable {
  public var targetMachineID: String
  public var phase: BotsTransferPhase
  /// Bytes sent and to send, while copying.
  public var bytesSent: Int64?
  public var bytesTotal: Int64?

  public init(targetMachineID: String, phase: BotsTransferPhase, bytesSent: Int64? = nil, bytesTotal: Int64? = nil) {
    self.targetMachineID = targetMachineID
    self.phase = phase
    self.bytesSent = bytesSent
    self.bytesTotal = bytesTotal
  }
}

// MARK: Between the two servers

/// One file of a transfer, by its path in the transfer (`bots/…` for the
/// bots folder, `files/<botId>.tar` for a bot's files).
public struct BotsTransferFile: Codable, Sendable, Hashable {
  public var path: String
  public var size: Int64
  /// SHA-256, lowercase hex.
  public var digest: String

  public init(path: String, size: Int64, digest: String) {
    self.path = path
    self.size = size
    self.digest = digest
  }
}

/// What the target must hold before it becomes the host, as the old host's
/// library had it when the bots stopped.
public struct BotsTransferExpected: Codable, Sendable, Hashable {
  public struct Chat: Codable, Sendable, Hashable {
    /// Nil for a Forum room.
    public var botID: String?
    public var conversationID: Int
    /// The old host's session for it, whose state the new host's session takes on.
    public var session: CarriedSession

    public init(botID: String?, conversationID: Int, session: CarriedSession) {
      self.botID = botID
      self.conversationID = conversationID
      self.session = session
    }
  }

  /// What the person set on a bot chat's session: carried to the session the
  /// new host saves the chat under.
  public struct CarriedSession: Codable, Sendable, Hashable {
    public var title: String
    public var archived: Bool
    public var archivedAt: Int64
    public var folderID: String?
    public var pinned: Bool
    /// The newest item seen, by its `createdAt` in milliseconds.
    public var readAt: Int64
    public var createdAt: Int64

    public init(title: String, archived: Bool, archivedAt: Int64, folderID: String?, pinned: Bool, readAt: Int64,
                createdAt: Int64) {
      self.title = title
      self.archived = archived
      self.archivedAt = archivedAt
      self.folderID = folderID
      self.pinned = pinned
      self.readAt = readAt
      self.createdAt = createdAt
    }
  }

  public var bots: [String]
  public var chats: [Chat]
  /// How far the old host's library held each bot's entries (`bot:<id>`) and the Forum's (`forum`).
  public var checkpoints: [String: Int64]

  public init(bots: [String], chats: [Chat], checkpoints: [String: Int64]) {
    self.bots = bots
    self.chats = chats
    self.checkpoints = checkpoints
  }
}

/// The old host's server opens a transfer on the target's: the files that follow and what to expect.
public struct ReceiveBots: Request {
  public static let method = "bots.transfer.receive"
  public typealias Reply = Done
  public var transferID: String
  public var files: [BotsTransferFile]
  public var expected: BotsTransferExpected
  public init(transferID: String, files: [BotsTransferFile], expected: BotsTransferExpected) {
    self.transferID = transferID
    self.files = files
    self.expected = expected
  }
}

/// The next piece of one file, written at `offset`.
public struct ReceiveBotsPiece: Request {
  public static let method = "bots.transfer.piece"
  public typealias Reply = Done
  public var transferID: String
  public var path: String
  public var offset: Int64
  public var data: Data
  public init(transferID: String, path: String, offset: Int64, data: Data) {
    self.transferID = transferID
    self.path = path
    self.offset = offset
    self.data = data
  }
}

/// Every file is sent: the target checks them, reads them in, starts the bots
/// and replies once it holds every expected bot and chat. Until the commit,
/// the target stops the bots and removes them again if the old host goes away.
public struct StartReceivedBots: Request {
  public static let method = "bots.transfer.start"
  public typealias Reply = Done
  public var transferID: String
  public init(transferID: String) { self.transferID = transferID }
}

/// The switch: the target makes itself the bots' host.
public struct CommitReceivedBots: Request {
  public static let method = "bots.transfer.commit"
  public typealias Reply = Done
  public var transferID: String
  public init(transferID: String) { self.transferID = transferID }
}

/// The old host gives up: the target stops what it started and removes what it received.
public struct AbortReceivedBots: Request {
  public static let method = "bots.transfer.abort"
  public typealias Reply = Done
  public var transferID: String
  public init(transferID: String) { self.transferID = transferID }
}

/// Whether the target made itself the host for a transfer, for an old host that
/// lost the commit's reply. While the bots run on the target before the
/// switch, the old host also sends it every few seconds: a target that hears
/// nothing of its transfer for a minute gives it back.
public struct ReceivedBotsState: Request {
  public static let method = "bots.transfer.state"
  public typealias Reply = ReceivedBotsOutcome
  public var transferID: String
  public init(transferID: String) { self.transferID = transferID }
}

public enum ReceivedBotsOutcome: String, Codable, Sendable, Hashable {
  /// The target is the host.
  case committed
  /// The target still holds the transfer, not yet committed, or is still giving it back.
  case pending
  /// The target holds nothing of it (aborted, or never received).
  case none
}
