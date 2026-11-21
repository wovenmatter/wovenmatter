import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

/// A stand-in for Pi Durable's control process: one provider, and a login that
/// shows a link, asks for a code and returns it as the credential.
private let fakeControl = """
import { createInterface } from 'node:readline';
const lines = createInterface({ input: process.stdin });
const write = value => process.stdout.write(JSON.stringify(value) + '\\n');
let answered;
lines.on('line', line => {
  const message = JSON.parse(line);
  if (message.answerTo === 'code') return answered(message.answer);
  if (message.action === 'providers') { write({ result: { providers: [{ id: 'openai-codex', name: 'ChatGPT', kind: 'subscription' }] } }); process.exit(0); }
  write({ event: { url: 'https://example.invalid/sign-in', code: 'ABCD' } });
  write({ event: { prompt: { id: 'code', message: 'Paste the code.' } } });
  new Promise(resolve => { answered = resolve; }).then(code => {
    write({ result: { credential: { type: 'oauth', access: code } } });
    process.exit(0);
  });
});
"""

@Test(.enabled(if: Resources.node != nil))
func subscriptionSignInRelaysItsPromptAndStoresTheCredentialOnThisMachineOnly() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-sign-in-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let agent = folder.appendingPathComponent("agent", isDirectory: true)
  try FileManager.default.createDirectory(at: agent.appendingPathComponent("src"), withIntermediateDirectories: true)
  try fakeControl.write(to: agent.appendingPathComponent("src/main.mjs"), atomically: true, encoding: .utf8)

  let socket = "/tmp/wvs-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(dataFolder: folder, socketPath: socket, listen: nil, appVersion: "test", machineName: "test",
                                    tailnet: StandInTailnet(), runtimes: [PiDurableRuntime(dataFolder: folder, agent: agent)],
                                    discoveryInterval: .seconds(3600))
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  let server = try await WovenServer.start(options)
  defer { server.stopLater() }
  let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))

  let flow = try await client.subscribe(StartSignIn(provider: "openai-codex"))
  var events: [SignInEvent] = []
  for try await event in flow.events {
    events.append(event)
    if case .prompt(let id, _) = event {
      _ = try await client.call(AnswerSignIn(flowID: flow.reply, promptID: id, answer: "the-code"))
    }
    if case .finished = event { break }
    if case .failed(let message) = event { Issue.record("The sign-in failed: \(message)"); break }
  }
  #expect(events.first == .open(url: "https://example.invalid/sign-in", code: "ABCD", instructions: nil))
  #expect(events.last == .finished(SignIn(provider: "openai-codex", name: "ChatGPT", kind: .subscription, connected: true)))

  // The credential stays in this machine's secret store, never in the library.
  let store = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  #expect(try store.read("sign-in/openai-codex") != nil)
  #expect(try await client.call(ListSignIns()).first?.connected == true)
  _ = try await client.call(SignOut(provider: "openai-codex"))
  #expect(try await client.call(ListSignIns()).first?.connected == false)
}
