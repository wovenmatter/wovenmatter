import AppKit
import Observation
import WovenMatterClient

/// Frames are ephemeral, tied to the selected tab and the lifetime of this viewer.
@MainActor @Observable
final class RemoteBrowserViewerModel {
    private(set) var tabs: [RemoteBrowserTab] = []
    private(set) var selectedID: String?
    private(set) var image: NSImage?
    private(set) var error: String?
    private(set) var hasLoaded = false
    private(set) var updatedAt: Date?
    private(set) var inputError: String?
    private(set) var frameID: String?
    private var pendingInput: [RemoteBrowserAction] = []
    private var sendingInput = false
    private var revision = UUID()
    private var refreshing = false
    private let loadTabs: () async throws -> RemoteBrowserTabs
    private let loadFrame: (String) async throws -> RemoteBrowserFrame
    private let copyText: (String) -> Void
    private let sendAction: (RemoteBrowserAction) async throws -> RemoteBrowserActionResult

    init(loadTabs: @escaping () async throws -> RemoteBrowserTabs,
         loadFrame: @escaping (String) async throws -> RemoteBrowserFrame,
         sendAction: @escaping (RemoteBrowserAction) async throws -> RemoteBrowserActionResult = { action in
             .init(tabID: action.tabID, accepted: false)
         }, copyText: @escaping (String) -> Void = { text in
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.loadTabs = loadTabs; self.loadFrame = loadFrame; self.sendAction = sendAction; self.copyText = copyText
    }

    var selectedTab: RemoteBrowserTab? { tabs.first { $0.id == selectedID } }

    func select(_ id: String) {
        guard id != selectedID else { return }
        revision = UUID()
        selectedID = id
        pendingInput.removeAll(); frameID = nil; inputError = nil
        image = nil
        updatedAt = nil
        error = nil
    }

    func clear() {
        revision = UUID()
        pendingInput.removeAll(); frameID = nil; inputError = nil
        tabs = []; selectedID = nil; image = nil; updatedAt = nil; error = nil; hasLoaded = false
    }

    func enqueue(_ gesture: RemoteBrowserAction) {
        guard image != nil, let selectedID, let frameID else {
            inputError = "Wait for a current browser image. If needed, update the workspace container in Settings."
            return
        }
        guard gesture.text?.utf8.count ?? 0 <= 16384 else {
            inputError = "Paste up to 16 KB at a time."; return
        }
        var action = gesture
        if !action.tabID.isEmpty && action.tabID != selectedID { return }
        action.tabID = selectedID
        if action.frameID.isEmpty { action.frameID = frameID }
        // Coalesce pointer motion and wheel bursts while preserving input order.
        if let last = pendingInput.last, last.frameID == frameID, last.kind == action.kind,
           ["move", "scroll", "text"].contains(action.kind),
           action.kind != "text" || ((last.text ?? "") + (action.text ?? "")).utf8.count <= 16384 {
            if action.kind == "scroll" {
                action.deltaX = max(-4000, min(4000, (last.deltaX ?? 0) + (action.deltaX ?? 0)))
                action.deltaY = max(-4000, min(4000, (last.deltaY ?? 0) + (action.deltaY ?? 0)))
            } else if action.kind == "text", ((last.text ?? "") + (action.text ?? "")).utf8.count <= 16384 {
                action.text = (last.text ?? "") + (action.text ?? "")
            }
            pendingInput.removeLast()
        }
        guard pendingInput.count < 128 else { inputError = "The workspace is catching up with your input."; return }
        pendingInput.append(action)
        if !sendingInput { Task { await drainInput() } }
    }

    private func drainInput() async {
        guard !sendingInput else { return }
        sendingInput = true
        let drainRevision = revision
        defer { sendingInput = false }
        while !pendingInput.isEmpty {
            let action = pendingInput.removeFirst(), requestRevision = revision
            guard selectedID == action.tabID else { continue }
            do {
                let result = try await sendAction(action)
                guard requestRevision == revision, selectedID == action.tabID else { continue }
                guard result.accepted, result.tabID == action.tabID else {
                    throw RemoteWorkspaceClientError.invalidResponse("The workspace did not accept this input.")
                }
                if action.kind == "copy", let text = result.text, !text.isEmpty, text.utf8.count <= 65536 {
                    copyText(text)
                }
                inputError = nil
            } catch {
                guard requestRevision == revision else { continue }
                // Never replay uncertain input or send queued text to a newly navigated page.
                pendingInput.removeAll()
                inputError = error.localizedDescription
            }
        }
        if revision == drainRevision {
            // Refresh independently: input arriving during image loading must
            // start draining immediately, without needing another gesture.
            Task { [weak self] in
                guard let self, self.revision == drainRevision else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let requestRevision = revision
        do {
            let result = try await loadTabs()
            guard !Task.isCancelled, requestRevision == revision else { return }
            tabs = result.running ? Array(result.tabs.prefix(64)) : []
            hasLoaded = true
            if !tabs.contains(where: { $0.id == selectedID }) {
                selectedID = tabs.first?.id; image = nil; updatedAt = nil; frameID = nil; pendingInput.removeAll()
            }
            error = nil
            guard let id = selectedID else { image = nil; frameID = nil; return }
            do {
                let frame = try await loadFrame(id)
                guard !Task.isCancelled, requestRevision == revision, selectedID == id else { return }
                guard frame.tabID == id, frame.imageBase64.utf8.count <= 2 * 1024 * 1024,
                      let bytes = Data(base64Encoded: frame.imageBase64), let decoded = NSImage(data: bytes),
                      decoded.size.width > 0, decoded.size.height > 0,
                      decoded.size.width <= 1920, decoded.size.height <= 1200 else {
                    throw RemoteWorkspaceClientError.invalidResponse("The workspace returned an invalid browser image.")
                }
                image = decoded; updatedAt = .now; frameID = frame.frameID
            } catch {
                guard !Task.isCancelled, requestRevision == revision, selectedID == id else { return }
                image = nil; updatedAt = nil; self.error = error.localizedDescription; frameID = nil; pendingInput.removeAll()
            }
        } catch {
            guard !Task.isCancelled, requestRevision == revision else { return }
            tabs = []; selectedID = nil; image = nil; updatedAt = nil; hasLoaded = true
            self.error = error.localizedDescription; frameID = nil; pendingInput.removeAll()
        }
    }
}
