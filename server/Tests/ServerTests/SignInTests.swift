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

/// A stand-in for Pi Durable's control process whose `providers` reports
/// Claude Code's sign-in as the file `claude` beside it says: true, false or null.
private let claudeControl = """
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
const lines = createInterface({ input: process.stdin });
lines.on('line', () => {
  const claudeSignedIn = JSON.parse(readFileSync(new URL('./claude', import.meta.url), 'utf8'));
  const claudeAccount = claudeSignedIn ? 'person@example.com' : null;
  process.stdout.write(JSON.stringify({ result: { providers: [{ id: 'claude-subscription', name: 'Claude', kind: 'subscription' }], claudeSignedIn, claudeAccount } }) + '\\n');
  process.exit(0);
});
"""

@Test(.enabled(if: Resources.node != nil))
func claudeSubscriptionFollowsClaudeCodesOwnSignInWithoutAClick() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-claude-sign-in-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let agent = folder.appendingPathComponent("agent", isDirectory: true)
  try FileManager.default.createDirectory(at: agent.appendingPathComponent("src"), withIntermediateDirectories: true)
  try claudeControl.write(to: agent.appendingPathComponent("src/main.mjs"), atomically: true, encoding: .utf8)
  let claude = agent.appendingPathComponent("src/claude")

  let socket = "/tmp/wvs-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(dataFolder: folder, socketPath: socket, listen: nil, appVersion: "test", machineName: "test",
                                    tailnet: StandInTailnet(), runtimes: [PiDurableRuntime(dataFolder: folder, agent: agent)],
                                    discoveryInterval: .seconds(3600))
  let secrets = folder.appendingPathComponent("secrets.json")
  options.secretStore = FileSecretStore(file: secrets)
  let server = try await WovenServer.start(options)
  defer { server.stopLater() }
  let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))

  func listed(_ claudeSignedIn: String) async throws -> Bool? {
    try claudeSignedIn.write(to: claude, atomically: true, encoding: .utf8)
    let signIn = try await client.call(ListSignIns()).first
    // The account shown is the one Claude Code names when it answers.
    #expect(signIn?.account == (claudeSignedIn == "true" ? "person@example.com" : nil))
    return signIn?.connected
  }
  let marker = { try FileSecretStore(file: secrets).read("sign-in/claude-subscription") }

  // Claude Code is signed in: Settings shows it, and its marker is saved for sessions and bots.
  #expect(try await listed("true") == true)
  #expect(try marker() != nil)
  // No answer from Claude Code says nothing: the marker stays.
  #expect(try await listed("null") == true)
  #expect(try marker() != nil)
  // Claude Code signed out: so does Woven.
  #expect(try await listed("false") == false)
  #expect(try marker() == nil)
}
