import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct OpenClawSessionLibrary: View {
    let model: ApplicationModel
    let agentID: UUID
    @State private var sessions: [OpenClawGatewaySession] = []
    @State private var nextOffset: Int?
    @State private var currentOffset = 0
    @State private var busy = false
    @State private var feedback: String?

    var body: some View {
        SettingsCard(title: "Shared OpenClaw sessions", detail: "Continue an existing session from OpenClaw without copying or starting a new chat. Imported sessions appear in this agent’s conversation list.") {
            HStack {
                Button("Refresh sessions") { load(offset: 0) }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            ForEach(sessions) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).font(.system(size: 13, weight: .medium))
                        Text(session.key).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DashboardPalette.mutedForeground).lineLimit(2)
                    }
                    Spacer()
                    Button("Import") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await model.importOpenClawSession(agentID: agentID, session: session)
                                feedback = "“\(session.title)” is available in the conversation list."
                            } catch { feedback = error.localizedDescription }
                        }
                    }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
                    .disabled(busy)
                }
            }
            HStack {
                Button("Previous") { load(offset: max(0, currentOffset - 25)) }
                    .disabled(busy || currentOffset == 0)
                Text("Page \(currentOffset / 25 + 1) of up to 10").font(.caption)
                Button("Next") { if let nextOffset { load(offset: nextOffset) } }
                    .disabled(busy || nextOffset == nil || currentOffset >= 225)
            }
            if let feedback { Text(feedback).font(.system(size: 12)).textSelection(.enabled) }
        }
    }

    private func load(offset: Int) {
        busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                let page = try await model.openClawNativeSessions(agentID: agentID, offset: offset)
                sessions = page.sessions
                currentOffset = offset
                nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                if sessions.isEmpty { feedback = "No shared sessions are available." }
            } catch { feedback = error.localizedDescription }
        }
    }
}
