import SwiftUI
import WovenMatterCore

/// Show services people use first. Technical processes stay in flat disclosures.
struct RuntimeInspectionInventoryView: View {
    @Environment(\.dashboardTheme) private var theme
    let items: [RuntimeInspection.Item]
    let connected: Bool

    private var inventory: RuntimeInspectionInventory { .init(items: items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !inventory.servers.isEmpty {
                section("Server") {
                    ForEach(inventory.servers) { item in row(item) }
                    if !inventory.otherProcesses.isEmpty {
                        processDetails(inventory.otherProcesses, title: "Other processes")
                    }
                }
            }
            section("Agent activity") {
                if inventory.agents.isEmpty {
                    Text(connected ? "No active agent sessions. Chats and their agent processes appear here when they run." : "No agent sessions in the last observation.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(inventory.agents) { agent in
                        VStack(alignment: .leading, spacing: 10) {
                            row(agent.summary)
                            if !agent.details.isEmpty {
                                processDetails(agent.details, title: "Processes and activity (\(agent.details.count))")
                            }
                        }
                    }
                }
            }
            if !inventory.connections.isEmpty {
                section("Device connection") {
                    let transport = inventory.connections.first { $0.kind == "connectionProcess" }
                    row(.init(id: "device-connection", kind: "connection", title: "Paired devices",
                              state: transport?.state ?? "unknown", detail: "Tailscale sharing for this server"))
                    processDetails(inventory.connections, title: "Process details")
                }
            }
            if inventory.servers.isEmpty, !inventory.otherProcesses.isEmpty {
                section("Other activity") { processDetails(inventory.otherProcesses, title: "Processes") }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.themeWhisper)
        .clipShape(DashboardShapes.card)
    }

    private func processDetails(_ entries: [RuntimeInspection.Item], title: String) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(entries) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        row(item)
                        if let parent = items.first(where: { $0.id == item.parentID }) {
                            Text("Managed by \(parent.title)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(.top, 8)
        } label: {
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ item: RuntimeInspection.Item) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(item.kind)).font(.system(size: 13))
                .foregroundStyle(.secondary).frame(width: 16, height: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.title).font(.system(size: 13, weight: .medium))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(connected ? item.state.capitalized : "Last: \(item.state)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if item.kind != "connection" {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            identity(item)
                            resources(item)
                        }
                        VStack(alignment: .leading, spacing: 3) { identity(item); resources(item) }
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }
        }
    }

    private func identity(_ item: RuntimeInspection.Item) -> some View {
        HStack(spacing: 10) {
            Text(item.kind == "connectionSupervisor" ? "Helper" : item.kind == "connectionProcess" ? "Transport" : item.kind.capitalized)
            if let pid = item.processID { Text("PID \(pid)") }
        }
    }
    private func resources(_ item: RuntimeInspection.Item) -> some View {
        HStack(spacing: 10) {
            if let memory = item.residentBytes { Text(ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)) }
            if let cpu = item.cpuPercent { Text(String(format: "%.1f%% CPU", cpu)) }
        }
    }
    private func icon(_ kind: String) -> String {
        switch kind {
        case "service": "server.rack"
        case "connection", "connectionSupervisor", "connectionProcess": "network"
        case "conversation": "bubble.left"
        case "subagent": "person.2"
        case "tool": "wrench"
        case "scheduler": "clock"
        default: "terminal"
        }
    }
}
