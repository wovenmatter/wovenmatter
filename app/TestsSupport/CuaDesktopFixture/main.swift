// Opt-in native acceptance. No provider, account, production database or user
// document is used. The target writes app-owned state independently of Cua.
import AppKit
import Foundation
import WovenMatterAutomation
import WovenMatterCore
import WovenMatterClient
import ApplicationServices

@MainActor final class Fixture: NSObject, NSApplicationDelegate {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WM_CUA_FIXTURE_ROOT"]!)
    let target = ProcessInfo.processInfo.environment["WM_CUA_FIXTURE_ROLE"] == "target"
    var window: NSWindow!
    var field: NSTextField!
    var timer: Timer?
    var count = 0
    var started = false
    var enabled = false
    let computer = WovenComputerAutomation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = target ? "Cua disposable target" : "Woven Cua Verification"
        let view = window.contentView!
        if target {
            let button = NSButton(title: "Increment", target: self, action: #selector(increment))
            button.frame = NSRect(x: 30, y: 300, width: 130, height: 35)
            button.setAccessibilityIdentifier("woven.increment"); view.addSubview(button)
            field = NSTextField(frame: NSRect(x: 30, y: 240, width: 400, height: 30))
            field.setAccessibilityLabel("Fixture text"); view.addSubview(field)
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.saveTarget() }
            }
        } else {
            let label = NSTextField(wrappingLabelWithString: "This provider-free check needs Accessibility and Screen Recording for Woven Cua Verification. Enable them in System Settings. The test operates only its disposable target window.")
            label.frame = NSRect(x: 30, y: 180, width: 540, height: 150); view.addSubview(label)
            let permissions = NSButton(title: "Request macOS permission prompts", target: self, action: #selector(requestPermissions))
            permissions.frame = NSRect(x: 30, y: 120, width: 300, height: 35); view.addSubview(permissions)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.beginWhenPermitted() }
            }
            saveReport(["status": .string("waiting_for_permissions"), "permissions": WovenComputerAutomation.permissions])
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func increment() { count += 1; saveTarget() }
    @objc func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
    }
    func saveTarget() {
        let selected = (field.currentEditor() as? NSTextView)?.selectedRange().length ?? 0
        let value: GatewayJSONValue = .object(["pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "windowID": .number(Double(window.windowNumber)), "count": .number(Double(count)),
            "text": .string(field.currentEditor()?.string ?? field.stringValue), "selected": .number(Double(selected))])
        try? JSONEncoder().encode(value).write(to: root.appending(path: "target.json"), options: .atomic)
    }
    func saveReport(_ report: [String: GatewayJSONValue]) {
        try? JSONEncoder().encode(GatewayJSONValue.object(report)).write(to: root.appending(path: "report.json"), options: .atomic)
    }
    func beginWhenPermitted() async {
        guard !started else { return }
        let permissions = WovenComputerAutomation.permissions.objectValue!
        guard permissions["accessibility"] == .bool(true), permissions["screenRecording"] == .bool(true) else { return }
        started = true; timer?.invalidate()
        do {
            let report = try await verify()
            saveReport(report.merging(["status": .string("passed")]) { _, new in new })
        } catch { saveReport(["status": .string("failed"), "error": .string(error.localizedDescription)]) }
        computer.revokeAll()
    }
    func invoke(_ arguments: [String: GatewayJSONValue], caller: String = "fixture-one", expectError: Bool = false) async throws -> GatewayJSONValue {
        let message: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString), "method": .string("tools/call"),
            "params": .object(["name": .string("woven_computer_use"), "arguments": .object(arguments)])])
        let response = await WovenMCPServer.handle(message) { [self] request in
            do {
                let command = try WovenMatterToolCommand(request.arguments)
                let input = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(command.required("json").utf8))
                let value = try await computer.execute(input, callerID: caller, admit: { [self] in
                    guard enabled else { throw WorkspaceToolError.disabled(.computer) }
                })
                return .init(result: value, requestID: request.requestID)
            } catch { return .init(success: false, error: error.localizedDescription, requestID: request.requestID) }
        }
        guard let envelope = response?.objectValue?["result"]?.objectValue,
              envelope["isError"] == .bool(expectError) else {
            throw failure("Unexpected MCP result: \(String(describing: response))")
        }
        if expectError { return .object(envelope) }
        guard let result = envelope["structuredContent"]?.objectValue?["result"] else { throw failure("Missing MCP result") }
        return result
    }
    func targetState() throws -> [String: GatewayJSONValue] {
        try JSONDecoder().decode(GatewayJSONValue.self, from: Data(contentsOf: root.appending(path: "target.json"))).objectValue!
    }
    func waitFor(_ key: String, _ value: GatewayJSONValue) async throws {
        for _ in 0..<100 {
            if (try? targetState()[key]) == value { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw failure("Independent app state did not confirm \(key)=\(value)")
    }
    func verify() async throws -> [String: GatewayJSONValue] {
        _ = try await invoke(["action": .string("apps")], expectError: true)
        enabled = true
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        config.environment = ["WM_CUA_FIXTURE_ROOT": root.path, "WM_CUA_FIXTURE_ROLE": "target"]
        let app = try await NSWorkspace.shared.openApplication(at: root.appending(path: "Cua Target.app"), configuration: config)
        defer { app.terminate() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appending(path: "target.json").path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(200))
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, pointer = NSEvent.mouseLocation
        let state = try targetState(), pid = state["pid"]!, wid = state["windowID"]!
        let target: [String: GatewayJSONValue] = ["pid": pid, "windowID": wid]
        _ = try await invoke(["action": .string("apps")])
        _ = try await invoke(["action": .string("launch"), "app": .string("wovenmatter.desktop.dev.cua-verification.target")])
        _ = try await invoke(["action": .string("windows"), "pid": pid])
        let desktop = try await invoke(["action": .string("screenshot")])
        guard desktop.objectValue?["content"]?.arrayValue?.contains(where: { $0.objectValue?["type"] == .string("image") }) == true else { throw failure("Desktop screenshot was not returned inline") }
        func snapshot() async throws -> GatewayJSONValue {
            try await invoke(target.merging(["action": .string("snapshot"), "treeFormat": .string("elements")]) { _, new in new })
        }
        func token(_ result: GatewayJSONValue, label: String) throws -> GatewayJSONValue {
            let elements = result.objectValue?["structuredContent"]?.objectValue?["elements"]?.arrayValue ?? []
            guard let row = elements.first(where: { $0.objectValue?["label"]?.stringValue == label }),
                  let token = row.objectValue?["element_token"] else { throw failure("Missing accessibility element \(label): \(result)") }
            return token
        }
        let before = try await snapshot()
        guard before.objectValue?["content"]?.arrayValue?.contains(where: { $0.objectValue?["type"] == .string("image") }) == true else { throw failure("Screenshot was not returned inline") }
        let button = try token(before, label: "Increment")
        _ = try await invoke(target.merging(["action": .string("click"), "elementToken": button]) { _, new in new })
        try await waitFor("count", .number(1))
        let refreshed = try await snapshot()
        _ = try await invoke(target.merging(["action": .string("click"), "elementToken": button]) { _, new in new }, expectError: true)
        let text = try token(refreshed, label: "Fixture text")
        _ = try await invoke(target.merging(["action": .string("type"), "elementToken": text, "text": .string("Cua verified")]) { _, new in new })
        try await waitFor("text", .string("Cua verified"))
        _ = try await invoke(target.merging(["action": .string("press"), "elementToken": text, "key": .string("cmd+a")]) { _, new in new })
        try await waitFor("selected", .number(12))
        _ = try await invoke(target.merging(["action": .string("type"), "elementToken": text, "text": .string("Replacement verified")]) { _, new in new })
        try await waitFor("text", .string("Replacement verified"))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front, NSEvent.mouseLocation == pointer else { throw failure("Background input changed the user's focus or pointer") }
        let again = try await snapshot(), foreignToken = try token(again, label: "Increment")
        _ = try await invoke(target.merging(["action": .string("click"), "elementToken": foreignToken]) { _, new in new }, caller: "fixture-two", expectError: true)
        enabled = false; computer.revoke(callerID: "fixture-one")
        _ = try await invoke(target.merging(["action": .string("click"), "elementToken": foreignToken]) { _, new in new }, expectError: true)
        try await waitFor("count", .number(1))
        return ["defaultOff": .bool(true), "backgroundLaunch": .bool(true), "desktopScreenshot": .bool(true), "inlineScreenshot": .bool(true), "accessibilityClick": .bool(true),
                "backgroundTyping": .bool(true), "hotkey": .bool(true), "staleTokenRejected": .bool(true),
                "foreignCallerRejected": .bool(true), "revocationRejected": .bool(true),
                "foregroundPreserved": .bool(true), "realPointerPreserved": .bool(true)]
    }
    func failure(_ message: String) -> NSError { NSError(domain: "CuaDesktopAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.run()
