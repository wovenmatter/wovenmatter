import SwiftUI
import WovenMatterCore

/// One surface per owner, with compact connected branches for owned activity.
struct RuntimeInspectionTree: View {
    @Environment(\.dashboardTheme) private var theme
    let items: [RuntimeInspection.Item]
    let connected: Bool

    private struct Branch: Identifiable {
        let item: RuntimeInspection.Item
        let continuations: [Bool]
        let isLast: Bool
        var id: String { item.id }
    }
    private struct Group: Identifiable {
        let owner: RuntimeInspection.Item
        var branches: [Branch]
        var id: String { owner.id }
    }

    private var groups: [Group] {
        let ids = Set(items.map(\.id))
        let children = Dictionary(grouping: items.filter { $0.parentID != nil }, by: { $0.parentID! })
        var seen = Set<String>(), result: [Group] = []
        func group(_ owner: RuntimeInspection.Item) {
            guard seen.insert(owner.id).inserted else { return }
            var branches: [Branch] = []
            func appendChildren(_ id: String, continuations: [Bool]) {
                let siblings = (children[id] ?? []).filter { !seen.contains($0.id) }.sorted { $0.title < $1.title }
                for (index, item) in siblings.enumerated() {
                    guard seen.insert(item.id).inserted else { continue }
                    let isLast = index == siblings.count - 1
                    branches.append(.init(item: item, continuations: Array(continuations.suffix(5)), isLast: isLast))
                    appendChildren(item.id, continuations: continuations + [!isLast])
                }
            }
            appendChildren(owner.id, continuations: [])
            result.append(.init(owner: owner, branches: branches))
        }
        for item in items where item.parentID == nil || !ids.contains(item.parentID!) { group(item) }
        // Missing parents and cycles remain visible without recursion loops.
        for item in items { group(item) }
        return result
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    row(group.owner, isOwner: true).padding(.bottom, group.branches.isEmpty ? 0 : 8)
                    ForEach(group.branches) { branch in
                        HStack(alignment: .top, spacing: 0) {
                            Color.clear
                                .frame(width: CGFloat(branch.continuations.count + 1) * 20)
                                .overlay {
                                    Canvas { context, size in
                                        var path = Path()
                                        for (index, continues) in branch.continuations.enumerated() where continues {
                                            let x = CGFloat(index) * 20 + 8
                                            path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height))
                                        }
                                        let x = CGFloat(branch.continuations.count) * 20 + 8
                                        path.move(to: .init(x: x, y: 0))
                                        path.addLine(to: .init(x: x, y: branch.isLast ? 15 : size.height))
                                        path.move(to: .init(x: x, y: 15)); path.addLine(to: .init(x: size.width - 5, y: 15))
                                        context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                                    }
                                }
                                .accessibilityHidden(true)
                            row(branch.item, isOwner: false).padding(.vertical, 6)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.themeWhisper)
                .clipShape(DashboardShapes.card)
            }
        }
    }

    private func row(_ item: RuntimeInspection.Item, isOwner: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(item.kind))
                .font(.system(size: isOwner ? 14 : 11))
                .foregroundStyle(.secondary).frame(width: 16, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.title).font(.system(size: isOwner ? 13 : 12, weight: isOwner ? .semibold : .medium))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(connected ? item.state.capitalized : "Last: \(item.state)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    metrics(item)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.kind.capitalized + (item.processID.map { " · PID \($0)" } ?? ""))
                        resources(item)
                    }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }
        }
    }

    private func metrics(_ item: RuntimeInspection.Item) -> some View {
        HStack(spacing: 10) {
            Text(item.kind.capitalized)
            if let pid = item.processID { Text("PID \(pid)") }
            resources(item)
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
        case "conversation": "bubble.left"
        case "subagent": "person.2"
        case "tool": "wrench"
        case "scheduler": "clock"
        default: "terminal"
        }
    }
}
