import AppKit
import SwiftUI
import WovenMatterCore

/// Raw credentials stay in this view's transient state. The persistent access
/// list contains only credential metadata and the host's token hashes.
struct SettingsMCPAccessSection: View {
    @Bindable var model: ApplicationModel
    @State private var snapshot: WovenMCPAccessSnapshot?
    @State private var issuedConnection: WovenMCPConnection?
    @State private var showsCreate = false
    @State private var label = ""
    @State private var sessionID = ""
    @State private var readOnly = true
    @State private var groups: Set<WorkspaceToolGroup> = [.notes, .history, .sessions, .goals, .usage, .calendar, .library]
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false

    private var conversations: [WorkspaceConversationRecord] {
        (model.workspaceOverview?.conversations ?? []).filter {
            !$0.isArchived && $0.localRuntimeKind.map {
                [.defaultAgent, .codex, .claudeCode, .grokBuild, .opencode].contains($0)
            } == true
        }
    }

    var body: some View {
        SettingsCard(title: "Woven MCP access",
                     detail: "Connect an outside agent to this Woven Matter instance. Each connection uses one chat’s current tool permissions and can be revoked here.") {
            VStack(alignment: .leading, spacing: 12) {
                endpointRow
                if let snapshot {
                    if snapshot.clients.isEmpty {
                        SettingsNote("No outside agents have access.")
                    } else {
                        ForEach(snapshot.clients) { grant in
                            clientRow(grant)
                            if grant.id != snapshot.clients.last?.id { Divider() }
                        }
                    }
                }
                if issuedConnection != nil { issuedCredentialRow }
                DisclosureGroup("Add outside agent", isExpanded: $showsCreate) { createForm.padding(.top, 10) }
                if let error { SettingsNote(error) }
            }
            .font(.system(size: 13))
        }
        .task { await perform(.status) }
        .onDisappear { issuedConnection = nil }
    }

    private var endpointRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP endpoint").font(.system(size: 12.5, weight: .medium))
                if let endpoint = snapshot?.endpointURL {
                    Text(endpoint).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                } else {
                    SettingsNote(busy ? "Loading…" : "Unavailable")
                }
            }
            Spacer(minLength: 8)
            Button("Refresh") { Task { await perform(.status) } }
                .buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
        }
    }

    private func clientRow(_ grant: WovenMCPClientGrant) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(grant.label).font(.system(size: 13, weight: .medium))
                Text(conversationTitle(grant.sessionID))
                    .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                Text((grant.readOnly ? "Read only" : "Read and write") + " · " + grant.groups.sorted { $0.title < $1.title }.map(\.title).joined(separator: ", "))
                    .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Revoke", role: .destructive) { Task { await perform(.revoke(grant.id)) } }
                .buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                .accessibilityLabel("Revoke \(grant.label) MCP access")
        }
    }

    private var issuedCredentialRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsNote("Access is ready. Copy this agent’s configuration now; its token is shown only through this copy action.")
            HStack(spacing: 8) {
                Button(copied ? "Configuration copied" : "Copy MCP configuration") { copyConfiguration() }
                    .buttonStyle(SettingsQuietButtonStyle())
                Button("Done") { issuedConnection = nil; copied = false }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Agent name", text: $label).settingsInput()
                .accessibilityLabel("Outside agent name")
            Picker("Act through chat", selection: $sessionID) {
                Text("Choose a chat").tag("")
                ForEach(conversations) { conversation in
                    Text(conversation.title).tag(conversation.id)
                }
            }
            .pickerStyle(.menu)
            if conversations.isEmpty {
                SettingsNote("Create a chat in this instance before granting outside-agent access.")
            }
            Toggle("Read only", isOn: $readOnly).toggleStyle(DashboardSwitchToggleStyle())
            SettingsNote("Access is limited to the selected groups and the chat’s current settings. Turning a tool off in the chat takes effect for this connection too.")
            DisclosureGroup("Tool groups") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(WorkspaceToolGroup.allCases) { group in
                        Toggle(group.title, isOn: Binding(get: { groups.contains(group) }, set: { enabled in
                            if enabled { groups.insert(group) } else { groups.remove(group) }
                        }))
                        .toggleStyle(DashboardSwitchToggleStyle())
                    }
                }.padding(.top, 10)
            }
            Button("Create access") {
                Task {
                    await perform(.create(label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                                          sessionID: sessionID, groups: groups, readOnly: readOnly))
                }
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(busy || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || groups.isEmpty
                      || !conversations.contains(where: { $0.id == sessionID }))
        }
        .disabled(busy)
    }

    private func conversationTitle(_ id: String) -> String {
        model.workspaceOverview?.conversations.first(where: { $0.id == id })?.title ?? "Chat unavailable"
    }

    @MainActor
    private func perform(_ action: WovenMCPAccessAction) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var next = try await model.controlMCPAccess(action)
            if let issued = next.issuedConnection {
                issuedConnection = issued; copied = false; showsCreate = false
                label = ""
            }
            next.issuedConnection = nil
            snapshot = next
        } catch { self.error = error.localizedDescription }
    }

    private func copyConfiguration() {
        guard let connection = issuedConnection else { return }
        let config = ["mcpServers": ["woven": ["url": connection.endpointURL,
                                                "headers": ["Authorization": "Bearer " + connection.bearerToken]]]] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string)
    }
}
