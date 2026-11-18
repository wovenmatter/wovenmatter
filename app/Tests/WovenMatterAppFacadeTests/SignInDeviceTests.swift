import Foundation
import Security
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

/// One device's Keychain, in memory. Bound with `KeychainAccess.$testOperations`,
/// so the code under test never reaches the user's Keychain.
final class SignInKeychainFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private func name(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")/\(query[kSecAttrAccount as String] as? String ?? "")"
    }
    var stored: [String: String] { lock.withLock { values.mapValues { String(decoding: $0, as: UTF8.self) } } }
    var operations: KeychainOperations {
        KeychainOperations(
            copyMatching: { [self] query in
                lock.withLock { values[name(query)].map { (errSecSuccess, $0 as CFData) } ?? (errSecItemNotFound, nil) }
            },
            getInteractionAllowed: { (errSecSuccess, false) },
            setInteractionAllowed: { _ in errSecSuccess },
            update: { [self] query, attributes in
                lock.withLock {
                    guard values[name(query)] != nil else { return errSecItemNotFound }
                    values[name(query)] = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            add: { [self] attributes in lock.withLock { values[name(attributes)] = attributes[kSecValueData as String] as? Data; return errSecSuccess } },
            delete: { [self] query in lock.withLock { values.removeValue(forKey: name(query)); return errSecSuccess } })
    }
}

/// A stand-in for Pi Durable's settings helper (`main.mjs --control`) with a fake
/// provider: a sign-in shows a link and a code, asks for a pasted code, then
/// returns an OAuth credential. Every request is appended to `requests.jsonl`.
struct FakeSettingsHelper {
    let directory: URL
    var script: URL { directory.appending(path: "helper.sh") }
    var requests: [String] { ((try? String(contentsOf: directory.appending(path: "requests.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "woven-sign-in-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let status = #"{"result":{"providers":[{"id":"openai-codex","name":"ChatGPT","connected":true}],"models":[],"searchConfigured":false}}"#
        let body = """
        #!/bin/sh
        read request
        printf '%s\\n' "$request" >> '\(directory.path)/requests.jsonl'
        case "$request" in
          *'"action":"login"'*)
            printf '%s\\n' '{"notification":{"url":"https://auth.example.test/device","userCode":"WOVEN-1234","message":"Open the link to sign in."}}'
            printf '%s\\n' '{"id":"code-1","prompt":{"message":"Paste the authorization code."}}'
            read answer
            printf '%s\\n' "$answer" >> '\(directory.path)/requests.jsonl'
            printf '%s\\n' '{"result":{"providers":[],"models":[],"searchConfigured":false,"connected":true,"provider":"openai-codex","credential":{"type":"oauth","access":"fixture-access","refresh":"fixture-refresh","expires":9000000000000,"accountId":"fixture-account","displayName":"person@example.test"}}}'
            ;;
          *) printf '%s\\n' '\(status)' ;;
        esac
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
    var launch: LocalACPRuntimeLaunchConfiguration { .init(runtimeKind: .defaultAgent, executableURL: script, arguments: []) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A Linux host's sign-in routes and settings helper, with a fake provider. Its
/// own store is the only place a credential lands.
actor FakeLinuxSignInHost: MemberExecutionRoutes {
    private(set) var keys: [String: [(id: String, label: String, key: String)]] = [:]
    private(set) var subscriptions: [String: String] = [:]
    private(set) var controlRequests: [Data] = []
    private(set) var answers: [String] = []
    private var sessions: [String: (provider: String, answered: Bool)] = [:]

    private func session(_ json: String) throws -> DefaultAgentControlSession {
        try JSONDecoder().decode(DefaultAgentControlSession.self, from: Data(json.utf8))
    }
    private func view() throws -> DeviceSignIns {
        var accounts: [String: [[String: Any]]] = [:]
        for (provider, entries) in keys { accounts[provider] = entries.enumerated().map { ["id": $1.id, "label": $1.label, "isSelected": $0 == 0] } }
        for (provider, label) in subscriptions { accounts[provider] = [["id": "default", "label": label, "isSelected": true]] }
        return try JSONDecoder().decode(DeviceSignIns.self, from: JSONSerialization.data(withJSONObject: ["accounts": accounts, "servers": []]))
    }
    func signIns() throws -> DeviceSignIns { try view() }
    func changeSignIns(_ change: DeviceSignInChange) throws -> DeviceSignIns {
        let provider = change.provider ?? ""
        switch change.action {
        case "saveKey": keys[provider, default: []].append((UUID().uuidString.lowercased(), change.label ?? "API key", change.key ?? ""))
        case "remove": keys[provider]?.removeAll { $0.id == change.id }; if change.id == "default" { subscriptions[provider] = nil }
        case "select":
            if let index = keys[provider]?.firstIndex(where: { $0.id == change.id }), let entry = keys[provider]?.remove(at: index) { keys[provider]?.insert(entry, at: 0) }
        default: break
        }
        return try view()
    }
    func startDefaultAgentControl(_ request: Data) throws -> DefaultAgentControlSession {
        let body = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        controlRequests.append(request)
        let id = UUID().uuidString.lowercased()
        if body["action"] as? String == "login" {
            sessions[id] = (body["provider"] as? String ?? "", false)
            return try defaultAgentControl(id: id)
        }
        return try session(#"{"id":"\#(id)","state":"succeeded","notifications":[],"result":{"providers":[],"models":[],"searchConfigured":false}}"#)
    }
    func defaultAgentControl(id: String) throws -> DefaultAgentControlSession {
        guard let current = sessions[id] else { throw LibraryAPIError(code: "http_404", message: "") }
        if current.answered {
            return try session(#"{"id":"\#(id)","state":"succeeded","notifications":[{"url":"https://auth.example.test/device","userCode":"HOST-1234"}],"result":{"providers":[],"models":[],"searchConfigured":false,"connected":true,"provider":"\#(current.provider)"}}"#)
        }
        return try session(#"{"id":"\#(id)","state":"running","notifications":[{"url":"https://auth.example.test/device","userCode":"HOST-1234"}],"prompt":{"id":"host-code","message":"Paste the authorization code."}}"#)
    }
    func answerDefaultAgentControl(id: String, answerTo: String, answer: String) throws -> DefaultAgentControlSession {
        answers.append(answer)
        if let current = sessions[id] {
            sessions[id] = (current.provider, true)
            // The host stores and renews what it signed in to.
            subscriptions[current.provider] = "host@example.test"
        }
        return try defaultAgentControl(id: id)
    }
    func cancelDefaultAgentControl(id: String) {}
    func uploadAttachment(_ data: Data, sha256: String, name: String, mimeType: String) throws -> LibraryAttachmentReference { throw LibraryAPIError(code: "unavailable", message: "") }
    func sessionOptions(providerID: String, workingDirectory: String?, model: String?) throws -> SessionSettings { throw LibraryAPIError(code: "unavailable", message: "") }
    func libraryFile(conversationID: String?, path: String) throws -> MemberLibraryFile { throw LibraryAPIError(code: "unavailable", message: "") }
    func adopt(_ body: Data) throws {}
    func unlockDefaultAgent(workspace: String, unlockKey: String) -> Bool { false }
    func configureDefaultAgent(_ payload: Data) throws -> DefaultAgentSyncReceipt { throw LibraryAPIError(code: "unavailable", message: "") }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A settings model for one device: its own Keychain, its own helper.
@MainActor
private func deviceModel(_ keychain: SignInKeychainFixture, helper: FakeSettingsHelper) -> DefaultAgentSettingsModel {
    let model = KeychainAccess.$testOperations.withValue(keychain.operations) { DefaultAgentSettingsModel() }
    model.helperLaunch = { helper.launch }
    let operations = keychain.operations
    model.preparePayload = { scope in
        try KeychainAccess.$testOperations.withValue(operations) { try DefaultAgentSupport.snapshot(workspace: scope) }
    }
    return model
}

@Suite("Per-device sign-ins", .serialized)
@MainActor
struct SignInDeviceTests {
    @Test func signingInOnThisMacKeepsTheCredentialInItsKeychain() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let model = deviceModel(keychain, helper: helper)
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            model.selectDevice(SignInDevice.localID)
            model.signIn("openai-codex")
            try await waitUntil { model.prompt != nil }
            #expect(model.signInURL?.absoluteString == "https://auth.example.test/device")
            #expect(model.signInCode == "WOVEN-1234")
            model.respond("pasted-code")
            try await waitUntil { model.signInOutcome != nil && !model.busy }
            #expect(model.signInOutcome?.error == nil)
            #expect(model.accounts["openai-codex"]?.map(\.label) == ["person@example.test"])
        }
        let stored = try #require(keychain.stored.first { $0.key.hasSuffix("/global.oauth.openai-codex") }?.value)
        #expect(stored.contains("fixture-refresh"))
        #expect(helper.requests.contains("{\"answer\":\"pasted-code\",\"answerTo\":\"code-1\"}") || helper.requests.contains { $0.contains("pasted-code") })
        #expect(!keychain.stored.keys.contains { $0.contains("/local.") })
    }

    @Test func signingInOnALinuxWorkspaceStoresNothingOnThisMac() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let host = FakeLinuxSignInHost(), workspace = UUID()
        let model = deviceModel(keychain, helper: helper)
        model.memberRoutes = { id in
            #expect(id == workspace)
            return host
        }
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            model.selectDevice(SignInDevice.linuxID(workspace))
            #expect(model.device == SignInDevice.linuxID(workspace))
            // A typed API key goes once to the workspace and is saved there.
            #expect(await model.saveKeyConfirmed("linux-secret", provider: "openai", label: "Work"))
            #expect(model.accounts["openai"]?.map(\.label) == ["Work"])
            // A subscription signs in on the workspace; only the link, code and answer pass here.
            model.signIn("openai-codex")
            try await waitUntil { model.prompt != nil }
            #expect(model.signInCode == "HOST-1234")
            model.respond("pasted-host-code")
            try await waitUntil { model.signInOutcome != nil && !model.busy }
            #expect(model.signInOutcome?.error == nil)
            try await waitUntil { model.accounts["openai-codex"]?.isEmpty == false }
        }
        #expect(await host.keys["openai"]?.map(\.key) == ["linux-secret"])
        #expect(await host.subscriptions["openai-codex"] != nil)
        #expect(await host.answers == ["pasted-host-code"])
        // The workspace got chat settings, never this Mac's credentials or a key.
        let requests = await host.controlRequests.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let login = try #require(requests.first { $0["action"] as? String == "login" })
        #expect((login["credentials"] as? [String: Any])?.isEmpty == true)
        #expect(login["unlockKey"] == nil && login["credentialAccounts"] == nil)
        #expect(keychain.stored.isEmpty)
        #expect(helper.requests.isEmpty)
    }

    @Test func signingInOnAnotherMacRunsThereAndStoresNothingHere() async throws {
        let here = SignInKeychainFixture(), there = SignInKeychainFixture()
        let localHelper = try FakeSettingsHelper(), peerHelper = try FakeSettingsHelper()
        defer { localHelper.remove(); peerHelper.remove() }
        // The other Mac: its own model, Keychain and helper behind its signed route.
        let peer = deviceModel(there, helper: peerHelper)
        let operations = there.operations
        let model = deviceModel(here, helper: localHelper)
        let memberID = UUID().uuidString.lowercased()
        var routed: [String] = []
        model.peerTransport = { member in
            #expect(member == memberID)
            return { method, payload in
                let path = method == "connections.command" ? "/v1/connections/command" : "/v1/connections/snapshot"
                routed.append(path)
                let response = await KeychainAccess.$testOperations.withValue(operations) {
                    await ApplicationModel.memberSignIns(method: "POST", path: path, body: method == "connections.command" ? payload : Data("{}".utf8), model: peer)
                }
                guard response.status == 200 else { throw DefaultAgentError.message(String(decoding: response.body, as: UTF8.self)) }
                return response.body
            }
        }
        try await KeychainAccess.$testOperations.withValue(here.operations) {
            model.selectDevice(SignInDevice.macID(memberID))
            try await waitUntil { !model.busy && !routed.isEmpty }
            #expect(await model.saveKeyConfirmed("peer-secret", provider: "openai", label: "Peer key"))
            try await waitUntil { model.accounts["openai"]?.map(\.label) == ["Peer key"] }
            model.signIn("openai-codex")
            try await waitUntil { model.prompt != nil }
            #expect(model.signInURL?.absoluteString == "https://auth.example.test/device")
            #expect(model.signInCode == "WOVEN-1234")
            model.respond("pasted-peer-code")
            try await waitUntil { model.signInOutcome != nil && !model.busy }
            #expect(model.signInOutcome?.error == nil)
            #expect(model.device == SignInDevice.macID(memberID))
        }
        #expect(there.stored.contains { $0.key.hasSuffix("/global.openai") && $0.value == "peer-secret" })
        #expect(there.stored.contains { $0.key.hasSuffix("/global.oauth.openai-codex") && $0.value.contains("fixture-refresh") })
        #expect(peerHelper.requests.contains { $0.contains("pasted-peer-code") })
        #expect(here.stored.isEmpty)
        #expect(localHelper.requests.isEmpty)
        // The route refuses anything but that Mac's own sign-ins.
        let refused = await ApplicationModel.memberSignIns(method: "POST", path: "/v1/connections/command",
            body: try JSONEncoder().encode(BackendConnectionsCommand(action: "device", value: "local")), model: peer)
        #expect(refused.status == 400)
        let remote = await ApplicationModel.memberSignIns(method: "GET", path: "/v1/connections/snapshot", body: Data(), model: peer)
        #expect(remote.status == 404)
    }

    @Test func devicesAreListedThisMacFirstAndBotsFindTheirDevice() {
        let devices = SignInDevice.ordered([
            .init(id: SignInDevice.linuxID("b0000000-0000-4000-8000-000000000000"), kind: .linux, name: "workstation", runsBots: true,
                  memberID: "linux-member", workspaceID: "b0000000-0000-4000-8000-000000000000"),
            .init(id: SignInDevice.macID("mac-b"), kind: .mac, name: "mac-mini", runsBots: false, memberID: "mac-b"),
            .init(id: SignInDevice.macID("mac-a"), kind: .mac, name: "macbook-air", runsBots: false, memberID: "mac-a"),
            .init(id: SignInDevice.localID, kind: .thisMac, name: "studio", runsBots: false, memberID: "this-mac"),
        ])
        #expect(devices.map(\.name) == ["studio", "mac-mini", "macbook-air", "workstation"])
        #expect(SignInDevice.id(forBotMachine: "LINUX-MEMBER", in: devices) == SignInDevice.linuxID("b0000000-0000-4000-8000-000000000000"))
        #expect(SignInDevice.id(forBotMachine: "this-mac", in: devices) == SignInDevice.localID)
        #expect(SignInDevice.id(forBotMachine: "mac-a", in: devices) == SignInDevice.macID("mac-a"))
        #expect(SignInDevice.tailnetName("mac-mini.tail1234.ts.net") == "mac-mini")
        #expect(SignInDevice.id(forScope: "global") == SignInDevice.localID)
        #expect(SignInDevice.id(forScope: "B0000000-0000-4000-8000-000000000000") == SignInDevice.linuxID("b0000000-0000-4000-8000-000000000000"))
        #expect(SignInDevice.linuxWorkspace(of: devices[3].id)?.uuidString.lowercased() == "b0000000-0000-4000-8000-000000000000")
    }

    @Test func usageLimitsReadOnlyThisDevicesAccounts() throws {
        let keychain = SignInKeychainFixture()
        let access = KeychainAccess(operations: keychain.operations)
        _ = try ProviderConnectionAccounts.addKey("device-key", provider: "openai", label: "Device", keychain: access)
        _ = try ProviderConnectionAccounts.addKey("legacy-key", provider: "openai", scope: "local", label: "Legacy", keychain: access)
        _ = try ProviderConnectionAccounts.addKey("remote-key", provider: "openrouter", scope: UUID().uuidString.lowercased(), keychain: access)
        let choices = try LocalUsageService.deviceConnectionChoices([.codex, .openRouter], keychain: access)
        #expect(choices.map(\.label) == ["API key · Device"])
    }
}
