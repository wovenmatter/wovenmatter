import Foundation

// The GitHub SSH key and git identity every machine's agents use. The key is
// synced sealed for each machine; replies never carry the private key.

/// The key as GitHub's Add SSH key page and `ssh-keygen -l` show it.
public struct GitHubKeySummary: Codable, Sendable, Hashable {
  /// `ssh-ed25519 <base64> <comment>`, the line GitHub takes.
  public var publicKey: String
  /// `SHA256:<base64>`, as `ssh-keygen -l` prints it.
  public var fingerprint: String
  public var type: String
  public var comment: String?

  public init(publicKey: String, fingerprint: String, type: String, comment: String?) {
    self.publicKey = publicKey
    self.fingerprint = fingerprint
    self.type = type
    self.comment = comment
  }
}

/// Author and committer on every commit. Blank fields keep each machine's own git settings.
public struct GitHubIdentity: Codable, Sendable, Hashable {
  public var name: String
  public var email: String

  public init(name: String = "", email: String = "") {
    self.name = name
    self.email = email
  }
}

/// Which places use the key: machines by machine ID, bots by bot ID, lowercased.
/// A place never switched follows `newPlaces`.
public struct GitHubPlaces: Codable, Sendable, Hashable {
  public var newPlaces: Bool
  public var places: [String: Bool]

  public init(newPlaces: Bool = true, places: [String: Bool] = [:]) {
    self.newPlaces = newPlaces
    self.places = places
  }

  public func allows(_ place: String) -> Bool { places[place.lowercased()] ?? newPlaces }
}

/// What Settings → GitHub shows. `key` is nil while this machine holds no key.
public struct GitHubState: Codable, Sendable, Hashable {
  public var key: GitHubKeySummary?
  public var identity: GitHubIdentity
  public var access: GitHubPlaces

  public init(key: GitHubKeySummary?, identity: GitHubIdentity, access: GitHubPlaces) {
    self.key = key
    self.identity = identity
    self.access = access
  }
}

public struct GetGitHub: Request {
  public static let method = "github.get"
  public typealias Reply = GitHubState
  public init() {}
}

/// Makes a new Ed25519 key in the server and gives it to every machine.
public struct GenerateGitHubKey: Request {
  public static let method = "github.generateKey"
  public typealias Reply = GitHubState
  public init() {}
}

/// Takes a pasted unencrypted OpenSSH Ed25519 private key. Never log it.
public struct ImportGitHubKey: Request {
  public static let method = "github.importKey"
  public typealias Reply = GitHubState
  public var privateKey: String
  public init(privateKey: String) { self.privateKey = privateKey }
}

public struct RemoveGitHubKey: Request {
  public static let method = "github.removeKey"
  public typealias Reply = GitHubState
  public init() {}
}

public struct SetGitHubIdentity: Request {
  public static let method = "github.setIdentity"
  public typealias Reply = GitHubState
  public var identity: GitHubIdentity
  public init(identity: GitHubIdentity) { self.identity = identity }
}

/// Switches the key on or off for one machine or bot.
public struct SetGitHubPlace: Request {
  public static let method = "github.setPlace"
  public typealias Reply = GitHubState
  public var place: String
  public var allowed: Bool
  public init(place: String, allowed: Bool) {
    self.place = place
    self.allowed = allowed
  }
}

/// Whether places added later get the key. The `listed` places keep what they have now.
public struct SetGitHubNewPlaces: Request {
  public static let method = "github.setNewPlaces"
  public typealias Reply = GitHubState
  public var allowed: Bool
  public var listed: [String]
  public init(allowed: Bool, listed: [String]) {
    self.allowed = allowed
    self.listed = listed
  }
}
