import AppKit
import Foundation
import Observation
import WovenMatterCore
import WovenMatterClient

@MainActor @Observable
final class DefaultAgentSettingsModel {
    struct Model: Decodable, Identifiable {
        let id: String
        let name: String
        let provider: String
        let providerName: String
    }
    struct Provider: Decodable, Identifiable {
        let id: String
        let name: String
        let connected: Bool
        let state: String?
        let detail: String?
    }
    struct Status: Decodable { let providers: [Provider]; let models: [Model]; let searchConfigured: Bool }
    var scope = "global"
    var settings = DefaultAgentSupport.settings
    var catalog: [Model] = []
    var providers: [Provider] = []
    var searchConfigured = false
    var accountLabels: [String: String] = [:]
    func connectionLabel(_ id: String) -> String {
        if let provider = providers.first(where: { $0.id == id }), !provider.connected { return "Connect account" }
        if let label = accountLabels[id] { return label }
        return providers.first { $0.id == id }?.connected == true ? "Credentials present" : "Connect account"
    }
    var busy = false
    var error: String?
    var notice: String?
    var signInURL: URL?
    var signInCode: String?
    var prompt: String?
    var promptID: String?
    var promptOptions: [(id: String, label: String)] = []
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var generation = UUID()
    private var operationTask: Task<Void, Never>?
    private var signInLease: UUID?
    private var activeKeyScope = "global"

    var configuration: DefaultAgentSettings {
        get { scope == "global" ? settings.global : settings.resolved(scope) }
        set { settings = DefaultAgentSupport.settings; if scope == "global" { settings.global = newValue } else { settings.workspaces[scope] = newValue }; DefaultAgentSupport.settings = settings }
    }
    var inherits: Bool { scope != "global" && settings.workspaces[scope] == nil }
    var keyScope: String { inherits ? "global" : scope }
    var orderedModels: [Model] {
        configuration.models.isEmpty ? catalog : configuration.models.compactMap { id in catalog.first { $0.id == id } }
    }
    func setInherits(_ value: Bool) {
        settings = DefaultAgentSupport.settings
        if value { settings.workspaces.removeValue(forKey: scope) }
        else { settings.workspaces[scope] = settings.global }
        DefaultAgentSupport.settings = settings
    }
    func saveKey(_ key: String, provider: String) {
        do { try DefaultAgentSupport.saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider, scope: keyScope); notice = "Key saved."; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func signOut(_ provider: String, remote: RemoteWorkspaceConfiguration?) {
        if let remote { refresh(remote: remote, login: provider, action: "logout"); return }
        do {
            try DefaultAgentSupport.saveKey("", provider: "oauth." + provider, scope: keyScope)
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func move(_ id: String, by offset: Int) {
        var value = configuration
        var order = orderedModels.map(\.id)
        guard let from = order.firstIndex(of: id), order.indices.contains(from + offset) else { return }
        order.swapAt(from, from + offset); value.models = order; configuration = value
    }
    func setVisible(_ id: String, visible: Bool) {
        var value = configuration
        if value.models.isEmpty { value.models = catalog.map(\.id) }
        if visible { if !value.models.contains(id) { value.models.append(id) } }
        else { guard value.models.count > 1 else { return }; value.models.removeAll { $0 == id }; value.fallbackModels.removeAll { $0 == id }; if value.defaultModel == id { value.defaultModel = value.models.first } }
        configuration = value
    }
    func moveFallback(_ id: String, by offset: Int) {
        var value = configuration
        guard let from = value.fallbackModels.firstIndex(of: id), value.fallbackModels.indices.contains(from + offset) else { return }
        value.fallbackModels.swapAt(from, from + offset); configuration = value
    }
    func setFallback(_ id: String, enabled: Bool) {
        var value = configuration
        value.fallbackModels.removeAll { $0 == id }
        if enabled { value.fallbackModels.append(id) }
        configuration = value
    }
    func changeScope(_ scope: String) { cancel(); settings = DefaultAgentSupport.settings; self.scope = scope; catalog = []; providers = []; accountLabels = [:]; notice = nil; error = nil }
    func cancel() {
        generation = UUID()
        operationTask?.cancel(); operationTask = nil
        finishSignIn()
        input?.closeFile(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; busy = false; signInURL = nil; signInCode = nil; prompt = nil; promptID = nil; promptOptions = []
    }
    private func finishSignIn() {
        if let signInLease { DefaultAgentCredentialCoordinator.shared.endSignIn(signInLease) }
        signInLease = nil
    }
    func respond(_ answer: String) {
        guard let id = promptID else { return }
        write(["answerTo": id, "answer": answer]); promptID = nil; prompt = nil; promptOptions = []
    }
    func refresh(remote: RemoteWorkspaceConfiguration? = nil, login: String? = nil, action: String? = nil) {
        cancel(); busy = true; error = nil; outputBuffer = Data()
        let runID = generation
        activeKeyScope = keyScope
        operationTask = Task { [self] in
        do {
            let prepared = try await DefaultAgentCredentialCoordinator.shared.prepare(scope)
            accountLabels = prepared.credentials.compactMapValues { $0.accountLabel }
            if login != nil {
                let lease = try await DefaultAgentCredentialCoordinator.shared.beginSignIn()
                guard generation == runID, !Task.isCancelled else {
                    DefaultAgentCredentialCoordinator.shared.endSignIn(lease)
                    return
                }
                signInLease = lease
            }
            try Task.checkCancellation()
            guard generation == runID else { return }
            var body = try JSONSerialization.jsonObject(with: prepared.data()) as! [String: Any]
            body["action"] = action ?? (login == nil ? "status" : "login")
            if let login { body["provider"] = login }
            let child = Process()
            if let remote {
                let launch = try RemoteHarnessLaunchResolver.resolve(configuration: remote, runtimeKind: .defaultAgent, processWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser).launch
                child.executableURL = launch.executableURL
                child.arguments = launch.arguments.map { $0.replacingOccurrences(of: "'--remote'", with: "'--control'") }
            } else {
                guard let launch = DefaultAgentSupport.resolution().launchConfiguration else { throw DefaultAgentError.message("The bundled helper is unavailable. Rebuild Woven Matter.") }
                child.executableURL = URL(fileURLWithPath: "/bin/sh")
                child.arguments = ["-c", #"ulimit -c 0; exec "$@""#, "woven-default-agent", launch.executableURL.path] + launch.arguments + ["--control"]
            }
            let stdin = Pipe(), stdout = Pipe()
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor in guard self?.generation == runID else { return }; self?.receive(data) }
            }
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.generation == runID else { return }
                    self.busy = false
                    if child.terminationStatus != 0 { self.finishSignIn() }
                    if child.terminationStatus != 0 && self.error == nil { self.error = "Default Agent setup did not complete. Try again." }
                }
            }
            try child.run(); process = child; input = stdin.fileHandleForWriting; write(body)
        } catch {
            guard generation == runID else { return }
            busy = false; self.error = error.localizedDescription
            finishSignIn()
        }
        }
    }
    private func write(_ value: [String: Any]) {
        do { var data = try JSONSerialization.data(withJSONObject: value); data.append(0x0a); try input?.write(contentsOf: data) }
        catch { self.error = "Default Agent helper disconnected." }
    }
    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = outputBuffer[..<newline]; outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let result = object["result"] as? [String: Any] {
                if let raw = result["credential"], let provider = result["provider"] as? String {
                    do {
                        let credential = try JSONDecoder().decode(DefaultAgentCredential.self, from: JSONSerialization.data(withJSONObject: raw))
                        try DefaultAgentSupport.saveOAuth(credential, provider: provider, scope: activeKeyScope)
                        accountLabels[provider] = credential.accountLabel
                    } catch { self.error = "Sign-in completed but could not be saved in Keychain. Try again."; busy = false; finishSignIn(); continue }
                }
                finishSignIn()
                if result["credential"] != nil || result["connected"] != nil || result["reset"] != nil || result["disconnected"] != nil { DefaultAgentSupport.changed() }
                if let data = try? JSONSerialization.data(withJSONObject: result), let status = try? JSONDecoder().decode(Status.self, from: data) {
                    providers = status.providers; catalog = status.models; searchConfigured = status.searchConfigured
                } else if result["reset"] as? Bool == true { notice = "Workspace credentials reset. Shared connections are available; sign in again for independent workspace accounts." }
                else if result["disconnected"] as? Bool == true { notice = "Workspace sign-in removed. Shared credentials will be used when available." }
                else { notice = "Connected. This account is shared with the features that use it." }
                busy = false; signInURL = nil; signInCode = nil; prompt = nil
            }
            if let error = object["error"] as? String { self.error = error; busy = false; finishSignIn() }
            if let event = object["notification"] as? [String: Any] {
                if let url = (event["url"] ?? event["verificationUri"]) as? String, let value = URL(string: url), value.scheme == "https" { signInURL = value }
                signInCode = event["userCode"] as? String
                notice = (event["message"] ?? event["instructions"]) as? String
            }
            if let value = object["prompt"] as? [String: Any] {
                promptID = object["id"] as? String; prompt = value["message"] as? String
                promptOptions = (value["options"] as? [[String: String]] ?? []).compactMap { v in guard let id = v["id"], let label = v["label"] else { return nil }; return (id, label) }
            }
        }
    }
}
