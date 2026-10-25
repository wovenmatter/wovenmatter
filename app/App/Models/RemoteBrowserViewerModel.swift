import AppKit
import ImageIO
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
    private var activePointers: [String: RemoteBrowserAction] = [:]
    private var pendingInput: [RemoteBrowserAction] = []
    private var sendingInput = false
    private var revision = UUID()
    private var refreshing = false
    private var refreshingTabs = false
    private let loadTabs: () async throws -> RemoteBrowserTabs
    private let loadFrame: (String, String?) async throws -> RemoteBrowserFrame
    private let sendBatch: (([RemoteBrowserAction]) async throws -> RemoteBrowserActionBatchResult)?
    private let copyText: (String) -> Void
    private let sendAction: (RemoteBrowserAction) async throws -> RemoteBrowserActionResult

    init(loadTabs: @escaping () async throws -> RemoteBrowserTabs,
         loadFrame: @escaping (String, String?) async throws -> RemoteBrowserFrame,
         sendBatch: (([RemoteBrowserAction]) async throws -> RemoteBrowserActionBatchResult)? = nil,
         sendAction: @escaping (RemoteBrowserAction) async throws -> RemoteBrowserActionResult = { action in
             .init(tabID: action.tabID, accepted: false)
         }, copyText: @escaping (String) -> Void = { text in
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.sendBatch = sendBatch
        self.loadTabs = loadTabs; self.loadFrame = loadFrame; self.sendAction = sendAction; self.copyText = copyText
    }

    var selectedTab: RemoteBrowserTab? { tabs.first { $0.id == selectedID } }

    func select(_ id: String) {
        guard id != selectedID else { return }
        cancelPointer()
        revision = UUID()
        selectedID = id
        pendingInput.removeAll(); frameID = nil; inputError = nil
        image = nil
        updatedAt = nil
        error = nil
    }

    func clear() {
        cancelPointer()
        revision = UUID()
        pendingInput.removeAll(); frameID = nil; inputError = nil
        tabs = []; selectedID = nil; image = nil; updatedAt = nil; error = nil; hasLoaded = false
    }

    private func cancelPointer(_ gestureID: String? = nil) {
        let ids = gestureID.map { [$0] } ?? Array(activePointers.keys)
        pendingInput.removeAll { action in action.gestureID.map { ids.contains($0) } ?? false }
        for id in ids {
            guard var action = activePointers.removeValue(forKey: id) else { continue }
            action.kind = "pointerCancel"; action.actionID = UUID().uuidString.lowercased()
            // Cancellation can overtake a press; the service rejects late input
            // for this gesture. Keep completed clicks until their release is acknowledged.
            Task { [sendAction, action] in _ = try? await sendAction(action) }
        }
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
        if action.kind == "pointerCancel" { cancelPointer(action.gestureID); return }
        // Coalesce pointer motion and wheel bursts while preserving input order.
        if let last = pendingInput.last, last.kind == action.kind,
           last.frameID == action.frameID || action.kind == "pointerMove",
           ["move", "scroll", "text", "pointerMove"].contains(action.kind), last.gestureID == action.gestureID,
           action.kind != "text" || ((last.text ?? "") + (action.text ?? "")).utf8.count <= 16384 {
            if action.kind == "scroll" {
                action.deltaX = max(-4000, min(4000, (last.deltaX ?? 0) + (action.deltaX ?? 0)))
                action.deltaY = max(-4000, min(4000, (last.deltaY ?? 0) + (action.deltaY ?? 0)))
            } else if action.kind == "text", ((last.text ?? "") + (action.text ?? "")).utf8.count <= 16384 {
                action.text = (last.text ?? "") + (action.text ?? "")
            }
            pendingInput.removeLast()
        }
        guard pendingInput.count < 128 else {
            if action.kind == "pointerUp" { cancelPointer(action.gestureID) }
            inputError = "The workspace is catching up with your input."; return
        }
        if action.kind == "pointerDown", let id = action.gestureID { activePointers[id] = action }
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
            var batch = [action], bytes = action.text?.utf8.count ?? 0
            if sendBatch != nil {
                // No batching timer: send the first gesture immediately, then
                // amortize the next network round trip over input already queued.
                while batch.count < 32, let next = pendingInput.first, next.tabID == action.tabID,
                      bytes + (next.text?.utf8.count ?? 0) < 48000 {
                    batch.append(pendingInput.removeFirst()); bytes += next.text?.utf8.count ?? 0
                }
            }
            do {
                let results: [RemoteBrowserActionResult]
                if let sendBatch { results = try await sendBatch(batch).results }
                else { results = [try await sendAction(action)] }
                guard requestRevision == revision, selectedID == action.tabID else { continue }
                guard results.count == batch.count, results.allSatisfy({ $0.accepted && $0.tabID == action.tabID }) else {
                    throw RemoteWorkspaceClientError.invalidResponse("The workspace did not accept this input.")
                }
                for (gesture, result) in zip(batch, results) {
                    if gesture.kind == "pointerUp", let id = gesture.gestureID { activePointers.removeValue(forKey: id) }
                    if gesture.kind == "copy", let text = result.text, !text.isEmpty, text.utf8.count <= 65536 { copyText(text) }
                }
                inputError = nil
            } catch {
                guard requestRevision == revision else { continue }
                // Never replay uncertain input or send queued text to a newly navigated page.
                pendingInput.removeAll(); cancelPointer()
                inputError = error.localizedDescription
            }
        }
        if revision == drainRevision {
            // Refresh independently: input arriving during image loading must
            // start draining immediately, without needing another gesture.
            Task { [weak self] in
                guard let self, self.revision == drainRevision else { return }
                await self.refresh(includeTabs: false)
            }
        }
    }

    func refreshTabs() async {
        guard !refreshingTabs else { return }
        refreshingTabs = true
        defer { refreshingTabs = false }
        let requestRevision = revision
        do {
            let result = try await loadTabs()
            guard !Task.isCancelled, requestRevision == revision else { return }
            let current = result.running ? Array(result.tabs.prefix(64)) : []
            if tabs != current { tabs = current }
            hasLoaded = true
            if !tabs.contains(where: { $0.id == selectedID }) {
                cancelPointer(); revision = UUID()
                selectedID = tabs.first?.id; image = nil; updatedAt = nil; frameID = nil; pendingInput.removeAll()
            }
        } catch {
            guard !Task.isCancelled, requestRevision == revision else { return }
            cancelPointer()
            tabs = []; selectedID = nil; image = nil; updatedAt = nil; hasLoaded = true
            self.error = error.localizedDescription; frameID = nil; pendingInput.removeAll()
        }
    }

    func refresh(includeTabs: Bool = true) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if includeTabs { await refreshTabs() }
        guard let id = selectedID else { return }
        let requestRevision = revision, previousFrameID = frameID
        do {
            let frame = try await loadFrame(id, previousFrameID)
            guard !Task.isCancelled, requestRevision == revision, selectedID == id else { return }
            guard frame.tabID == id, frame.imageBase64.utf8.count <= 2 * 1024 * 1024 else { throw BackendRPCError.invalidFrame }
            if frame.imageBase64.isEmpty {
                guard image != nil, previousFrameID != nil else { throw BackendRPCError.invalidFrame }
            } else {
                let decoded = try await Self.decodeImage(frame.imageBase64)
                guard !Task.isCancelled, requestRevision == revision, selectedID == id else { return }
                image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                updatedAt = .now
            }
            if frameID != frame.frameID { frameID = frame.frameID }
            error = nil
        } catch {
            guard !Task.isCancelled, requestRevision == revision, selectedID == id else { return }
            cancelPointer()
            image = nil; updatedAt = nil; self.error = error.localizedDescription; frameID = nil; pendingInput.removeAll()
        }
    }

    /// Decode and decompress away from AppKit's event/drawing thread.
    nonisolated private static func decodeImage(_ base64: String) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let bytes = Data(base64Encoded: base64),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 1920, height <= 1200,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw RemoteWorkspaceClientError.invalidResponse("The workspace returned an invalid browser image.") }
            return image
        }.value
    }
}
