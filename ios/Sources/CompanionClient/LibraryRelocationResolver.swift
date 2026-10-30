import CryptoKit
import Foundation
import WovenMatterCompanion
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LibraryRelocationSignal: Error, Sendable { let relocation: CompanionLibraryRelocation; let previousEndpoint: URL }

private final class RelocationNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum LibraryRelocationResolver {
  public static func verify(_ proof: CompanionLibraryRelocationProof, credential: MobileCredential, nonce: Data) throws -> Bool {
    guard proof.relocation.previousLibraryID == credential.workspaceID, nonce.count == 32,
          CompanionPairingPayload.isValidEndpoint(proof.relocation.endpoint), UUID(uuidString: proof.relocation.transferID) != nil else { return false }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let key = SymmetricKey(data: SHA256.hash(data: Data(credential.token.utf8)))
    return HMAC<SHA256>.isValidAuthenticationCode(proof.signature, authenticating: nonce + (try encoder.encode(proof.relocation)), using: key)
  }
  public static func find(credential: MobileCredential) async throws -> CompanionLibraryRelocation? {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCache = nil
    config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
    let session = URLSession(configuration: config, delegate: RelocationNoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var generator = SystemRandomNumberGenerator()
    let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    let digest = Data(SHA256.hash(data: Data(credential.token.utf8)))
    let keyID = SHA256.hash(data: digest).map { String(format: "%02x", $0) }.joined()
    let body = try JSONEncoder().encode(CompanionLibraryRelocationChallenge(libraryID: credential.workspaceID, deviceID: credential.deviceID, nonce: nonce, credentialID: keyID))
    return await withTaskGroup(of: CompanionLibraryRelocation?.self) { group in
    for endpoint in (credential.migrationCandidates ?? []).prefix(64) where endpoint != credential.endpoint && CompanionPairingPayload.isValidEndpoint(endpoint) {
      group.addTask {
      var request = URLRequest(url: endpoint.appending(path: "v1/library-relocation/proof"))
      request.httpMethod = "POST"; request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      // No bearer is sent to a discovered endpoint. It must first prove it owns
      // the transferred verifier for this exact device and fresh challenge.
      do {
        #if !os(Linux)
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= 8192 else { return nil }
        var data = Data()
        for try await byte in bytes { guard data.count < 8192 else { return nil }; data.append(byte) }
        #else
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8192 else { return nil }
        #endif
        let proof = try JSONDecoder().decode(CompanionLibraryRelocationProof.self, from: data)
        return try verify(proof, credential: credential, nonce: nonce) ? proof.relocation : nil
      } catch { return nil }
      }
    }
    for await relocation in group { if let relocation { group.cancelAll(); return relocation } }
    return nil
    }
  }
}
