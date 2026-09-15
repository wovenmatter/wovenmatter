import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct OpenClawSessionLibrary: View {
    let model: ApplicationModel
    let agentID: UUID
    @State private var sessions: [OpenClawGatewaySession] = []
    @State private var nextOffset: Int?
    @State private var pageOffsets = [0]
    @State private var currentPage = 0
    @State private var busy = false
    @State private var feedback: String?

    var body: some View {
        SettingsCard(title: "Shared OpenClaw sessions", detail: "Import an existing conversation with its original working directory.") {
            HStack {
                Button("Refresh sessions") { load(page: 0) }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 26))
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
                                sessions.removeAll { $0.key == session.key }
                                feedback = "“\(session.title)” is available in the conversation list."
                            } catch { feedback = error.localizedDescription }
                        }
                    }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
                    .disabled(busy)
                }
            }
            HStack {
                Button("Previous") { load(page: currentPage - 1) }
                    .disabled(busy || currentPage == 0)
                Text("Page \(currentPage + 1) of up to 10").font(.caption)
                Button("Next") {
                    if let nextOffset {
                        pageOffsets = Array(pageOffsets.prefix(currentPage + 1)) + [nextOffset]
                        load(page: currentPage + 1)
                    }
                }
                    .disabled(busy || nextOffset == nil || currentPage >= 9)
            }
            .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
            if let feedback { Text(feedback).font(.system(size: 12)).textSelection(.enabled) }
        }
    }

    private func load(page index: Int) {
        guard pageOffsets.indices.contains(index) else { return }
        let offset = pageOffsets[index]
        busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                let page = try await model.openClawNativeSessions(agentID: agentID, offset: offset)
                if index == 0 { pageOffsets = [0] }
                sessions = page.sessions
                currentPage = index
                nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                if sessions.isEmpty { feedback = "No shared sessions are available." }
            } catch { feedback = error.localizedDescription }
        }
    }
}
