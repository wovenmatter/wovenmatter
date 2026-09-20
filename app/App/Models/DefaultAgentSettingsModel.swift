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
    }
    struct Status: Decodable { let providers: [Provider]; let models: [Model]; let searchConfigured: Bool }
    var scope = "global"
    var settings = DefaultAgentSupport.settings
    var catalog: [Model] = []
    var providers: [Provider] = []
    var searchConfigured = false
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

    var configuration: DefaultAgentSettings {
        get { scope == "global" ? settings.global : settings.resolved(scope) }
        set { if scope == "global" { settings.global = newValue } else { settings.workspaces[scope] = newValue }; DefaultAgentSupport.settings = settings }
    }
    var inherits: Bool { scope != "global" && settings.workspaces[scope] == nil }
    var keyScope: String { inherits ? "global" : scope }
    var orderedModels: [Model] {
        configuration.models.isEmpty ? catalog : configuration.models.compactMap { id in catalog.first { $0.id == id } }
    }
    func setInherits(_ value: Bool) {
        if value { settings.workspaces.removeValue(forKey: scope) }
        else { settings.workspaces[scope] = settings.global }
        DefaultAgentSupport.settings = settings
    }
    func saveKey(_ key: String, provider: String) {
        do { try DefaultAgentSupport.saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider, scope: keyScope); notice = "Key saved."; error = nil }
        catch { self.error = error.localizedDescription }
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
    func changeScope(_ scope: String) { cancel(); self.scope = scope; catalog = []; providers = []; notice = nil; error = nil }
    func cancel() {
        generation = UUID()
        input?.closeFile(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; busy = false; signInURL = nil; signInCode = nil; prompt = nil; promptID = nil; promptOptions = []
    }
    func respond(_ answer: String) {
        guard let id = promptID else { return }
        write(["answerTo": id, "answer": answer]); promptID = nil; prompt = nil; promptOptions = []
    }
    func refresh(remote: RemoteWorkspaceConfiguration? = nil, login: String? = nil) {
        cancel(); busy = true; error = nil; outputBuffer = Data()
        let runID = generation
        do {
            var body = try JSONSerialization.jsonObject(with: DefaultAgentSupport.payload(workspace: scope == "global" ? "local" : scope)) as! [String: Any]
            // Global editing must use global values even when the local workspace has an override.
            if scope == "global" {
                body["config"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.global))
                var keys: [String: [String: String]] = [:]
                for id in ["openai", "openrouter", "opencode-go", "exa"] {
                    if let key = try DefaultAgentSupport.key(id) { keys[id] = ["type": "api_key", "key": key] }
                }
                body["credentials"] = keys
            }
            body["action"] = login == nil ? "status" : "login"
            if let login { body["provider"] = login }
            let child = Process()
            if let remote {
                let launch = try RemoteHarnessLaunchResolver.resolve(configuration: remote, runtimeKind: .defaultAgent, processWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser).launch
                child.executableURL = launch.executableURL
                child.arguments = launch.arguments.map { $0.replacingOccurrences(of: "'--remote'", with: "'--control'") }
            } else {
                guard let launch = DefaultAgentSupport.resolution().launchConfiguration else { throw DefaultAgentError.message("The bundled helper is unavailable. Rebuild Woven Matter.") }
                child.executableURL = launch.executableURL; child.arguments = launch.arguments + ["--control"]
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
                    if child.terminationStatus != 0 && self.error == nil { self.error = "Default Agent setup did not complete. Try again." }
                }
            }
            try child.run(); process = child; input = stdin.fileHandleForWriting; write(body)
        } catch { busy = false; self.error = error.localizedDescription }
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
                if let data = try? JSONSerialization.data(withJSONObject: result), let status = try? JSONDecoder().decode(Status.self, from: data) {
                    providers = status.providers; catalog = status.models; searchConfigured = status.searchConfigured
                } else { notice = "Signed in. Refresh connections to see available models." }
                busy = false; signInURL = nil; signInCode = nil; prompt = nil
            }
            if let error = object["error"] as? String { self.error = error; busy = false }
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
