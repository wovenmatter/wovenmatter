import AppKit
import SwiftUI
import WovenMatterClient

struct OpenCodeSettingsCard: View {
    @Bindable var model: OpenCodeModel
    @State private var remote = false
    @State private var name = ""
    @State private var url = ""
    @State private var username = "opencode"
    @State private var password = ""
    @State private var showSessions = false
    var body: some View {
        SettingsCard(title: "OpenCode v2", detail: "Connect to a shared OpenCode service. Existing v1 transcripts remain read-only.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Connect on This Mac") { model.perform { try await model.connectLocal() } }
                    Button("Remote Server…") { remote.toggle() }
                    Spacer()
                    Text(OpenCodeConnection.supportedVersion).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.servers) { server in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(server.name).fontWeight(.medium)
                            Text(server.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if model.connected.contains(server.id) {
                            Text("Connected").font(.caption)
                            Button("Disconnect") { model.perform { await model.disconnect(server.id) } }
                        } else { Button("Connect") { model.perform { try await model.connect(server) } } }
                        Button("Sessions…") {
                            model.selectedServerID = server.id; model.savePreferences(); showSessions = true
                        }.disabled(!model.connected.contains(server.id))
                    }
                }
                if remote {
                    TextField("Server name", text: $name)
                    TextField("Server URL", text: $url)
                    TextField("Username", text: $username)
                    SecureField("Service password", text: $password)
                    Button("Save and Connect") { model.perform {
                        try await model.addRemote(name: name, url: url, username: username, password: password)
                        password = ""; remote = false
                    } }
                }
                TextField("Workspace path on the OpenCode host", text: $model.directory).onSubmit { model.savePreferences() }
                DisclosureGroup("Local service setup") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Service registration file", text: $model.registrationPath).onSubmit { model.savePreferences() }
                        Text("Install the tested beta with the official package, then select opencode2.")
                        Text("npm install -g @opencode/cli@\(OpenCodeConnection.supportedVersion)")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            TextField("opencode2 executable", text: $model.executablePath)
                            Button("Choose…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let file = panel.url { model.executablePath = file.path; model.savePreferences() }
                            }
                        }
                        Button("Start Shared Service") { model.perform {
                            model.savePreferences()
                            try await OpenCodeServiceLauncher.start(executable: URL(fileURLWithPath: model.executablePath), registration: URL(fileURLWithPath: model.registrationPath))
                            try await model.connectLocal()
                        } }.disabled(model.executablePath.isEmpty)
                        Text("Disconnecting Woven Matter leaves the service and its work running.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            }.textFieldStyle(.roundedBorder).buttonStyle(.bordered).controlSize(.small)
        }
        .sheet(isPresented: $showSessions) { OpenCodeSessionBrowser(model: model) }
    }
}

struct OpenCodeSessionBrowser: View {
    @Bindable var model: OpenCodeModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OpenCode sessions").font(.title2)
                Spacer()
                Button("Done") { dismiss() }
            }
            Picker("Server", selection: $model.selectedServerID) {
                ForEach(model.servers) { Text($0.name).tag($0.id) }
            }
            HStack {
                TextField("Search sessions", text: $search).onSubmit { reload() }
                Button("Search") { reload() }
                Button("Import…") { model.perform {
                    let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        let bytes = try Data(contentsOf: url)
                        guard bytes.count < 32 * 1024 * 1024 else { throw OpenCodeError.message("Session export exceeds 32 MB.") }
                        var body = try OpenCodeValue.decode(bytes)
                        body["location"] = ["directory": .string(model.directory)]
                        let response = try await model.resource("session/import", method: "POST", body: body)
                        model.requestedConversationID = try await model.open(response["data"]); dismiss()
                    }
                } }
                Button("New Session") { model.perform { model.requestedConversationID = try await model.create(); dismiss() } }
            }
            TextField("New session workspace on server", text: $model.directory)
            List {
                ForEach(model.sessions, id: \.self) { session in
                    Button { model.perform { model.requestedConversationID = try await model.open(session); dismiss() } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session["title"].string ?? "Untitled session").foregroundStyle(.primary)
                            Text(session["location"]["directory"].text).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
                if model.sessionsCursor != nil {
                    Button("Load More") { model.perform { try await model.listSessions(search: search, more: true) } }
                }
            }
            if loading { ProgressView() }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }.padding(20).frame(minWidth: 560, minHeight: 480).textFieldStyle(.roundedBorder)
        .task(id: model.selectedServerID) { reload() }
    }
    private func reload() {
        model.perform { loading = true; defer { loading = false }; try await model.listSessions(search: search) }
    }
}
