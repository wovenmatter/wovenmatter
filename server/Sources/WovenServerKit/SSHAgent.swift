import Foundation
import NIOCore
import NIOPosix
import Synchronization
import WovenProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// An Ed25519 SSH key in OpenSSH's own format (`openssh-key-v1`, unencrypted),
/// the only kind Woven keeps.
struct OpenSSHKey: Sendable, Equatable {
  static let header = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
  static let footer = "-----END OPENSSH " + "PRIVATE KEY-----"
  static let type = "ssh-ed25519"

  /// The 32-byte private seed.
  let seed: Data
  let publicKey: Data
  let comment: String

  init(seed: Data, comment: String) throws {
    self.seed = seed
    self.publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    self.comment = comment
  }

  static func generate(comment: String = "woven-matter") -> OpenSSHKey {
    // A fresh key's seed is always 32 bytes, so this cannot fail.
    try! OpenSSHKey(seed: Curve25519.Signing.PrivateKey().rawRepresentation, comment: comment)
  }

  /// The SSH wire form of the public key.
  var blob: Data { SSHWire.string(Data(Self.type.utf8)) + SSHWire.string(publicKey) }

  var summary: GitHubKeySummary {
    let line = Self.type + " " + blob.base64EncodedString()
    return GitHubKeySummary(publicKey: comment.isEmpty ? line : line + " " + comment,
                            fingerprint: "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: ""),
                            type: Self.type, comment: comment.isEmpty ? nil : comment)
  }

  /// An SSH signature blob over `data`.
  func sign(_ data: Data) throws -> Data {
    let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: data)
    return SSHWire.string(Data(Self.type.utf8)) + SSHWire.string(signature)
  }

  /// The private key file's text.
  var text: String {
    let check = UInt32.random(in: .min ... .max)
    var secret = SSHWire.uint32(check) + SSHWire.uint32(check)
    secret += SSHWire.string(Data(Self.type.utf8)) + SSHWire.string(publicKey) + SSHWire.string(seed + publicKey)
    secret += SSHWire.string(Data(comment.utf8))
    var pad: UInt8 = 1
    while secret.count % 8 != 0 { secret.append(pad); pad += 1 }
    var body = Data("openssh-key-v1\0".utf8)
    body += SSHWire.string(Data("none".utf8)) + SSHWire.string(Data("none".utf8)) + SSHWire.string(Data())
    body += SSHWire.uint32(1) + SSHWire.string(blob) + SSHWire.string(secret)
    let encoded = body.base64EncodedString()
    var lines: [String] = []
    var index = encoded.startIndex
    while index < encoded.endIndex {
      let end = encoded.index(index, offsetBy: 70, limitedBy: encoded.endIndex) ?? encoded.endIndex
      lines.append(String(encoded[index..<end]))
      index = end
    }
    return ([Self.header] + lines + [Self.footer]).joined(separator: "\n") + "\n"
  }

  /// Reads pasted or stored key text. Anything but an unencrypted OpenSSH
  /// Ed25519 key is refused with a message for people.
  init(text: String) throws {
    let pasted = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    func refuse(_ message: String) -> any Error { ProtocolError(.badRequest, message) }
    guard !pasted.isEmpty else { throw refuse("Paste a private key.") }
    if pasted.hasPrefix("ssh-") || pasted.hasPrefix("ecdsa-") {
      throw refuse("That is a public key. Paste the private key, which starts with \(Self.header).")
    }
    guard pasted.utf8.count <= 16 * 1024, pasted.hasPrefix(Self.header), pasted.hasSuffix(Self.footer) else {
      if pasted.hasPrefix("-----BEGIN "), pasted.contains("PRIVATE KEY-----") {
        throw refuse("Woven uses Ed25519 keys in OpenSSH format, which start with \(Self.header). Generate a key here instead.")
      }
      throw refuse("That is not an SSH private key. It starts with \(Self.header).")
    }
    let unreadable = refuse("That private key could not be read. Paste the whole key, including its BEGIN and END lines.")
    let base64 = pasted.dropFirst(Self.header.count).dropLast(Self.footer.count).filter { !$0.isWhitespace }
    guard let body = Data(base64Encoded: String(base64)) else { throw unreadable }
    var reader = SSHWire.Reader(body)
    do {
      guard try reader.bytes(15) == Data("openssh-key-v1\0".utf8) else { throw unreadable }
      let cipher = try reader.text(), kdf = try reader.text()
      _ = try reader.string()
      guard cipher == "none", kdf == "none" else {
        throw refuse("This key has a passphrase. Paste a key without one, or generate a new key here.")
      }
      guard try reader.uint32() == 1 else { throw unreadable }
      var outer = SSHWire.Reader(try reader.string())
      guard try outer.text() == Self.type else {
        throw refuse("Woven uses Ed25519 keys only. Generate a key here, or paste an Ed25519 key.")
      }
      let published = try outer.string()
      var secret = SSHWire.Reader(try reader.string())
      guard try secret.uint32() == secret.uint32(), try secret.text() == Self.type else { throw unreadable }
      let publicKey = try secret.string(), privateKey = try secret.string(), comment = try secret.text()
      guard publicKey == published, publicKey.count == 32, privateKey.count == 64 else { throw unreadable }
      self = try OpenSSHKey(seed: Data(privateKey.prefix(32)), comment: comment)
      guard self.publicKey == publicKey else { throw unreadable }
    } catch let error as ProtocolError {
      throw error
    } catch {
      throw unreadable
    }
  }
}

/// SSH's wire encoding: big-endian lengths before byte strings.
enum SSHWire {
  struct Short: Error {}

  static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
  static func string(_ bytes: Data) -> Data { uint32(UInt32(bytes.count)) + bytes }

  struct Reader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
      self.data = Data(data)
      offset = 0
    }

    var atEnd: Bool { offset >= data.count }

    mutating func bytes(_ count: Int) throws -> Data {
      guard count >= 0, data.count - offset >= count else { throw Short() }
      defer { offset += count }
      return data.subdata(in: offset..<offset + count)
    }

    mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func string() throws -> Data { try bytes(Int(uint32())) }
    mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }
  }
}

/// The SSH agent agents reach git through: it lists the GitHub key and signs
/// with it, and nothing else. It answers FAILURE while there is no key or this
/// machine is switched off, so switching off stops agents at once.
final class SSHAgent: Sendable {
  static let failure: UInt8 = 5, requestIdentities: UInt8 = 11, identitiesAnswer: UInt8 = 12
  static let signRequest: UInt8 = 13, signResponse: UInt8 = 14

  let path: String
  private let channel: any Channel
  private let box: KeyBox

  private init(path: String, channel: any Channel, box: KeyBox) {
    self.path = path
    self.channel = channel
    self.box = box
  }

  /// Listens on `path`, which only this user can open.
  static func start(path: String) async throws -> SSHAgent {
    let box = KeyBox()
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(AgentFrames()))
          try channel.pipeline.syncOperations.addHandler(AgentHandler(reply: { box.reply(to: $0) }))
        }
      }
      .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true).get()
    chmod(path, 0o600)
    return SSHAgent(path: path, channel: channel, box: box)
  }

  /// The key to answer with, or nil to refuse everything.
  func use(_ key: OpenSSHKey?) {
    box.key.withLock { $0 = key }
  }

  func stop() async {
    try? await channel.close()
    unlink(path)
  }

  /// One request, without its length, to its reply.
  static func reply(to message: Data, key: OpenSSHKey?) -> Data {
    var reader = SSHWire.Reader(message)
    guard let key, let kind = try? reader.bytes(1).first else { return Data([failure]) }
    switch kind {
    case requestIdentities:
      return Data([identitiesAnswer]) + SSHWire.uint32(1) + SSHWire.string(key.blob) + SSHWire.string(Data(key.comment.utf8))
    case signRequest:
      guard let blob = try? reader.string(), let data = try? reader.string(), blob == key.blob,
            let signature = try? key.sign(data) else { return Data([failure]) }
      return Data([signResponse]) + SSHWire.string(signature)
    default:
      return Data([failure])
    }
  }
}

private final class KeyBox: Sendable {
  let key = Mutex<OpenSSHKey?>(nil)
  func reply(to message: Data) -> Data { SSHAgent.reply(to: message, key: key.withLock { $0 }) }
}

/// Splits the stream into length-prefixed agent messages.
private struct AgentFrames: ByteToMessageDecoder {
  typealias InboundOut = ByteBuffer
  static let maximum = 256 * 1024

  struct TooLong: Error {}

  mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
    guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return .needMoreData }
    guard length > 0, length <= Self.maximum else { throw TooLong() }
    guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
    buffer.moveReaderIndex(forwardBy: 4)
    context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: Int(length))!))
    return .continue
  }

  mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
    while try decode(context: context, buffer: &buffer) == .continue {}
    return .needMoreData
  }
}

private final class AgentHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer
  private let reply: @Sendable (Data) -> Data

  init(reply: @escaping @Sendable (Data) -> Data) { self.reply = reply }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)
    let answer = reply(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
    var out = context.channel.allocator.buffer(capacity: answer.count + 4)
    out.writeInteger(UInt32(answer.count))
    out.writeBytes(answer)
    context.writeAndFlush(wrapOutboundOut(out), promise: nil)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }
}
