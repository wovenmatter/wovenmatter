import Foundation

/// The port every Woven server listens on, on its tailnet address.
public let wovenPort = 47337

/// Where a device first finds a Mac's server: that Mac's tailnet address and
/// port, as a link for a QR code or a short code a person types. It holds
/// nothing else and is no secret; Tailscale decides who may connect.
///
/// A tailnet address is in Tailscale's range, 100.64/10, so 22 bits name the
/// host. The code is six characters of Crockford base32 (30 bits): the host,
/// one bit that says another port follows, and seven check bits that catch a
/// mistyped code. Another port adds four characters. Reading ignores case, spaces and
/// dashes, and takes O for 0 and I or L for 1.
public struct ConnectionCode: Sendable, Hashable {
  /// The schemes of the release and development iPhone and iPad apps.
  public static let schemes = ["wovenmatter", "wovenmatter-dev"]

  /// A dotted IPv4 address in 100.64/10.
  public let address: String
  public let port: Int
  private let host: UInt32

  /// nil unless `address` is a tailnet IPv4 address and `port` a TCP port.
  public init?(address: String, port: Int = wovenPort) {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, (1...65535).contains(port) else { return nil }
    var value: UInt32 = 0
    for part in parts {
      guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let octet = UInt8(part) else { return nil }
      value = value << 8 | UInt32(octet)
    }
    guard value >> 22 == Self.prefix else { return nil }
    self.host = value & 0x3F_FFFF
    self.address = parts.map { String(UInt8($0)!) }.joined(separator: ".")
    self.port = port
  }

  /// Reads a typed code; nil when it is not one.
  public init?(code text: String) {
    var symbols: [UInt32] = []
    for character in text.uppercased() where character != "-" && !character.isWhitespace {
      guard let value = Self.value(of: character) else { return nil }
      symbols.append(value)
    }
    guard symbols.count == 6 || symbols.count == 10 else { return nil }
    let head = symbols.prefix(6).reduce(0) { $0 << 5 | $1 }
    let host = head >> 8, follows = head >> 7 & 1 == 1, check = head & 0x7F
    var port = wovenPort
    if symbols.count == 10 {
      let tail = symbols.suffix(4).reduce(0) { $0 << 5 | $1 }
      guard follows, tail & 0xF == 0 else { return nil }
      port = Int(tail >> 4)
    } else if follows {
      return nil
    }
    guard port != 0, check == Self.check(host: host, port: port) else { return nil }
    self.init(address: Self.dotted(Self.prefix << 22 | host), port: port)
  }

  /// Reads a link from `link(scheme:)` with either app's scheme; nil when it
  /// is not one.
  public init?(link: URL) {
    guard let scheme = link.scheme?.lowercased(), Self.schemes.contains(scheme), link.host()?.lowercased() == "connect",
          link.pathComponents.count == 2 else { return nil }
    self.init(code: link.pathComponents[1])
  }

  /// Reads either a link or a code, as pasted or typed.
  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("://") {
      guard let url = URL(string: trimmed) else { return nil }
      self.init(link: url)
    } else {
      self.init(code: trimmed)
    }
  }

  /// The code to show, grouped: `ABC-DEF`, or `ABC-DEF-GHJK` for another port.
  public var code: String {
    let symbols = self.symbols
    var groups = [String(symbols.prefix(3)), String(symbols.dropFirst(3).prefix(3))]
    if symbols.count > 6 { groups.append(String(symbols.suffix(4))) }
    return groups.joined(separator: "-")
  }

  /// The link a QR code carries, for the app that uses `scheme`.
  public func link(scheme: String) -> URL {
    URL(string: "\(scheme)://connect/\(String(symbols))")!
  }

  // MARK: Encoding

  /// The first ten bits of every tailnet address.
  private static let prefix: UInt32 = (100 << 2) | (64 >> 6)
  private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  private var symbols: [Character] {
    let follows: UInt32 = port == wovenPort ? 0 : 1
    var characters = Self.encode(host << 8 | follows << 7 | Self.check(host: host, port: port), count: 6)
    if follows == 1 { characters += Self.encode(UInt32(port) << 4, count: 4) }
    return characters
  }

  private static func encode(_ value: UInt32, count: Int) -> [Character] {
    (0..<count).reversed().map { alphabet[Int(value >> (5 * UInt32($0)) & 0x1F)] }
  }

  private static func value(of character: Character) -> UInt32? {
    switch character {
    case "O": return 0
    case "I", "L": return 1
    default: return alphabet.firstIndex(of: character).map(UInt32.init)
    }
  }

  /// Seven bits of FNV-1a over the host and port.
  private static func check(host: UInt32, port: Int) -> UInt32 {
    var hash: UInt32 = 0x811C_9DC5
    for byte in [UInt8(host >> 16 & 0xFF), UInt8(host >> 8 & 0xFF), UInt8(host & 0xFF), UInt8(port >> 8), UInt8(port & 0xFF)] {
      hash = (hash ^ UInt32(byte)) &* 0x0100_0193
    }
    return (hash ^ hash >> 7 ^ hash >> 14 ^ hash >> 21) & 0x7F
  }

  private static func dotted(_ value: UInt32) -> String {
    [24, 16, 8, 0].map { String(value >> UInt32($0) & 0xFF) }.joined(separator: ".")
  }
}
