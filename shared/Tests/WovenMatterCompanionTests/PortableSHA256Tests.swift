#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Testing
import WovenMatterCompanion

@Suite("Portable SHA-256")
struct PortableSHA256Tests {
  private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

  @Test func matchesPublishedVectors() {
    #expect(hex(PortableSHA256.hash(data: Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(hex(PortableSHA256.hash(data: Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(hex(PortableSHA256.hash(data: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
      == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(hex(PortableSHA256.hash(data: Data(repeating: 0x61, count: 1_000_000)))
      == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  }

  #if canImport(CryptoKit)
  @Test(arguments: [0, 1, 55, 56, 63, 64, 65, 119, 120, 1_000])
  func matchesCryptoKit(length: Int) {
    let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    #expect(PortableSHA256.hash(data: data) == Array(SHA256.hash(data: data)))
  }
  #endif
}
