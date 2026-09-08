import SwiftUI
import WovenMatterClient

struct OpenCodeIntegrationsView: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    @State private var integrations: [OpenCodeValue] = []
    @State private var key = ""
    @State private var label = ""
    @State private var code = ""
    @State private var attempt: OpenCodeValue = .null
    @State private var attemptPath = ""
    @State private var attemptStatus = ""
    @State private var selectedMethod: OpenCodeValue = .null
    @State private var selectedIntegration: OpenCodeValue = .null
    @State private var rename: String?
    @State private var credentialLabel = ""
    @State private var revoke: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Providers and integrations").font(.headline)
            Button("Refresh") { reload() }
            ForEach(integrations, id: \.self) { integration in
                DisclosureGroup(integration["name"].text) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(integration["connections"].array, id: \.self) { connection in
                            HStack {
                                Text(connection["label"].string ?? connection["name"].text); Spacer()
                                if connection["type"].text == "credential" {
                                    Button("Use") { model.perform { _ = try await model.resource("credential/" + OpenCodeHTTPClient.segment(connection["id"].text) + "/activate", conversationID: conversationID, method: "POST"); reload() } }
                                    Button("Rename…") { rename = connection["id"].text; credentialLabel = connection["label"].text }
                                    Button("Remove…", role: .destructive) { revoke = connection["id"].text }
                                }
                            }
                        }
                        ForEach(integration["methods"].array, id: \.self) { method in
                            if method["type"].text == "env" { Text("Environment: " + method["names"].array.map(\.text).joined(separator: ", ")).foregroundStyle(.secondary) }
                            else { Button(method["label"].string ?? "Connect with key") { selectedIntegration = integration; selectedMethod = method; key = ""; label = "" } }
                        }
                    }.padding(8)
                }
            }
            if let rename {
                HStack {
                    TextField("Credential label", text: $credentialLabel)
                    Button("Save Label") { model.perform {
                        _ = try await model.resource("credential/" + OpenCodeHTTPClient.segment(rename), conversationID: conversationID, method: "PATCH", body: ["label": .string(credentialLabel)])
                        self.rename = nil; reload()
                    } }
                }
            }
            if !selectedMethod.isNull {
                Divider()
                Text("Connect " + selectedIntegration["name"].text).fontWeight(.semibold)
                TextField("Account label (optional)", text: $label)
                if selectedMethod["type"].text == "key" { SecureField("API key", text: $key) }
                if !selectedMethod["form"].array.isEmpty {
                    OpenCodeFormView(form: ["title": "Connection details", "fields": selectedMethod["form"]]) { answers in
                        if let answers { begin(answer: answers) } else { selectedMethod = .null }
                    }
                } else {
                    if selectedMethod["type"].text == "command" { Text(selectedMethod["command"].array.map(\.text).joined(separator: " ")).font(.system(.caption, design: .monospaced)) }
                    Button("Connect") { begin(answer: nil) }
                }
            }
            if !attempt.isNull {
                Text(attempt["instructions"].text).textSelection(.enabled)
                if let url = URL(string: attempt["url"].text), ["https", "http"].contains(url.scheme) { Link("Open authorization", destination: url) }
                if attempt["mode"].text == "code" {
                    SecureField("Authorization code", text: $code)
                    Button("Complete Sign-in") { model.perform { _ = try await model.resource(attemptPath + "/complete", conversationID: conversationID, method: "POST", body: ["code": .string(code)]); code = ""; poll() } }
                }
                Text(attemptStatus).font(.caption)
                HStack {
                    Button("Check Sign-in") { poll() }
                    Button("Cancel Sign-in") { model.perform { _ = try await model.resource(attemptPath, conversationID: conversationID, method: "DELETE"); attempt = .null } }
                }
            }
        }.textFieldStyle(.roundedBorder).task { reload() }
        .confirmationDialog("Remove this OpenCode credential?", isPresented: Binding(get: { revoke != nil }, set: { if !$0 { revoke = nil } }), titleVisibility: .visible) {
            Button("Remove Credential", role: .destructive) { if let id = revoke { model.perform { _ = try await model.resource("credential/" + OpenCodeHTTPClient.segment(id), conversationID: conversationID, method: "DELETE"); revoke = nil; reload() } } }
        }
    }
    private func reload() { model.perform { integrations = try await model.resource("integration", conversationID: conversationID)["data"].array } }
    private func begin(answer: OpenCodeValue?) {
        model.perform {
            let type = selectedMethod["type"].text
            let path = "integration/" + OpenCodeHTTPClient.segment(selectedIntegration["id"].text) + "/connect/" + type
            var body: OpenCodeValue = [:]
            if type == "key" { body["key"] = .string(key) } else { body["methodID"] = selectedMethod["id"] }
            if let answer { body["answer"] = answer }; if !label.isEmpty { body["label"] = .string(label) }
            let response = try await model.resource(path, conversationID: conversationID, method: "POST", body: body)
            key = ""
            if type != "key" { attempt = response["data"]; attemptPath = path + "/" + OpenCodeHTTPClient.segment(attempt["attemptID"].text); attemptStatus = "Pending" }
            selectedMethod = .null; reload()
        }
    }
    private func poll() { model.perform {
        let response = try await model.resource(attemptPath, conversationID: conversationID)
        attemptStatus = response["data"]["status"].text + " " + response["data"]["message"].text
        if response["data"]["status"].text == "complete" { attempt = .null; reload() }
    } }
}

struct OpenCodeMCPView: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    @State private var servers: OpenCodeValue = .null
    @State private var resources: OpenCodeValue = .null
    @State private var name = ""
    @State private var remote = true
    @State private var url = ""
    @State private var command = ""
    @State private var remove: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP servers").font(.headline)
            ForEach(servers["data"].array, id: \.self) { server in
                let name = server["name"].text
                DisclosureGroup(name) {
                    OpenCodeValueView(value: server["status"])
                    HStack {
                        Button("Connect") { act(name, action: "/connect") }
                        Button("Disconnect") { act(name, action: "/disconnect") }
                        Button("Remove…", role: .destructive) { remove = name }
                    }
                    if !server["integrationID"].isNull { Text("Authorize this server under Integrations.").font(.caption) }
                }
            }
            Divider()
            Text("Add server").font(.headline)
            TextField("Server name", text: $name)
            Toggle("Remote server", isOn: $remote)
            if remote { TextField("MCP URL", text: $url) }
            else { TextField("Command and arguments (one argument per line)", text: $command, axis: .vertical).lineLimit(3...8) }
            Button("Add MCP Server") { model.perform {
                let config: OpenCodeValue = remote ? ["type": "remote", "url": .string(url)] : ["type": "local", "command": .array(command.split(separator: "\n").map { .string(String($0)) })]
                _ = try await model.resource("mcp/" + OpenCodeHTTPClient.segment(name), conversationID: conversationID, method: "PUT", body: ["config": config]); reload()
            } }.disabled(name.isEmpty || (remote ? url.isEmpty : command.isEmpty))
            DisclosureGroup("Resources") { OpenCodeValueView(value: resources) }
            Button("Refresh") { reload() }
        }.textFieldStyle(.roundedBorder).task { reload() }
        .confirmationDialog("Remove this MCP server from OpenCode?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
            Button("Remove Server", role: .destructive) { if let remove { act(remove, action: "", method: "DELETE") } }
        }
    }
    private func reload() { model.perform {
        servers = try await model.resource("mcp", conversationID: conversationID)
        resources = try await model.resource("mcp/resource", conversationID: conversationID)
    } }
    private func act(_ name: String, action: String, method: String = "POST") { model.perform {
        _ = try await model.resource("mcp/" + OpenCodeHTTPClient.segment(name) + action, conversationID: conversationID, method: method); remove = nil; reload()
    } }
}
