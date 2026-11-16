#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Security)
import Security
#endif

/// Settings → GitHub's signing agent (docs/architecture/GITHUB_IDENTITY.md): the SSH agent
/// protocol (draft-miller-ssh-agent), listing and signing only. Agents and bots ask it to sign
/// GitHub logins; they never get the key, so turning a place off stops them at once with
/// nothing to take back. Linux hosts answer the same in `remote/src/ssh-agent.mjs`.
public enum SSHSigningAgent {
    static let failure: UInt8 = 5, requestIdentities: UInt8 = 11, identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13, signResponse: UInt8 = 14
    static let rsaSHA256: UInt32 = 2, rsaSHA512: UInt32 = 4
    public static let maximumMessage = 256 * 1024

    /// A key the agent can sign with: the public key blob it lists, and its signer.
    public struct Key: Sendable {
        public let type: String
        public let publicBlob: Data
        let signer: @Sendable (Data, UInt32) throws -> Data
        public func sign(_ data: Data, flags: UInt32 = 0) throws -> Data { try signer(data, flags) }
    }

    /// One request (without its length prefix) → the reply. `key` is nil while the asking place
    /// may not use the key: the agent then lists nothing and refuses to sign.
    public static func reply(to message: Data, key: Key?, comment: String = GitHubSSHKeys.defaultComment) -> Data {
        var reader = Reader(message)
        guard let kind = try? reader.byte() else { return Data([failure]) }
        if kind == requestIdentities {
            guard let key else { return Data([identitiesAnswer]) + u32(0) }
            return Data([identitiesAnswer]) + u32(1) + string(key.publicBlob) + string(Data(comment.utf8))
        }
        if kind == signRequest, let key,
           let blob = try? reader.string(), let data = try? reader.string() {
            let flags = (try? reader.u32()) ?? 0
            if blob == key.publicBlob, let signature = try? key.sign(data, flags: flags) {
                return Data([signResponse]) + string(signature)
            }
        }
        return Data([failure])
    }

    // MARK: Keys

    /// An unencrypted OpenSSH private key (`openssh-key-v1`, as Settings → GitHub saves every key).
    public static func parse(privateKey text: String) throws -> Key {
        let body = text.replacingOccurrences(of: GitHubSSHKeys.openSSHHeader, with: "")
            .replacingOccurrences(of: GitHubSSHKeys.openSSHFooter, with: "")
            .filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: body) else { throw invalid("That is not an OpenSSH private key.") }
        var reader = Reader(decoded)
        let magic = Data("openssh-key-v1".utf8) + Data([0])
        guard (try? reader.bytes(magic.count)) == magic else { throw invalid("That is not an OpenSSH private key.") }
        guard try reader.text() == "none", try reader.text() == "none" else { throw invalid("This key has a passphrase.") }
        _ = try reader.string()
        guard try reader.u32() == 1 else { throw invalid("The key file holds more than one key.") }
        let publicBlob = try reader.string()
        var secret = Reader(try reader.string())
        guard try secret.u32() == secret.u32() else { throw invalid("That private key could not be read.") }
        let type = try secret.text()
        switch type {
        case "ssh-ed25519":
            _ = try secret.string()
            let privateKey = try secret.string()
            guard privateKey.count == 64 else { throw invalid("That private key could not be read.") }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey.prefix(32))
            return Key(type: type, publicBlob: publicBlob) { data, _ in
                string(Data(type.utf8)) + string(try key.signature(for: data))
            }
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try secret.string()
            _ = try secret.string()
            let scalar = try secret.string()
            let size = type.hasSuffix("256") ? 32 : type.hasSuffix("384") ? 48 : 66
            let raw = padded(scalar, to: size)
            let sign: @Sendable (Data) throws -> Data
            switch size {
            case 32: let key = try P256.Signing.PrivateKey(rawRepresentation: raw); sign = { try key.signature(for: $0).rawRepresentation }
            case 48: let key = try P384.Signing.PrivateKey(rawRepresentation: raw); sign = { try key.signature(for: $0).rawRepresentation }
            default: let key = try P521.Signing.PrivateKey(rawRepresentation: raw); sign = { try key.signature(for: $0).rawRepresentation }
            }
            return Key(type: type, publicBlob: publicBlob) { data, _ in
                let signature = try sign(data)
                return string(Data(type.utf8)) + string(mpint(signature.prefix(size)) + mpint(signature.suffix(size)))
            }
        case "ssh-rsa":
            let n = try secret.string(), e = try secret.string(), d = try secret.string()
            let iqmp = try secret.string(), p = try secret.string(), q = try secret.string()
            return try rsaKey(publicBlob: publicBlob, n: n, e: e, d: d, iqmp: iqmp, p: p, q: q)
        default:
            throw invalid("Woven can't sign with this kind of key. Generate one here, or paste an Ed25519, ECDSA, or RSA key.")
        }
    }

    private static func rsaKey(publicBlob: Data, n: Data, e: Data, d: Data, iqmp: Data, p: Data, q: Data) throws -> Key {
        #if canImport(Security)
        let one = BigUnsigned(Data([1]))
        let dP = BigUnsigned(d).remainder(BigUnsigned(p) - one), dQ = BigUnsigned(d).remainder(BigUnsigned(q) - one)
        // PKCS #1 RSAPrivateKey: version, n, e, d, p, q, d mod (p-1), d mod (q-1), q⁻¹ mod p.
        let fields = [Data([0]), n, e, d, p, q, dP.bytes, dQ.bytes, iqmp].map(derInteger).reduce(Data(), +)
        let der = Data([0x30]) + derLength(fields.count) + fields
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error) else {
            throw invalid("That RSA key could not be read.")
        }
        let secKey = SecKeyBox(key: key)
        return Key(type: "ssh-rsa", publicBlob: publicBlob) { data, flags in
            let (name, algorithm): (String, SecKeyAlgorithm) = flags & rsaSHA512 != 0 ? ("rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512)
                : flags & rsaSHA256 != 0 ? ("rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256) : ("ssh-rsa", .rsaSignatureMessagePKCS1v15SHA1)
            var failure: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(secKey.key, algorithm, data as CFData, &failure) as Data? else {
                throw invalid("The RSA key could not sign.")
            }
            return string(Data(name.utf8)) + string(signature)
        }
        #else
        throw invalid("RSA keys are signed on a Mac.")
        #endif
    }

    static func invalid(_ message: String) -> GitHubIdentityError { .message(message) }

    // MARK: Wire format

    static func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func u32(_ value: Int) -> Data { u32(UInt32(value)) }
    static func string(_ value: Data) -> Data { u32(value.count) + value }
    static func unsigned(_ value: Data) -> Data {
        let trimmed = value.drop { $0 == 0 }
        return trimmed.isEmpty ? Data([0]) : Data(trimmed)
    }
    static func mpint(_ value: Data) -> Data {
        let bytes = unsigned(value)
        if bytes == Data([0]) { return string(Data()) }
        return string(bytes.first! & 0x80 != 0 ? Data([0]) + bytes : bytes)
    }
    static func padded(_ value: Data, to size: Int) -> Data {
        let bytes = Data(value.drop { $0 == 0 })
        return bytes.count >= size ? Data(bytes.suffix(size)) : Data(count: size - bytes.count) + bytes
    }
    static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes = Data(), value = length
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)]) + bytes
    }
    static func derInteger(_ value: Data) -> Data {
        var bytes = unsigned(value)
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + derLength(bytes.count) + bytes
    }

    struct Reader {
        private let data: Data
        private var offset: Int
        init(_ data: Data) { self.data = Data(data); offset = 0 }
        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw SSHSigningAgent.invalid("That private key could not be read.") }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func byte() throws -> UInt8 { try bytes(1)[0] }
        mutating func u32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func string() throws -> Data { try bytes(Int(try u32())) }
        mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }
    }
}

#if canImport(Security)
/// A private key Security only reads after creation.
private struct SecKeyBox: @unchecked Sendable { let key: SecKey }
#endif

/// Just enough unsigned arithmetic for RSA's CRT exponents: subtraction and remainder.
struct BigUnsigned: Comparable {
    /// Little-endian 32-bit limbs, without leading zero limbs.
    private var limbs: [UInt32]

    init(_ bytes: Data) {
        var limbs: [UInt32] = []
        var value: UInt32 = 0, shift: UInt32 = 0
        for byte in bytes.reversed() {
            value |= UInt32(byte) << shift
            shift += 8
            if shift == 32 { limbs.append(value); value = 0; shift = 0 }
        }
        if shift > 0 { limbs.append(value) }
        self.limbs = limbs
        trim()
    }
    private init(limbs: [UInt32]) { self.limbs = limbs; trim() }
    private mutating func trim() { while limbs.last == 0 { limbs.removeLast() } }

    var bytes: Data {
        var result = Data()
        for limb in limbs.reversed() { result += withUnsafeBytes(of: limb.bigEndian) { Data($0) } }
        let trimmed = result.drop { $0 == 0 }
        return trimmed.isEmpty ? Data([0]) : Data(trimmed)
    }
    private var bitWidth: Int { limbs.isEmpty ? 0 : (limbs.count - 1) * 32 + (32 - limbs.last!.leadingZeroBitCount) }
    private func bit(_ index: Int) -> Bool { limbs[index / 32] >> (index % 32) & 1 == 1 }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }
    /// `lhs - rhs`, for `lhs >= rhs`.
    static func - (lhs: Self, rhs: Self) -> Self {
        var result = lhs.limbs, borrow: Int64 = 0
        for index in result.indices {
            var value = Int64(result[index]) - borrow - (index < rhs.limbs.count ? Int64(rhs.limbs[index]) : 0)
            borrow = value < 0 ? 1 : 0
            if value < 0 { value += 1 << 32 }
            result[index] = UInt32(value)
        }
        return Self(limbs: result)
    }
    /// Shift-and-subtract remainder: fast enough for one RSA key.
    func remainder(_ modulus: Self) -> Self {
        var remainder = Self(limbs: [])
        for index in stride(from: bitWidth - 1, through: 0, by: -1) {
            var shifted = [UInt32](repeating: 0, count: remainder.limbs.count + 1), carry: UInt32 = 0
            for (position, limb) in remainder.limbs.enumerated() { shifted[position] = limb << 1 | carry; carry = limb >> 31 }
            shifted[remainder.limbs.count] = carry
            if bit(index) { shifted[0] |= 1 }
            remainder = Self(limbs: shifted)
            if !(remainder < modulus) { remainder = remainder - modulus }
        }
        return remainder
    }
}
