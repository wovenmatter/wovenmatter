import Foundation
import WovenProtocol

/// Carries out the browser, computer and visual-reply preview calls this Mac's server sends its UI,
/// and the update another machine asked for, for as long as the app runs, and answers each one.
@MainActor
final class UIToolsStore {
    private let host: WovenAutomationHost
    private var following: Task<Void, Never>?

    init(server: ServerConnection, assets: WorkspaceAssetSession) {
        host = WovenAutomationHost(assets: assets)
        following = Task { [weak self] in
            await server.follow(SubscribeUITools(), reply: { _ in }, event: { [weak self] call in
                self?.carryOut(call, server: server)
            })
        }
    }

    private func carryOut(_ call: UIToolCall, server: ServerConnection) {
        if call.tool == "app_update" {
            Task {
                let failure = await DesktopUpdater.shared.updateWithoutAsking()
                _ = try? await server.call(AnswerUITool(id: call.id, result: failure.map(ToolResult.error) ?? .text("Updating.")))
                // Installs, quits and relaunches only once the answer has gone.
                if failure == nil { DesktopUpdater.shared.installWhenReady() }
            }
            return
        }
        Task { [host] in
            // A preview has its own web view, so it never waits on the browser or computer.
            let result = call.tool == "preview_html" ? await VisualReplyPreview().run(call.arguments) : await host.handle(call)
            _ = try? await server.call(AnswerUITool(id: call.id, result: result))
        }
    }
}
