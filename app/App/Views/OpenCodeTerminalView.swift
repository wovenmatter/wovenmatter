import AppKit
import SwiftUI
import SwiftTerm
import WovenMatterClient

struct OpenCodeTerminalView: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    @State private var terminals: [OpenCodeValue] = []
    @State private var selected: String?
    @State private var terminate: String?
    @State private var generation = 0
    @State private var persistent = true
    private var collection: String { persistent ? "experimental/session/" + OpenCodeHTTPClient.segment(model.links[conversationID]?.sessionID ?? "") + "/terminal" : "pty" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Terminals", selection: $persistent) { Text("Session terminals").tag(true); Text("Workspace terminals").tag(false) }.frame(width: 240)
                Spacer()
                Button("New Terminal") { model.perform {
                    let response = try await model.resource(collection, conversationID: conversationID, method: "POST", body: persistent ? ["args": .array([]), "title": "Woven Matter terminal", "env": [:], "cwd": .string(model.snapshots[conversationID]?.info["location"]["directory"].text ?? model.directory)] : [:])
                    selected = response["data"]["id"].string; reload()
                } }
                Button("Refresh") { reload() }
            }
            ForEach(terminals, id: \.self) { terminal in
                HStack {
                    Button(terminal["title"].string ?? terminal["id"].text) { selected = terminal["id"].text }
                    Text(terminal["status"].text).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Terminate…", role: .destructive) { terminate = terminal["id"].text }
                }
            }
            if let selected {
                OpenCodeTerminalSurface(model: model, conversationID: conversationID, terminalID: selected, persistent: persistent)
                    .id(selected + String(generation)).frame(minHeight: 360)
                HStack {
                    Button("Reconnect Terminal") { generation += 1 }
                    Button("Disconnect Terminal") { self.selected = nil }
                }
            }
            Text("Closing this view disconnects the terminal display. The terminal process continues on the OpenCode host.")
                .font(.caption).foregroundStyle(.secondary)
        }.task { reload() }.onChange(of: persistent) { _, _ in selected = nil; terminals = []; reload() }
        .confirmationDialog("Terminate this terminal process on the OpenCode host?", isPresented: Binding(get: { terminate != nil }, set: { if !$0 { terminate = nil } }), titleVisibility: .visible) {
            Button("Terminate Terminal", role: .destructive) { if let terminate { model.perform {
                _ = try await model.resource((persistent ? "experimental/persistent-pty/" : "pty/") + OpenCodeHTTPClient.segment(terminate), conversationID: conversationID, method: "DELETE")
                if selected == terminate { selected = nil }; self.terminate = nil; reload()
            } } }
        }
    }
    private func reload() { model.perform { terminals = try await model.resource(collection, conversationID: conversationID)["data"].array } }
}

private struct OpenCodeTerminalSurface: NSViewRepresentable {
    let model: OpenCodeModel
    let conversationID: String
    let terminalID: String
    let persistent: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model: model, conversationID: conversationID, terminalID: terminalID, persistent: persistent) }
    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.terminalDelegate = context.coordinator
        context.coordinator.attach(terminal)
        return terminal
    }
    func updateNSView(_ view: TerminalView, context: Context) {}
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.disconnect()
        view.terminalDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let model: OpenCodeModel
        let conversationID: String
        let terminalID: String
        let persistent: Bool
        let attachmentID = UUID().uuidString
        var columns = 80
        var rows = 24
        var ready = false
        var socket: URLSessionWebSocketTask?
        var reader: Task<Void, Never>?
        var writer: Task<Void, Never>?
        var resize: Task<Void, Never>?
        init(model: OpenCodeModel, conversationID: String, terminalID: String, persistent: Bool) {
            self.model = model; self.conversationID = conversationID; self.terminalID = terminalID; self.persistent = persistent
        }
        func attach(_ terminal: TerminalView) {
            reader = Task { [weak self, weak terminal] in
                guard let self, let terminal, let link = model.links[conversationID] else { return }
                do {
                    var query = model.locationQuery(conversationID)
                    if persistent {
                        let snapshot = try await model.resource("experimental/persistent-pty/" + OpenCodeHTTPClient.segment(terminalID) + "/snapshot", conversationID: conversationID)["data"]
                        columns = Int(snapshot["info"]["size"]["cols"].number ?? 80)
                        rows = Int(snapshot["info"]["size"]["rows"].number ?? 24)
                        terminal.getTerminal().resize(cols: columns, rows: rows)
                        if let data = Data(base64Encoded: snapshot["checkpoint"].text) { terminal.feed(byteArray: Array(data)[...]) }
                        query["cursor"] = String(format: "%.0f", snapshot["info"]["output"]["tail"].number ?? 0)
                        query["attachment_id"] = attachmentID; query["input_protocol"] = "1"
                    }
                    let socket = try await model.coordinator.terminal(connectionID: link.connectionID, id: terminalID, persistent: persistent, query: query)
                    if Task.isCancelled { socket.cancel(with: .goingAway, reason: nil); return }
                    self.socket = socket
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .string(let text):
                            if persistent {
                                let event = try OpenCodeValue.decode(Data(text.utf8))
                                if event["type"].text == "replay_complete" { ready = true }
                                if event["type"].text == "resized", let checkpoint = Data(base64Encoded: event["checkpoint"].text) {
                                    columns = Int(event["cols"].number ?? 80); rows = Int(event["rows"].number ?? 24)
                                    terminal.getTerminal().resize(cols: columns, rows: rows)
                                    terminal.feed(byteArray: Array(Data([27, 99]) + checkpoint)[...])
                                }
                                if event["type"].text == "exited" { ready = false }
                                continue
                            }
                            data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        // Control frames carry a replay watermark, not screen data.
                        if data.first != 0 { terminal.feed(byteArray: Array(data)[...]) }
                    }
                } catch {
                    if !Task.isCancelled { model.error = "Terminal disconnected: " + error.localizedDescription }
                }
            }
        }
        func disconnect() { reader?.cancel(); writer?.cancel(); resize?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard !persistent || ready else { return }
            var bytes = Data(data)
            if persistent { bytes = Data([1, UInt8(clamping: columns >> 8), UInt8(truncatingIfNeeded: columns), UInt8(clamping: rows >> 8), UInt8(truncatingIfNeeded: rows)]) + bytes }
            let prior = writer, payload = bytes
            writer = Task { [weak self] in
                await prior?.value
                guard let self, let socket, !Task.isCancelled else { return }
                do { try await socket.send(.data(payload)) } catch { model.error = error.localizedDescription }
            }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            columns = min(newCols, 65535); rows = min(newRows, 65535)
            guard !persistent else { return }
            resize?.cancel()
            resize = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let self else { return }
                    _ = try await model.resource((persistent ? "experimental/persistent-pty/" : "pty/") + OpenCodeHTTPClient.segment(terminalID), conversationID: conversationID, method: "PUT",
                        body: ["size": ["cols": .number(Double(newCols)), "rows": .number(Double(newRows))]])
                } catch { if !Task.isCancelled { self?.model.error = error.localizedDescription } }
            }
        }
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
