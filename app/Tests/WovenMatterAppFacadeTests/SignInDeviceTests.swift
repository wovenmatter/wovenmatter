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
        return try view()
    }
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
    func createProject(name: String) throws -> RemoteProjectDirectory { throw LibraryAPIError(code: "unavailable", message: "") }
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
    /// A host that has not updated has no `sign-ins`.
    func uploadAttachment(_ data: Data, sha256: String, name: String, mimeType: String) throws -> LibraryAttachmentReference { throw LibraryAPIError(code: "unavailable", message: "") }
    func sessionOptions(providerID: String, workingDirectory: String?, model: String?) throws -> SessionSettings { throw LibraryAPIError(code: "unavailable", message: "") }
    func libraryFile(conversationID: String?, path: String) throws -> MemberLibraryFile { throw LibraryAPIError(code: "unavailable", message: "") }
    func adopt(_ body: Data) throws {}
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
            let path = method == "connections.command" ? "/connections/command" : "/connections/snapshot"
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
        await ApplicationModel.memberSignIns(method: "POST", path: "/connections/command", body: body, model: model)
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

    /// `/connections/*` through this Mac's server authentication: Mac members only.
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
        for path in ["/connections/snapshot", "/connections/command"] {
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

    /// A network blip while signing in on another Mac neither ends the sign-in here
    /// nor lets that Mac give up on it.
    @Test func aSignInOnAnotherMacSurvivesTransientFailures() async throws {
        #expect(MemberSignInSession.defaultIdleLimit > DefaultAgentSettingsModel.pollRetryLimit)
        let here = SignInKeychainFixture(), there = SignInKeychainFixture()
        let localHelper = try FakeSettingsHelper(), peerHelper = try FakeSettingsHelper()
        defer { localHelper.remove(); peerHelper.remove() }
        let peer = deviceModel(there, helper: peerHelper)
        let model = deviceModel(here, helper: localHelper)
        let route = peerRoute(peer, keychain: there)
        let failures = FailureBudget()
        model.peerTransport = { member in
            let send = route(member)
            return { method, payload in
                if method == "connections.snapshot", await failures.take() { throw DefaultAgentError.message("The network connection was lost.") }
                return try await send(method, payload)
            }
        }
        try await KeychainAccess.$testOperations.withValue(here.operations) {
            model.selectDevice(SignInDevice.macID(UUID().uuidString.lowercased()))
            try await waitUntil(model) { !model.busy }
            await failures.arm(4)
            model.signIn("openai-codex")
            try await waitUntil(model) { model.prompt != nil }
            #expect(model.error == nil && model.busy)
            #expect(await failures.remaining == 0)
            model.respond("pasted-code")
            try await waitUntil(model) { model.signInOutcome != nil && !model.busy }
            #expect(model.signInOutcome?.error == nil)
        }
        #expect(there.stored.contains { $0.key.hasSuffix("/global.oauth.openai-codex") })
    }

    /// Once no window shows a sign-in on another Mac for two minutes, this Mac's
    /// background server stops following it and cancels it there; a window whose
    /// timers are stretched while the user is in the browser is not "gone".
    @Test func noWindowLeftStopsFollowingASignInOnAnotherMac() async throws {
        #expect(DefaultAgentSettingsModel.windowIdleLimit >= .seconds(120))
        #expect(DefaultAgentSettingsModel.windowIdleLimit >= DefaultAgentSettingsModel.pollRetryLimit)
        let here = SignInKeychainFixture(), there = SignInKeychainFixture()
        let localHelper = try FakeSettingsHelper(), peerHelper = try FakeSettingsHelper()
        defer { localHelper.remove(); peerHelper.remove() }
        let peer = deviceModel(there, helper: peerHelper)
        let model = deviceModel(here, helper: localHelper)
        model.peerTransport = peerRoute(peer, keychain: there)
        let start = ContinuousClock.now
        var offset: Duration = .zero
        model.now = { start + offset }
        try await KeychainAccess.$testOperations.withValue(here.operations) {
            model.selectDevice(SignInDevice.macID(UUID().uuidString.lowercased()))
            try await waitUntil(model) { !model.busy }
            model.noteWindowContact()
            model.signIn("openai-codex")
            try await waitUntil(model) { model.prompt != nil }
            // A minute and a half without a window poll (the user is in the browser): still signing in.
            offset = .seconds(90)
            try await Task.sleep(for: .milliseconds(800))
            #expect(peer.busy && model.busy && !model.windowsGone)
            // A window asks again: the clock restarts.
            model.noteWindowContact(); offset = .seconds(200)
            try await Task.sleep(for: .milliseconds(500))
            #expect(peer.busy && !model.windowsGone)
            // Then no window at all for longer than the limit.
            offset = .seconds(200) + DefaultAgentSettingsModel.windowIdleLimit + .seconds(1)
            try await waitUntil(peer, timeout: .seconds(10)) { !peer.busy && peer.signInProvider == nil }
            try await waitUntil(model, timeout: .seconds(10)) { !model.busy }
        }
        #expect(!there.stored.keys.contains { $0.hasSuffix("oauth.openai-codex") })
    }

    /// A window polling a sign-in holds an activity, so App Nap cannot stretch its polling.
    @Test func aWindowPollingASignInHoldsAnActivity() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let backend = deviceModel(keychain, helper: helper)
        let window = DefaultAgentSettingsModel()
        window.backendRequest = { method, payload in
            try await KeychainAccess.$testOperations.withValue(keychain.operations) {
                try await BackendConnectionsService.handle(method: method, payload: payload, model: backend)
            }
        }
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            window.signIn("openai-codex")
            try await waitUntil(window) { window.prompt != nil }
            #expect(window.busy && window.holdsPollingActivity)
            window.cancel()
            try await waitUntil(window) { !window.busy && !window.holdsPollingActivity }
        }
        // The background server's own model holds none.
        #expect(!backend.holdsPollingActivity)
    }

    /// A failed command releases a window's polling activity: it is held only while busy.
    @Test func aFailedCommandReleasesTheWindowsActivity() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let backend = deviceModel(keychain, helper: helper)
        let window = DefaultAgentSettingsModel()
        let failing = FailureBudget()
        window.backendRequest = { method, payload in
            if method == "connections.command", await failing.take() { throw DefaultAgentError.message("The background service is not connected.") }
            return try await KeychainAccess.$testOperations.withValue(keychain.operations) {
                try await BackendConnectionsService.handle(method: method, payload: payload, model: backend)
            }
        }
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            window.signIn("openai-codex")
            try await waitUntil(window) { window.prompt != nil && window.holdsPollingActivity }
            await failing.arm(1)
            window.respond("pasted-code")
            try await waitUntil(window) { !window.busy }
            #expect(window.error != nil && !window.holdsPollingActivity)
            backend.cancel()
        }
    }

    /// A freshly started background server has no active work in either settings
    /// model, and a sign-in in progress never holds up a stop: stop cancels it.
    @Test func stopNeverWaitsOnASignIn() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let model = fixture.model
        // A stopping server takes no new sign-in work from another Mac.
        model.backendStopping = true
        let refused = await model.memberSignIns(.init(method: "POST", target: "/connections/snapshot", headers: [:], body: Data("{}".utf8)),
                                                path: "/connections/snapshot", memberID: UUID().uuidString.lowercased())
        #expect(refused.status == 503 && model.memberSignInSessions.isEmpty)
        model.backendStopping = false
        #expect(!model.connections.busy && !model.signInConnections.busy)
        #expect(!model.backendHasUnfinishedMaintenance)
        model.signInConnections.busy = true
        #expect(!model.backendHasUnfinishedMaintenance)
        model.connections.busy = true
        #expect(model.backendHasUnfinishedMaintenance)
        model.connections.busy = false
        model.signInConnections.busy = false
    }

    /// The device chosen on Subscriptions & API Keys has its own model, window and
    /// background server alike: the setup window, Pi Durable pages, chats and task
    /// defaults read and write this Mac's own model, never see that Mac's values,
    /// and opening one never drops that Mac or cancels its sign-in.
    @Test func otherViewsNeverSeeOrDisturbAnotherMacChosenForSigningIn() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let backend = fixture.model
        let here = SignInKeychainFixture(), there = SignInKeychainFixture()
        let localHelper = try FakeSettingsHelper(), peerHelper = try FakeSettingsHelper()
        defer { localHelper.remove(); peerHelper.remove() }
        let peer = deviceModel(there, helper: peerHelper)
        let route = peerRoute(peer, keychain: there)
        backend.signInConnections.peerTransport = { member in
            let send = route(member)
            return { method, payload in
                var snapshot = try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: try await send(method, payload))
                snapshot.settings.global.defaultModel = "peer-provider/peer-only-model"
                snapshot.providers = [.init(id: "peer-provider", name: "Peer", connected: true, state: nil, detail: nil, account: nil)]
                snapshot.catalog = [.init(id: "peer-provider/peer-only-model", name: "Peer only", provider: "peer-provider", providerName: "Peer")]
                return try JSONEncoder().encode(snapshot)
            }
        }
        func window(_ map: @escaping @Sendable (String) -> String) -> DefaultAgentSettingsModel {
            let value = DefaultAgentSettingsModel()
            value.backendRequest = { method, payload in
                let response = await backend.handleBackendRequest(.init(method: map(method), payload: payload))
                if let error = response.error { throw DefaultAgentError.message(error) }
                return response.result ?? Data()
            }
            return value
        }
        let page = window { ApplicationModel.signInBackendMethod($0) }
        let setup = window { $0 }
        let own = DefaultAgentSupport.settings.global.defaultModel
        try await KeychainAccess.$testOperations.withValue(here.operations) {
            page.selectDevice(SignInDevice.macID(UUID().uuidString.lowercased()))
            try await waitUntil(page) { !page.busy && page.configuration.defaultModel == "peer-provider/peer-only-model" }
            // (A) The setup window's Pi Durable settings are this Mac's.
            setup.changeScope("global")
            setup.loadAccounts()
            try await Task.sleep(for: .milliseconds(300))
            #expect(setup.device == SignInDevice.localID && backend.connections.device == SignInDevice.localID)
            #expect(setup.configuration.defaultModel == own && backend.connections.configuration.defaultModel == own)
            #expect(!setup.providers.contains { $0.id == "peer-provider" } && !setup.catalog.contains { $0.provider == "peer-provider" })
            // (B) A sign-in running on that Mac survives opening the setup window for a Linux workspace.
            page.signIn("openai-codex")
            try await waitUntil(page) { page.prompt != nil }
            setup.changeScope(UUID().uuidString.lowercased())
            try await Task.sleep(for: .milliseconds(500))
            #expect(peer.busy && peer.signInProvider == "openai-codex")
            #expect(page.device.hasPrefix("mac:") && backend.signInConnections.device.hasPrefix("mac:") && page.busy)
            page.cancel()
            try await waitUntil(peer) { !peer.busy }
            // A Pi Durable page's model can never be pointed at another device.
            let before = backend.connections.device
            setup.selectDevice(SignInDevice.linuxID(UUID()))
            try await Task.sleep(for: .milliseconds(300))
            #expect(backend.connections.device == before)
            let refused = await backend.handleBackendRequest(.init(method: "connections.command",
                payload: try JSONEncoder().encode(BackendConnectionsCommand(action: "device", value: SignInDevice.linuxID(UUID())))))
            #expect(refused.error != nil && backend.connections.device == before)
        }
    }

    /// Leaving Subscriptions & API Keys returns to this Mac, so this Mac's own
    /// settings views never show or save another Mac's chat settings or catalog.
    @Test func leavingThePageReturnsToThisMacsOwnSettings() async throws {
        let here = SignInKeychainFixture(), there = SignInKeychainFixture()
        let localHelper = try FakeSettingsHelper(), peerHelper = try FakeSettingsHelper()
        defer { localHelper.remove(); peerHelper.remove() }
        let peer = deviceModel(there, helper: peerHelper)
        let model = deviceModel(here, helper: localHelper)
        let route = peerRoute(peer, keychain: there)
        // That Mac's own chat settings, providers and catalog differ from this Mac's.
        model.peerTransport = { member in
            let send = route(member)
            return { method, payload in
                var snapshot = try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: try await send(method, payload))
                snapshot.settings.global.defaultModel = "peer-provider/peer-only-model"
                snapshot.providers = [.init(id: "peer-provider", name: "Peer", connected: true, state: nil, detail: nil, account: nil)]
                snapshot.catalog = [.init(id: "peer-provider/peer-only-model", name: "Peer only", provider: "peer-provider", providerName: "Peer")]
                return try JSONEncoder().encode(snapshot)
            }
        }
        let own = DefaultAgentSupport.settings.global.defaultModel
        try await KeychainAccess.$testOperations.withValue(here.operations) {
            model.selectDevice(SignInDevice.macID(UUID().uuidString.lowercased()))
            try await waitUntil(model) { !model.busy && model.configuration.defaultModel == "peer-provider/peer-only-model" }
            #expect(model.catalog.contains { $0.provider == "peer-provider" })
            SignInDevicePicker.leave(model)
            #expect(model.device == SignInDevice.localID)
            #expect(model.configuration.defaultModel == own)
            #expect(!model.providers.contains { $0.id == "peer-provider" })
            #expect(!model.catalog.contains { $0.provider == "peer-provider" })
            // Nothing later from that Mac replaces them.
            try await Task.sleep(for: .milliseconds(600))
            #expect(model.configuration.defaultModel == own && !model.catalog.contains { $0.provider == "peer-provider" })
        }
    }

    /// A member that stops polling (it slept or went offline) has its sign-in cancelled here.
    @Test func aMemberThatStopsPollingHasItsSignInCancelledHere() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let session = MemberSignInSession(model: deviceModel(keychain, helper: helper), idleLimit: .milliseconds(300))
        let peer = session.model
        try await KeychainAccess.$testOperations.withValue(keychain.operations) {
            session.touch()
            #expect(await command(.init(action: "refresh", provider: "openai-codex"), on: peer, keychain: keychain).status == 200)
            // The member keeps polling while the sign-in starts.
            try await waitUntil(peer) { session.touch(); return peer.prompt != nil }
            // While it polls, the sign-in waits for the user.
            for _ in 0..<4 { session.touch(); try await Task.sleep(for: .milliseconds(150)) }
            #expect(peer.busy)
            try await waitUntil(peer, timeout: .seconds(10)) { !peer.busy && peer.signInProvider == nil }
        }
    }

    /// A member gone for a while with nothing running is released, with its model and watchdog.
    @Test func anIdleMemberSessionIsReleased() async throws {
        let keychain = SignInKeychainFixture(), helper = try FakeSettingsHelper(); defer { helper.remove() }
        let session = MemberSignInSession(model: deviceModel(keychain, helper: helper), idleLimit: .milliseconds(200), releaseAfter: .milliseconds(300))
        var released = false
        session.onRelease = { released = true }
        session.touch()
        #expect(session.isWatching)
        let deadline = ContinuousClock.now + .seconds(5)
        while !released, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(released && !session.isWatching)
        // Its notification loops end with it.
        #expect(!session.model.isObserving)
        #expect(MemberSignInSession.defaultReleaseAfter > MemberSignInSession.defaultIdleLimit)
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
        backend.selectsDevices = true
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
        #expect(login["credentialAccounts"] == nil)
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
                let path = method == "connections.command" ? "/connections/command" : "/connections/snapshot"
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
        let refused = await ApplicationModel.memberSignIns(method: "POST", path: "/connections/command",
            body: try JSONEncoder().encode(BackendConnectionsCommand(action: "device", value: "local")), model: peer)
        #expect(refused.status == 400)
        let remote = await ApplicationModel.memberSignIns(method: "GET", path: "/connections/snapshot", body: Data(), model: peer)
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


private actor FailureBudget {
    private(set) var remaining = 0
    func arm(_ count: Int) { remaining = count }
    func take() -> Bool { guard remaining > 0 else { return false }; remaining -= 1; return true }
}
