import AppKit
import SwiftUI
import WovenMatterClient

struct OpenCodeConversationControls: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    @State private var inspect = false
    @State private var browser = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.links[conversationID] == nil {
                Text("Saved OpenCode v1 transcript · Start a new v2 session to send messages.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(model.statuses[conversationID] ?? "Connecting…").font(.caption).foregroundStyle(.secondary)
                    Menu(model.snapshots[conversationID]?.info["model"]["id"].string ?? "Model") {
                        ForEach(model.models[conversationID] ?? [], id: \.self) { option in
                            Menu(option["providerID"].text + " / " + option["name"].text) {
                                modelButton(option, variant: "default")
                                ForEach(option["variants"].array, id: \.self) { variant in modelButton(option, variant: variant["id"].text) }
                            }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Menu(model.snapshots[conversationID]?.info["agent"].string ?? "Agent") {
                        ForEach(model.agents[conversationID] ?? [], id: \.self) { agent in
                            Button(agent["name"].string ?? agent["id"].text) { model.perform {
                                _ = try await model.sessionCall(conversationID, "/agent", method: "POST", body: ["agent": agent["id"]])
                            } }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer(minLength: 0)
                    Picker("Follow-up", selection: Binding(get: { model.delivery[conversationID] ?? "queue" }, set: { model.delivery[conversationID] = $0 })) {
                        Text("Queue").tag("queue"); Text("Steer").tag("steer")
                    }.labelsHidden().frame(width: 82)
                    Button("Session…") { inspect = true }
                    Button("Browse…") { browser = true }
                }
                if let error = model.errors[conversationID] ?? model.error {
                    Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                }
                ForEach(model.serverFiles[conversationID] ?? [], id: \.self) { file in
                    HStack { Label(file["name"].text, systemImage: "doc"); Button("Remove") { model.serverFiles[conversationID]?.removeAll { $0 == file } } }.font(.caption)
                }
                OpenCodeInteractions(model: model, conversationID: conversationID)
            }
        }.controlSize(.small)
        .task(id: conversationID) { if model.links[conversationID] != nil { model.perform { try await model.refreshCatalog(conversationID) } } }
        .sheet(isPresented: $inspect) { OpenCodeSessionInspector(model: model, conversationID: conversationID) }
        .sheet(isPresented: $browser) { OpenCodeSessionBrowser(model: model) }
    }
    private func modelButton(_ option: OpenCodeValue, variant: String) -> some View {
        Button(variant == "default" ? "Default" : variant) { model.perform {
            var selection: OpenCodeValue = ["id": option["id"], "providerID": option["providerID"]]
            if variant != "default" { selection["variant"] = .string(variant) }
            _ = try await model.sessionCall(conversationID, "/model", method: "POST", body: ["model": selection])
        } }
    }
}

struct OpenCodeSessionInspector: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Session"
    @State private var title = ""
    @State private var command = ""
    @State private var value: OpenCodeValue = .null
    @State private var loading = false
    @State private var failure: String?
    @State private var confirmDelete = false
    private let tabs = ["Session", "Files", "Terminals", "Commands", "Integrations", "MCP", "Plugins", "Configuration", "Instructions", "Permissions"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("OpenCode").font(.title2); Spacer(); Button("Done") { dismiss() } }
            Picker("Section", selection: $tab) { ForEach(tabs, id: \.self) { Text($0) } }.pickerStyle(.segmented).labelsHidden()
            if loading { ProgressView() }
            if let error = failure ?? model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case "Session": session
                    case "Files": OpenCodeFilesView(model: model, conversationID: conversationID)
                    case "Terminals": OpenCodeTerminalView(model: model, conversationID: conversationID)
                    case "Commands": commands
                    case "Integrations": OpenCodeIntegrationsView(model: model, conversationID: conversationID)
                    case "MCP": OpenCodeMCPView(model: model, conversationID: conversationID)
                    case "Plugins": plugins
                    case "Instructions", "Permissions": OpenCodeAdvancedSettings(model: model, conversationID: conversationID, permissions: tab == "Permissions")
                    default: configuration
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }.padding(20).frame(minWidth: 780, idealWidth: 920, minHeight: 590).controlSize(.small)
        .task(id: tab) { await reload() }
        .confirmationDialog("Delete this session from the OpenCode server?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) { model.perform { _ = try await model.sessionCall(conversationID, method: "DELETE"); dismiss() } }
        }
    }
    @ViewBuilder private var session: some View {
        if let snapshot = model.snapshots[conversationID] {
            HStack {
                TextField("Session name", text: $title)
                Button("Rename") { act { _ = try await model.sessionCall(conversationID, "/rename", method: "POST", body: ["title": .string(title)]) } }
                Button("Fork") { act {
                    let fork = try await model.sessionCall(conversationID, "/fork", method: "POST", body: ["boundary": ["type": "through"]])
                    model.requestedConversationID = try await model.open(fork["data"], serverID: model.links[conversationID]?.connectionID); dismiss()
                } }
            }.textFieldStyle(.roundedBorder)
            Text(snapshot.info["location"]["directory"].text).font(.caption).textSelection(.enabled)
            HStack {
                Button("Resume") { act {
                    if let link = model.links[conversationID] { try await model.coordinator.prompt(link, input: .init(text: ""), resume: true) }
                } }.disabled(snapshot.active)
                Button("Compact Context") { act { _ = try await model.sessionCall(conversationID, "/compact", method: "POST", body: [:]) } }
                Button("Interrupt") { act { _ = try await model.sessionCall(conversationID, "/interrupt", method: "POST") } }.disabled(!snapshot.active)
                Button("Background Tools") { act { _ = try await model.sessionCall(conversationID, "/background", method: "POST") } }.disabled(!snapshot.active)
                Button("Export…") { act { try await export() } }
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
            DisclosureGroup("Usage and context") {
                OpenCodeValueView(value: snapshot.info["tokens"])
                Text("Cost: \(snapshot.info["cost"].json)").font(.caption)
                Button("Inspect Context") { act { value = try await model.sessionCall(conversationID, "/context") } }
                if !value.isNull { OpenCodeValueView(value: value) }
            }
            if !snapshot.inbox.isEmpty {
                Text("Queued input").font(.headline)
                ForEach(snapshot.inbox, id: \.self) { item in
                    HStack {
                        VStack(alignment: .leading) { Text(item["payload"]["text"].string ?? item["type"].text); Text(item["delivery"].text).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Steer") { inbox(item, action: "/steer") }
                        Button("Queue") { inbox(item, action: "/queue") }
                        Button("Cancel") { inbox(item, action: "", method: "DELETE") }
                    }
                }
            }
            ForEach((try? model.store.database.openCodeUncertainSubmissions(conversationID: conversationID)) ?? [], id: \.self) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input outcome is uncertain").fontWeight(.semibold)
                    Text(item["payload"]["text"].text).textSelection(.enabled)
                    Text("The input has not been resent. Check the shared session before sending it again.").font(.caption)
                    Button("Acknowledge and clear this notice") { act {
                        try model.store.database.saveOpenCodeSubmission(conversationID: conversationID, id: item["id"].text, payload: item["payload"], status: "acknowledged")
                        if let link = model.links[conversationID] { try await model.coordinator.refresh(link) }
                    } }
                }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("History and snapshots") {
                if let link = model.links[conversationID], snapshot.olderCursor != nil {
                    Button("Load Older Messages") { act { try await model.coordinator.loadOlder(link) } }
                }
                ForEach(snapshot.messages.filter { $0["type"].text == "user" }, id: \.self) { message in
                    HStack {
                        Text(message["text"].text).lineLimit(2)
                        Spacer()
                        Button("Fork Before") { act {
                            let result = try await model.sessionCall(conversationID, "/fork", method: "POST", body: ["boundary": ["type": "before", "messageID": message["id"]]])
                            model.requestedConversationID = try await model.open(result["data"], serverID: model.links[conversationID]?.connectionID); dismiss()
                        } }
                        Button("Preview Revert") { act {
                            value = try await model.sessionCall(conversationID, "/revert/stage", method: "POST", body: ["messageID": message["id"], "files": .bool(true)])
                        } }
                    }
                }
                if !snapshot.info["revert"].isNull {
                    OpenCodeValueView(value: snapshot.info["revert"])
                    HStack {
                        Button("Apply Staged Revert", role: .destructive) { act { _ = try await model.sessionCall(conversationID, "/revert/commit", method: "POST") } }
                        Button("Discard Revert") { act { _ = try await model.sessionCall(conversationID, "/revert/clear", method: "POST") } }
                    }
                }
            }
            DisclosureGroup("Session details") { OpenCodeValueView(value: snapshot.info) }
        }
    }
    @ViewBuilder private var commands: some View {
        TextField("Command arguments", text: $command).textFieldStyle(.roundedBorder)
        ForEach(value["commands"].array, id: \.self) { entry in
            HStack {
                Text(entry["name"].string ?? entry["id"].text)
                Text(entry["description"].text).foregroundStyle(.secondary)
                Spacer()
                Button("Run") { act { _ = try await model.sessionCall(conversationID, "/command", method: "POST", body: ["command": entry["name"].isNull ? entry["id"] : entry["name"], "text": .string(command)]) } }
            }
        }
        Text("Skills").font(.headline)
        ForEach(value["skills"].array, id: \.self) { entry in
            HStack {
                Text(entry["name"].string ?? entry["id"].text); Spacer()
                Button("Activate") { act { _ = try await model.sessionCall(conversationID, "/skill", method: "POST", body: ["skill": entry["id"].isNull ? entry["name"] : entry["id"]]) } }
            }
        }
        OpenCodeShellJobs(model: model, conversationID: conversationID)
        Text("Shell command").font(.headline)
        HStack { TextField("Command on the OpenCode host", text: $command); Button("Run Shell") { act { _ = try await model.sessionCall(conversationID, "/shell", method: "POST", body: ["command": .string(command)]) } } }
    }
    @ViewBuilder private var plugins: some View {
        ForEach(value["data"].array, id: \.self) { plugin in
            DisclosureGroup(plugin["id"].string ?? plugin["source"]["target"].string ?? plugin["source"]["path"].string ?? "Built-in plugin") { OpenCodeValueView(value: plugin) }
        }
        HStack {
            Button("Check Updates") { act { _ = try await model.resource("plugin/check", conversationID: conversationID, method: "POST", body: [:]); await reload() } }
            Button("Update Listed Plugins") { act {
                _ = try await model.resource("plugin/update", conversationID: conversationID, method: "POST", body: ["targets": .array(value["data"].array.map { $0["source"]["target"] }.filter { !$0.isNull })]); await reload()
            } }
        }
    }
    @ViewBuilder private var configuration: some View {
        Text("Configuration reported by OpenCode").font(.headline)
        OpenCodeValueView(value: value)
        Text("This backend exposes configuration inspection. Global configuration files remain managed on the OpenCode host.").font(.caption).foregroundStyle(.secondary)
    }
    private func inbox(_ item: OpenCodeValue, action: String, method: String = "POST") {
        act { _ = try await model.sessionCall(conversationID, "/inbox/" + OpenCodeHTTPClient.segment(item["id"].text) + action, method: method) }
    }
    private func act(_ operation: @escaping @MainActor () async throws -> Void) {
        model.perform { failure = nil; do { try await operation() } catch { failure = error.localizedDescription } }
    }
    private func reload() async {
        loading = true; failure = nil; value = .null
        defer { loading = false }
        do {
            switch tab {
            case "Session": title = model.snapshots[conversationID]?.info["title"].text ?? ""
            case "Commands":
                async let commands = model.resource("command", conversationID: conversationID)
                async let skills = model.resource("skill", conversationID: conversationID)
                let result = try await (commands, skills); value = ["commands": result.0["data"], "skills": result.1["data"]]
            case "Plugins": value = try await model.resource("plugin", conversationID: conversationID)
            case "Configuration": value = try await model.resource("config", conversationID: conversationID)
            default: break
            }
        } catch { failure = error.localizedDescription }
    }
    private func export() async throws {
        let data = try await model.sessionCall(conversationID, "/export", query: ["sanitize": "true"])
        let panel = NSSavePanel(); panel.nameFieldStringValue = "opencode-session.json"
        if panel.runModal() == .OK, let url = panel.url { try Data(data["data"].json.utf8).write(to: url, options: .atomic) }
    }
}

/// Native disclosure rows preserve backend-provided details without pretending
/// optional plugin data is a standard desktop capability.
struct OpenCodeValueView: View {
    let value: OpenCodeValue
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch value {
            case .object(let fields):
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    if let field = fields[key], !field.isNull {
                        HStack(alignment: .top, spacing: 12) {
                            Text(key).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            if field.object.isEmpty && field.array.isEmpty { Text(field.string ?? field.json).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            else { DisclosureGroup("Details") { AnyView(OpenCodeValueView(value: field)) } }
                        }
                    }
                }
            case .array(let items):
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    DisclosureGroup(item["name"].string ?? item["title"].string ?? item["id"].string ?? "Item \(index + 1)") { AnyView(OpenCodeValueView(value: item)) }
                }
            default: Text(value.string ?? value.json).textSelection(.enabled)
            }
        }.font(.callout)
    }
}

struct OpenCodeAdvancedSettings: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    let permissions: Bool
    @State private var entries: [OpenCodeValue] = []
    @State private var key = ""
    @State private var instruction = ""
    @State private var environment = ""
    @State private var revoke: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(permissions ? "Saved permissions" : "Session instructions").font(.headline)
            ForEach(entries, id: \.self) { entry in
                HStack(alignment: .top) {
                    OpenCodeValueView(value: entry)
                    Spacer()
                    if permissions { Button("Revoke…", role: .destructive) { revoke = entry["id"].text } }
                    else { Button("Remove", role: .destructive) { model.perform {
                        _ = try await model.sessionCall(conversationID, "/instructions/entries/" + OpenCodeHTTPClient.segment(entry["key"].text), method: "DELETE")
                        try await reload()
                    } } }
                }
            }
            if !permissions {
                TextField("Entry key (lowercase, digits, . _ -)", text: $key)
                TextEditor(text: $instruction).frame(height: 90).border(.separator)
                Button("Save Instruction") { model.perform {
                    _ = try await model.sessionCall(conversationID, "/instructions/entries/" + OpenCodeHTTPClient.segment(key), method: "PUT", body: ["value": .string(instruction)])
                    try await reload()
                } }.disabled(key.isEmpty)
                Divider()
                Text("Session environment").font(.headline)
                Text("Replace the session's environment overrides. Enter one NAME=value per line; an empty list clears overrides.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $environment).frame(height: 90).border(.separator)
                Button("Apply Environment") { model.perform {
                    var variables: [String: OpenCodeValue] = [:]
                    for line in environment.split(separator: "\n") {
                        let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        guard pair.count == 2, !pair[0].isEmpty else { throw OpenCodeError.message("Each environment line must use NAME=value.") }
                        variables[String(pair[0])] = .string(String(pair[1]))
                    }
                    _ = try await model.sessionCall(conversationID, "/environment", method: "PUT", body: ["variables": .object(variables)])
                    environment = ""
                } }
            }
            Button("Refresh") { model.perform { try await reload() } }
        }.textFieldStyle(.roundedBorder).task(id: permissions) { model.perform { try await reload() } }
        .confirmationDialog("Revoke this saved permission on the OpenCode host?", isPresented: Binding(get: { revoke != nil }, set: { if !$0 { revoke = nil } }), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { if let revoke { model.perform {
                _ = try await model.resource("permission/saved/" + OpenCodeHTTPClient.segment(revoke), conversationID: conversationID, method: "DELETE")
                self.revoke = nil; try await reload()
            } } }
        }
    }
    private func reload() async throws {
        entries = try await (permissions ? model.resource("permission/saved", conversationID: conversationID) : model.sessionCall(conversationID, "/instructions/entries"))["data"].array
    }
}

/// Media stays associated with its server message in the SQLite snapshot.
/// A host file URI is fetched through that server, never opened as a local path.
struct OpenCodeMessageMedia: View {
    let model: OpenCodeModel
    let conversationID: String
    let messageID: String
    private var files: [OpenCodeValue] {
        guard let message = model.snapshots[conversationID]?.messages.first(where: { $0["id"].text == messageID }) else { return [] }
        return message["files"].array + message["content"].array.flatMap { $0["state"]["content"].array.filter { $0["type"].text == "file" } }
    }
    var body: some View {
        ForEach(Array(files.enumerated()), id: \.offset) { _, file in
            OpenCodeMediaItem(model: model, conversationID: conversationID, file: file)
        }
    }
}

private struct OpenCodeMediaItem: View {
    let model: OpenCodeModel
    let conversationID: String
    let file: OpenCodeValue
    @State private var preview: NSImage?
    @State private var failure: String?
    private var embedded: Data? {
        if let data = file["data"].string { return Data(base64Encoded: data) }
        let uri = file["uri"].text
        if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") { return Data(base64Encoded: String(uri[uri.index(after: comma)...])) }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = preview ?? embedded.flatMap({ NSImage(data: $0) }) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 540, maxHeight: 320)
            }
            HStack {
                Label(file["name"].string ?? file["mime"].string ?? "Attachment", systemImage: "paperclip")
                Button("Save…") { model.perform {
                    let bytes = try await contents()
                    let panel = NSSavePanel(); panel.nameFieldStringValue = file["name"].string ?? "opencode-attachment"
                    if panel.runModal() == .OK, let url = panel.url { try bytes.write(to: url, options: .atomic) }
                } }
                if embedded == nil { Button("Preview") { model.perform {
                    do { preview = NSImage(data: try await contents()); if preview == nil { failure = "Use Save to inspect this file." } }
                    catch { failure = error.localizedDescription }
                } } }
            }.font(.caption)
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func contents() async throws -> Data {
        if let embedded { return embedded }
        let uri = file["uri"].string ?? file["source"]["uri"].text
        guard let location = URL(string: uri), location.isFileURL, let link = model.links[conversationID] else {
            throw OpenCodeError.message("This attachment has no embedded content or server file reference.")
        }
        return try await model.coordinator.readFile(connectionID: link.connectionID, path: location.path, query: model.locationQuery(conversationID)).0
    }
}

struct OpenCodeShellJobs: View {
    let model: OpenCodeModel
    let conversationID: String
    @State private var jobs: [OpenCodeValue] = []
    @State private var output = ""
    @State private var selected: String?
    @State private var cursor = "0"
    @State private var stop: String?
    var body: some View {
        DisclosureGroup("Background shell jobs") {
            Button("Refresh Jobs") { model.perform { jobs = try await model.resource("shell", conversationID: conversationID)["data"].array } }
            ForEach(jobs, id: \.self) { job in
                HStack {
                    Text(job["command"].text).lineLimit(2); Text(job["status"].text).foregroundStyle(.secondary)
                    Spacer()
                    Button("Output") { selected = job["id"].text; cursor = "0"; output = ""; read() }
                    if job["status"].text == "running" { Button("Stop…") { stop = job["id"].text } }
                }
            }
            if selected != nil {
                ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 260)
                Button("Read More") { read() }
            }
        }.confirmationDialog("Stop this shell job on the OpenCode host?", isPresented: Binding(get: { stop != nil }, set: { if !$0 { stop = nil } }), titleVisibility: .visible) {
            Button("Stop Job", role: .destructive) { if let stop { model.perform {
                _ = try await model.resource("shell/" + OpenCodeHTTPClient.segment(stop), conversationID: conversationID, method: "DELETE")
                self.stop = nil; jobs = try await model.resource("shell", conversationID: conversationID)["data"].array
            } } }
        }
    }
    private func read() { model.perform {
        guard let selected else { return }
        let page = try await model.resource("shell/" + OpenCodeHTTPClient.segment(selected) + "/output", conversationID: conversationID, query: ["cursor": cursor, "limit": "65536"])["data"]
        output += page["output"].text; cursor = String(format: "%.0f", page["cursor"].number ?? 0)
    } }
}
