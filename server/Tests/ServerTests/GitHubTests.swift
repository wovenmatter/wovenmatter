import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#endif

/// The GitHub key is imported into a real server, used only through its SSH
/// agent, never stored or answered in plaintext, and refused once this machine
/// is switched off. The key is a throwaway made here; nothing contacts GitHub.
@Test
func gitHubKeySignsOnlyThroughTheAgentAndStopsWhenThisMachineIsOff() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-github-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let socket = "/tmp/wvg-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(dataFolder: folder, socketPath: socket, listen: nil, appVersion: "test", machineName: "test",
                                    tailnet: StandInTailnet(), runtimes: [], discoveryInterval: .seconds(3600))
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  let server = try await WovenServer.start(options)
  defer { server.stopLater() }
  let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))

  let key = OpenSSHKey.generate(comment: "throwaway")
  let pasted = key.text
  var replies: [GitHubState] = [try await client.call(ImportGitHubKey(privateKey: pasted))]
  #expect(replies[0].key == key.summary)
  #expect(replies[0].key?.fingerprint.hasPrefix("SHA256:") == true)

  let agent = try SocketFolder.path("agent.sock", for: folder)
  let identities = try agentRequest(agent, Data([SSHAgent.requestIdentities]))
  #expect(identities == Data([SSHAgent.identitiesAnswer]) + SSHWire.uint32(1) + SSHWire.string(key.blob)
    + SSHWire.string(Data("throwaway".utf8)))

  let challenge = Data("session identifier and user auth request".utf8)
  let signed = try agentRequest(agent, Data([SSHAgent.signRequest]) + SSHWire.string(key.blob) + SSHWire.string(challenge)
    + SSHWire.uint32(0))
  var reader = SSHWire.Reader(signed)
  #expect(try reader.bytes(1) == Data([SSHAgent.signResponse]))
  var signature = SSHWire.Reader(try reader.string())
  #expect(try signature.text() == "ssh-ed25519")
  let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey)
  #expect(publicKey.isValidSignature(try signature.string(), for: challenge))

  // The private key is nowhere in plaintext: not in a reply, a setting, a
  // library row or the files git reads.
  replies.append(try await client.call(GetGitHub()))
  let page = try await server.library.pull(after: 0, limit: 10_000)
  #expect(page.rows.contains { $0.table == "sealed_secrets" && $0.id == "\(Secrets.gitHubKey):\(server.machineID)" })
  var haystack = try replies.map { try JSONEncoder().encode($0) }
  haystack.append(try JSONEncoder().encode(try await client.call(ListSettings())))
  haystack.append(try JSONEncoder().encode(page.rows))
  for row in page.rows {
    for value in row.values.values { if case .blob(let data) = value { haystack.append(data) } }
  }
  let github = folder.appendingPathComponent("github")
  for name in try FileManager.default.contentsOfDirectory(atPath: github.path) {
    haystack.append(try Data(contentsOf: github.appendingPathComponent(name)))
  }
  let lines = pasted.split(separator: "\n")
  // The first line of the body is the public header; the rest holds the private part.
  let secretForms = [key.seed, Data(key.seed.base64EncodedString().utf8)] + lines[2..<(lines.count - 1)].map { Data($0.utf8) }
  for data in haystack {
    for secret in secretForms { #expect(data.range(of: secret) == nil) }
  }
  #expect(try String(contentsOf: github.appendingPathComponent("id_github.pub"), encoding: .utf8) == key.summary.publicKey + "\n")

  // Switched off here, the agent refuses and git no longer sends GitHub the key.
  let off = try await client.call(SetGitHubPlace(place: server.machineID, allowed: false))
  #expect(off.access.allows(server.machineID) == false)
  #expect(try agentRequest(agent, Data([SSHAgent.requestIdentities])) == Data([SSHAgent.failure]))
  #expect(try agentRequest(agent, Data([SSHAgent.signRequest]) + SSHWire.string(key.blob) + SSHWire.string(challenge)
    + SSHWire.uint32(0)) == Data([SSHAgent.failure]))
  #expect(!FileManager.default.fileExists(atPath: github.appendingPathComponent("github.conf").path))
}

/// A child's environment points git at the server's files, after any git
/// settings of the server's own, and is left alone when there are none.
@Test
func childEnvironmentPointsGitAtTheServersFiles() {
  let settings = GitEnvironment.Settings(folder: URL(fileURLWithPath: "/data/github"))
  let own = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.editor", "GIT_CONFIG_VALUE_0": "vi"]
  let child = GitEnvironment.added(settings, to: own)
  #expect(child["GIT_SSH_COMMAND"] == "ssh -F '/data/github/ssh_config'")
  #expect(child["GIT_CONFIG_COUNT"] == "2" && child["GIT_CONFIG_KEY_0"] == "core.editor")
  #expect(child["GIT_CONFIG_KEY_1"] == "include.path" && child["GIT_CONFIG_VALUE_1"] == "/data/github/gitconfig")
  #expect(GitEnvironment.added(settings, to: ["GIT_SSH": "/bin/myssh"])["GIT_SSH_COMMAND"] == nil)
  #expect(GitEnvironment.added(nil, to: own) == own)
}

/// Sends one agent request over the Unix socket and returns the reply, without lengths.
private func agentRequest(_ path: String, _ message: Data) throws -> Data {
  #if canImport(Glibc)
  let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
  #else
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  #endif
  guard fd >= 0 else { throw RuntimeError.failed("No socket.") }
  defer { close(fd) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    for (index, byte) in path.utf8.enumerated() where index < buffer.count - 1 { buffer[index] = byte }
  }
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard connected == 0 else { throw RuntimeError.failed("Could not reach the agent at \(path).") }
  let frame = SSHWire.string(message)
  _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  func read(_ count: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: count)
    while data.count < count {
      let got = recv(fd, &buffer, count - data.count, 0)
      guard got > 0 else { throw RuntimeError.failed("The agent closed the connection.") }
      data.append(contentsOf: buffer.prefix(got))
    }
    return data
  }
  var length = SSHWire.Reader(try read(4))
  return try read(Int(try length.uint32()))
}
