import CryptoKit
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
    private var readNames: [String] = []
    private func name(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")/\(query[kSecAttrAccount as String] as? String ?? "")"
    }
    var stored: [String: String] { lock.withLock { values.mapValues { String(decoding: $0, as: UTF8.self) } } }
    /// Every item read, by account name.
    var reads: [String] { lock.withLock { readNames } }
    var operations: KeychainOperations {
        KeychainOperations(
            copyMatching: { [self] query in
                lock.withLock {
                    readNames.append(query[kSecAttrAccount as String] as? String ?? "")
                    return values[name(query)].map { (errSecSuccess, $0 as CFData) } ?? (errSecItemNotFound, nil)
                }
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
    func signIns() throws -> DeviceSignIns {
        if outdated { throw LibraryAPIError(code: "not_found", message: "not_found") }
        return try view()
    }
    func changeSignIns(_ change: DeviceSignInChange) throws -> DeviceSignIns {
        if outdated { throw LibraryAPIError(code: "not_found", message: "not_found") }
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
    /// A host that has not updated has no `v1/sign-ins`.
    private(set) var outdated = false
    func makeOutdated() { outdated = true }
    func uploadAttachment(_ data: Data, sha256: String, name: String, mimeType: String) throws -> LibraryAttachmentReference { throw LibraryAPIError(code: "unavailable", message: "") }
    func sessionOptions(providerID: String, workingDirectory: String?, model: String?) throws -> SessionSettings { throw LibraryAPIError(code: "unavailable", message: "") }
    func libraryFile(conversationID: String?, path: String) throws -> MemberLibraryFile { throw LibraryAPIError(code: "unavailable", message: "") }
    func adopt(_ body: Data) throws {}
    func unlockDefaultAgent(workspace: String, unlockKey: String) -> Bool { false }
    func configureDefaultAgent(_ payload: Data) throws -> DefaultAgentSyncReceipt { throw LibraryAPIError(code: "unavailable", message: "") }
}

@MainActor
private func waitUntil(_ model: DefaultAgentSettingsModel, timeout: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation,
                       _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out: busy=\(model.busy) error=\(model.error ?? "-") outcome=\(String(describing: model.signInOutcome)) prompt=\(model.prompt ?? "-")",
                         sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A settings model for one device: its own Keychain, its own helper.
@MainActor
private func deviceModel(_ keychain: SignInKeychainFixture, helper: FakeSettingsHelper) -> DefaultAgentSettingsModel {
    let model = KeychainAccess.$testOperations.withValue(keychain.operations) { DefaultAgentSettingsModel() }
    model.helperLaunch = { helper.launch }
    let operations = keychain.operations
    // Its own coordinator: no other test's sign-in or renewal can hold this one up.
    model.coordinator = ProviderAccountCoordinator(refresh: { scopes in
        try KeychainAccess.$testOperations.withValue(keychain.operations) {
            Dictionary(uniqueKeysWithValues: try scopes.map { ($0, try DefaultAgentSupport.snapshot(workspace: $0)) })
        }
    })
    model.preparePayload = { scope in
        try KeychainAccess.$testOperations.withValue(operations) { try DefaultAgentSupport.snapshot(workspace: scope) }
    }
    return model
}

/// Another Mac's route to `peer`, as this Mac's background server reaches it.
@MainActor
private func peerRoute(_ peer: DefaultAgentSettingsModel, keychain: SignInKeychainFixture)
    -> @MainActor @Sendable (String) -> (String, Data) async throws -> Data {
    let operations = keychain.operations
    return { _ in
        { method, payload in
            let path = method == "connections.command" ? "/v1/connections/command" : "/v1/connections/snapshot"
            let response = await KeychainAccess.$testOperations.withValue(operations) {
                await ApplicationModel.memberSignIns(method: "POST", path: path, body: method == "connections.command" ? payload : Data("{}".utf8), model: peer)
            }
            guard response.status == 200 else { throw DefaultAgentError.message(String(decoding: response.body, as: UTF8.self)) }
            return response.body
        }
    }
}

@MainActor
private func command(_ value: BackendConnectionsCommand, on model: DefaultAgentSettingsModel, keychain: SignInKeychainFixture) async -> LibraryHTTPResponse {
    let body = (try? JSONEncoder().encode(value)) ?? Data()
    return await KeychainAccess.$testOperations.withValue(keychain.operations) {
        await ApplicationModel.memberSignIns(method: "POST", path: "/v1/connections/command", body: body, model: model)
    }
}

@Suite("Per-device sign-ins", .serialized)
@MainActor
struct SignInDeviceTests {
    /// The exploit: another Mac asks this Mac to "reconnect" a local model server
    /// whose ID is this Mac's ChatGPT sign-in, at the attacker's URL, with no key,
    /// so the saved key would be sent there as a bearer token.
    @Test func anotherMacCannotMakeThisMacSendAStoredSecretAnywhere() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let peer = deviceModel(keychain, helper: helper)
        var secret = DefaultAgentCredential(type: "oauth"); secret.access = "a"; secret.refresh = "device-refresh-token"; secret.expires = 9000000000000
        try KeychainAccess.$testOperations.withValue(keychain.operations) {
            _ = try ProviderConnectionAccounts.addOAuth(secret, provider: "openai-codex")
            try DefaultAgentSupport.saveKey("vault-key", provider: "encryption-key", scope: "0f0e0d0c-0b0a-4908-8706-050403020100", notify: false)
        }
        let before = keychain.stored, readsBefore = keychain.reads.count
        let attacker = LocalModelServer(id: "oauth.openai-codex", url: "https://attacker.example/v1", models: ["m"])
        let attempts: [BackendConnectionsCommand] = [
            .init(action: "connectServer", value: "", label: attacker.url, server: attacker),
            .init(action: "connectServer", value: nil, label: attacker.url, server: .init(id: "encryption-key", url: attacker.url, models: [])),
            .init(action: "removeServer", server: attacker),
            .init(action: "saveKey", provider: "oauth.openai-codex", value: "overwrite"),
            .init(action: "remove", provider: "encryption-key", value: "x"),
            .init(action: "select", provider: "../global.oauth.openai-codex", value: "x"),
            .init(action: "signOut", provider: "encryption-key"),
            .init(action: "refresh", provider: "openai-codex", value: "probe-server"),
            .init(action: "refresh", provider: "claude-subscription", profile: "../../elsewhere"),
            .init(action: "checkKeychain"), .init(action: "devices"), .init(action: "device", value: "local"),
            .init(action: "inherits", flag: true), .init(action: "unknown"),
        ]
        for attempt in attempts {
            let response = await command(attempt, on: peer, keychain: keychain)
            #expect(response.status == 400, "\(attempt.action) \(attempt.provider ?? "")")
        }
        // Nothing was read that a member can learn, sent anywhere, or changed.
        #expect(!keychain.reads.dropFirst(readsBefore).contains("global.oauth.openai-codex"))
        #expect(!keychain.reads.dropFirst(readsBefore).contains { $0.hasSuffix(".encryption-key") })
        #expect(keychain.stored == before)
        // The same request from this Mac's own window is refused at the root too.
        for attempt in attempts.prefix(3) {
            await #expect(throws: (any Error).self) {
                _ = try await KeychainAccess.$testOperations.withValue(keychain.operations) {
                    try await BackendConnectionsService.handle(method: "connections.command", payload: JSONEncoder().encode(attempt), model: peer)
                }
            }
        }
        #expect(!keychain.reads.dropFirst(readsBefore).contains("global.oauth.openai-codex"))
        #expect(keychain.stored == before)
    }

    /// `/v1/connections/*` through this Mac's server authentication: Mac members only.
    @Test func onlySignedMacMembersReachThisMacsSignIns() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let host = LibraryHostController(model: fixture.model, defaults: fixture.defaults, supportDirectory: fixture.directory, peerStorage: .memory())
        let directory = try await host.peerSync.members()
        try await directory.ensureSelf(name: "This Mac", endpoints: [])
        let audience = directory.identity.deviceID
        let mac = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
        let phone = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .ios, key: .init())
        let linux = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
        let stranger = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
        for member in [mac, phone, linux] {
            try await directory.add(deviceID: member.deviceID, kind: member.kind, name: member.kind.rawValue, publicKey: member.publicKey, endpoints: [])
        }
        let session = MemberSignInSession(model: deviceModel(keychain, helper: helper))
        fixture.model.memberSignInSessions[mac.deviceID] = session
        func call(_ signer: MemberIdentity?, _ path: String, body: Data = Data("{}".utf8)) async throws -> LibraryHTTPResponse {
            var headers: [String: String] = [:]
            if let signer { headers = try signer.signer.headers(method: "POST", target: path, body: body, audience: audience) }
            let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
            return await KeychainAccess.$testOperations.withValue(keychain.operations) {
                await host.memberSignIns(.init(method: "POST", target: path, headers: lowered, body: body), path: path)
            }
        }
        for path in ["/v1/connections/snapshot", "/v1/connections/command"] {
            let body = path.hasSuffix("command") ? try JSONEncoder().encode(BackendConnectionsCommand(action: "accounts")) : Data("{}".utf8)
            #expect(try await call(mac, path, body: body).status == 200, "\(path)")
            for refused in [phone, linux, stranger] {
                #expect(try await call(refused, path, body: body).status == 401, "\(refused.kind) \(path)")
            }
            #expect(try await call(nil, path, body: body).status == 401)
        }
        #expect(fixture.model.memberSignInSessions.keys.sorted() == [mac.deviceID])
        // A member's view is this Mac's own device scope and chat settings, and its
        // sign-in never holds this Mac's renewal lease.
        let model = ApplicationModel.memberSignInModel()
        #expect(model.scope == "global" && !model.inherits && !model.holdsSignInLease)
        let scoped = await command(.init(action: "scope", value: "local"), on: session.model, keychain: keychain)
        #expect(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: scoped.body).scope == "global")
    }

    /// Leaving another Mac while a sign-in runs there cancels it there.
    @Test(arguments: ["selectDevice", "changeScope"])
    func leavingAnotherMacMidSignInCancelsItThere(_ leave: String) async throws {
        let here = SignInKeychainFixture(), there = SignInKeychainFixture()
        let localHelper = try FakeSettingsHelper(), peerHelper = try FakeSettingsHelper()
        defer { localHelper.remove(); peerHelper.remove() }
        let peer = deviceModel(there, helper: peerHelper)
        let model = deviceModel(here, helper: localHelper)
        model.peerTransport = peerRoute(peer, keychain: there)
        let memberID = UUID().uuidString.lowercased()
        try await KeychainAccess.$testOperations.withValue(here.operations) {
            model.selectDevice(SignInDevice.macID(memberID))
            try await waitUntil(model) { !model.busy }
            model.signIn("openai-codex")
            try await waitUntil(model) { model.prompt != nil }
            #expect(peer.busy && peer.signInProvider == "openai-codex")
            if leave == "selectDevice" { model.selectDevice(SignInDevice.localID) } else { model.changeScope("global") }
            try await waitUntil(peer) { !peer.busy && peer.signInProvider == nil }
        }
        #expect(!there.stored.keys.contains { $0.hasSuffix("oauth.openai-codex") })
    }

    /// A member that stops polling (it slept or went offline) has its sign-in cancelled here.
    @Test func aMemberThatStopsPollingHasItsSignInCancelledHere() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let session = MemberSignInSession(model: deviceModel(keychain, helper: helper), idleLimit: .milliseconds(300))
        let peer = session.model
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            session.touch()
            #expect(await command(.init(action: "refresh", provider: "openai-codex"), on: peer, keychain: keychain).status == 200)
            try await waitUntil(peer) { peer.prompt != nil }
            // While it polls, the sign-in waits for the user.
            for _ in 0..<4 { session.touch(); try await Task.sleep(for: .milliseconds(150)) }
            #expect(peer.busy)
            try await waitUntil(peer, timeout: .seconds(10)) { !peer.busy && peer.signInProvider == nil }
        }
    }

    /// A member's sign-in here never holds this Mac's lease: its own sign-ins and
    /// renewal for Pi Durable and bots go on while one waits.
    @Test func aMembersSignInNeverBlocksThisMacsOwnRenewal() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let peer = deviceModel(keychain, helper: helper)
        peer.holdsSignInLease = false
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            peer.signIn("openai-codex")
            try await waitUntil(peer) { peer.prompt != nil }
            let lease = try await peer.coordinator.beginSignIn()
            peer.coordinator.endSignIn(lease)
            peer.coordinator.invalidate()
            _ = try await peer.coordinator.prepare("global")
            peer.cancel()
        }
    }

    /// A command a window issued for one device never lands on another.
    @Test func aCommandIssuedForAnotherDeviceIsRefused() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let backend = deviceModel(keychain, helper: helper)
        let stale = BackendConnectionsCommand(action: "saveKey", provider: "openai", value: "meant-for-another-mac", device: SignInDevice.macID("other"))
        await #expect(throws: (any Error).self) {
            _ = try await KeychainAccess.$testOperations.withValue(keychain.operations) {
                try await BackendConnectionsService.handle(method: "connections.command", payload: JSONEncoder().encode(stale), model: backend)
            }
        }
        #expect(keychain.stored.isEmpty)
        // A window names the device each command is for.
        let window = DefaultAgentSettingsModel()
        var sent: [BackendConnectionsCommand] = []
        window.backendRequest = { method, payload in
            if method == "connections.command" { sent.append(try JSONDecoder().decode(BackendConnectionsCommand.self, from: payload)) }
            return try await KeychainAccess.$testOperations.withValue(keychain.operations) {
                try await BackendConnectionsService.handle(method: method, payload: payload, model: backend)
            }
        }
        window.selectDevice(SignInDevice.macID("other"))
        _ = await window.saveKeyConfirmed("typed-here", provider: "openai")
        #expect(sent.last?.action == "saveKey" && sent.last?.device == SignInDevice.macID("other"))
        #expect(keychain.stored.isEmpty)
    }

    /// A Linux host that has not updated answers with the existing update message.
    @Test func anOutdatedLinuxHostAsksForAnUpdate() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let host = FakeLinuxSignInHost(), workspace = UUID()
        await host.makeOutdated()
        let model = deviceModel(keychain, helper: helper)
        model.memberRoutes = { _ in host }
        model.devices = [.init(id: SignInDevice.linuxID(workspace), kind: .linux, name: "workstation", runsBots: false, workspaceID: workspace.uuidString.lowercased())]
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            model.selectDevice(SignInDevice.linuxID(workspace))
            try await waitUntil(model) { model.error != nil }
            #expect(model.error == "Update Woven Matter on workstation to manage its sign-ins from here.")
            #expect(!(await model.saveKeyConfirmed("k", provider: "openai")))
            #expect(model.error == "Update Woven Matter on workstation to manage its sign-ins from here.")
        }
    }

    /// A Linux host that has not updated keeps working exactly as before; an
    /// updated one gets chat settings alone and, once nothing waits for this
    /// Mac's key there, this Mac's copies for it are removed.
    @Test func linuxHostsAreConfiguredForTheVaultTheyHave() async throws {
        let scope = UUID().uuidString.lowercased()
        defer { DefaultAgentSupport.markLegacyHost(scope, false) }
        let settings = try DefaultAgentSupport.configurationPayload(workspace: scope)
        var relayedPayload = DefaultAgentPayload(config: .init(), credentials: ["openai": .init(type: "api_key", key: "workspace-key")], workspace: scope)
        relayedPayload.unlockKey = "vault-key"
        let relayed = relayedPayload
        let legacy: @Sendable (String) async throws -> DefaultAgentPayload = { _ in relayed }
        let key: @Sendable (String) async throws -> String? = { _ in "vault-key" }
        // Not updated: what it got before, and this Mac renews what it relays.
        let old = try await DefaultAgentHostSync.payload(scope: scope, vault: .init(), settingsOnly: settings, legacy: legacy, vaultKey: key)
        #expect(old.credentials["openai"]?.key == "workspace-key" && old.unlockKey == "vault-key")
        #expect(DefaultAgentSupport.legacyHostScopes.contains(scope))
        // Updated, with a vault sealed with this Mac's key waiting: settings and the key once.
        let pending = try await DefaultAgentHostSync.payload(scope: scope, vault: .init(deviceVault: true, legacyVault: true), settingsOnly: settings, legacy: legacy, vaultKey: key)
        #expect(pending.credentials.isEmpty && pending.credentialAccounts == nil && pending.unlockKey == "vault-key")
        #expect(!DefaultAgentSupport.legacyHostScopes.contains(scope))
        let current = try await DefaultAgentHostSync.payload(scope: scope, vault: .init(deviceVault: true, legacyVault: false), settingsOnly: settings, legacy: legacy, vaultKey: key)
        #expect(current.credentials.isEmpty && current.unlockKey == nil)
        // Copies are forgotten only once the host keeps its own vault with nothing waiting.
        let forgotten = ForgottenScopes()
        for (json, forgets) in [(#"{"saved":true,"revision":"r","epoch":"e"}"#, false),
                                (#"{"saved":true,"revision":"r","epoch":"e","deviceVault":true,"legacyVault":true}"#, false),
                                (#"{"saved":true,"revision":"r","epoch":"e","deviceVault":true,"legacyVault":false}"#, true)] {
            let receipt = try JSONDecoder().decode(DefaultAgentSyncReceipt.self, from: Data(json.utf8))
            let before = await forgotten.scopes.count
            await DefaultAgentHostSync.acknowledged(receipt, scope: scope) { await forgotten.add($0) }
            #expect(await forgotten.scopes.count == before + (forgets ? 1 : 0), "\(json)")
        }
    }


    @Test func signingInOnThisMacKeepsTheCredentialInItsKeychain() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let model = deviceModel(keychain, helper: helper)
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            model.selectDevice(SignInDevice.localID)
            model.signIn("openai-codex")
            try await waitUntil(model) { model.prompt != nil }
            #expect(model.signInURL?.absoluteString == "https://auth.example.test/device")
            #expect(model.signInCode == "WOVEN-1234")
            model.respond("pasted-code")
            try await waitUntil(model) { model.signInOutcome != nil && !model.busy }
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
            try await waitUntil(model) { model.prompt != nil }
            #expect(model.signInCode == "HOST-1234")
            model.respond("pasted-host-code")
            try await waitUntil(model) { model.signInOutcome != nil && !model.busy }
            #expect(model.signInOutcome?.error == nil)
            try await waitUntil(model) { model.accounts["openai-codex"]?.isEmpty == false }
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
            try await waitUntil(model) { !model.busy && !routed.isEmpty }
            #expect(await model.saveKeyConfirmed("peer-secret", provider: "openai", label: "Peer key"))
            try await waitUntil(model) { model.accounts["openai"]?.map(\.label) == ["Peer key"] }
            model.signIn("openai-codex")
            try await waitUntil(model) { model.prompt != nil }
            #expect(model.signInURL?.absoluteString == "https://auth.example.test/device")
            #expect(model.signInCode == "WOVEN-1234")
            model.respond("pasted-peer-code")
            try await waitUntil(model) { model.signInOutcome != nil && !model.busy }
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

private actor ForgottenScopes {
    var scopes: [String] = []
    func add(_ scope: String) { scopes.append(scope) }
}
