import SwiftUI

struct ConversationGoalControls: View {
    @Environment(\.wovenTheme) private var theme
    let session: SessionStore
    @State private var showingDetails = false
    @State private var error: String?
    @State private var busy = false
    private var goal: WorkspaceGoal? { session.goal }

    var body: some View {
        if let goal {
            HStack(spacing: 8) {
                Text("Pursuing goal").font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Button(role: .destructive) { mutate(.clear(id: goal.id)) } label: {
                    Text("Delete").padding(.horizontal, 6).frame(height: 24)
                }.disabled(busy)
                Button { showingDetails = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12)).frame(width: 24, height: 24)
                }
                .help("Expand goal")
                .accessibilityLabel("Expand goal")
            }
            .font(.system(size: 11))
            .buttonStyle(WovenIconButtonStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(theme.palette.themeWhisper, in: DesktopShapes.card)
            // Above the composer the chat scrolls beneath it, so it is not see-through.
            .background(WovenPalette.background, in: DesktopShapes.card)
            .sheet(isPresented: $showingDetails) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Goal").font(.headline)
                        Spacer()
                        Text("Pursuing goal").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(goal.objective).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.never).frame(minHeight: 180, maxHeight: 360)
                    HStack {
                        Spacer()
                        Button("Done") { showingDetails = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 480)
            }
            .alert("Unable to update goal", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func mutate(_ mutation: WorkspaceGoalMutation) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await session.updateGoal(mutation)
                showingDetails = false
            } catch { self.error = error.localizedDescription }
        }
    }
}
