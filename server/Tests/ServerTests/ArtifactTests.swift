import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

@Test(.timeLimit(.minutes(1)))
func noteWrittenByTwoWritersOnOneServerKeepsTheNewerAndTheOtherInHistory() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
  let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(dataFolder: folder, socketPath: socket, listen: nil, appVersion: "test",
                                    machineName: "test", tailnet: StandInTailnet(), runtimes: [StandInRuntime()])
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  let server = try await WovenServer.start(options)
  defer { Task { await server.stop() } }
  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))
    return client
  }
  func note(_ text: String) throws -> String {
    try NoteDocument(blocks: [.richText(NoteRichTextBlock(runs: [NoteTextRun(text: text)]))]).encoded()
  }
  let editor = try await connect(), agent = try await connect()

  let created = try await editor.call(CreateArtifact(kind: .note, title: "Plan"))
  let base = created.artifact.stamp
  // The agent edits on top of what it read; the editor, still on the same base, writes after it.
  let agentWrite = try await agent.call(WriteArtifact(artifactID: created.artifact.id, basedOn: base, body: note("agent")))
  #expect(!agentWrite.replacedUnseen)
  let editorWrite = try await editor.call(WriteArtifact(artifactID: created.artifact.id, basedOn: base, body: note("person")))
  #expect(editorWrite.replacedUnseen)

  let current = try await agent.call(ReadArtifact(artifactID: created.artifact.id))
  #expect(NoteDocument.decode(current.body).plainText == "person")
  let versions = try await agent.call(ListArtifactVersions(artifactID: created.artifact.id))
  #expect(versions.map(\.reason) == [.conflict])
  let kept = try await agent.call(ReadArtifactVersion(versionID: try #require(versions.first).id))
  #expect(NoteDocument.decode(kept.body).plainText == "agent")
}
