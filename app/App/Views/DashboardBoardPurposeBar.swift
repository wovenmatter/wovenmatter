import SwiftUI

/// The project's purpose stays visible while its cards and agents change.
struct DashboardBoardPurposeBar: View {
    @Binding var purpose: String
    let taskCount: Int
    let completedCount: Int
    let needsReviewCount: Int
    let onAddTask: () -> Void
    let onReview: () -> Void
    @Environment(\.dashboardTheme) private var theme
    @State private var showsSharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What is this board for? Add a purpose or project instructions.", text: $purpose, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13))
                .lineLimit(1...3).accessibilityLabel("Board purpose")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { summary; Spacer(minLength: 0); actions }
                VStack(alignment: .leading, spacing: 8) { summary; actions }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.palette.workspace)
        .overlay(alignment: .bottom) { theme.palette.border.frame(height: 1) }
    }

    private var summary: some View {
        Text(taskCount == 0 ? "Tasks, references, and shared work" : "\(completedCount) of \(taskCount) tasks complete")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { showsSharing = true } label: { Image(systemName: "info.circle") }
                .help("Board sharing").accessibilityLabel("Board sharing and permissions")
                .popover(isPresented: $showsSharing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Board sharing").font(.headline)
                        Text("This board follows your library’s existing sync. Agents connected to one Mac share revision checks.")
                        Text("Different Macs sync whole boards. Simultaneous edits can create a recovered copy; review it before continuing. Task assignment is a label, not a distributed lock.")
                        Text("Board contents and linked instructions never grant extra tool permissions.")
                    }.font(.callout).padding(16).frame(width: 310)
                }
            if needsReviewCount > 0 {
                Button(action: onReview) {
                    Label("\(needsReviewCount) to review", systemImage: "tray")
                }.accessibilityLabel("Review \(needsReviewCount) board items")
            }
            Button(action: onAddTask) { Label("Add task", systemImage: "plus") }
        }
        .font(.system(size: 11)).buttonStyle(DashboardQuietButtonStyle())
    }
}
