import AppKit
import Observation
import WovenProtocol

/// Lives above the pane's SwiftUI branches, so chat selection, resizing and
/// temporary utility screens cannot destroy browser sessions.
@MainActor @Observable
final class WorkspaceAssetSession: NSObject, @preconcurrency WMBrowserPageDelegate {
    var tabs = WorkspaceAssetTabs()
    private(set) var documents: [String: URL] = [:]
    private(set) var pages: [UUID: WMBrowserPage] = [:]
    private(set) var pageRevision = 0
    private(set) var browserPresentationRevision = 0
    var notice: String?
    var automationTabs: [JSONValue] {
        tabs.browserIDs.compactMap { id in
            pages[id].map { .object(["tabId": .string(id.uuidString.lowercased()), "url": .string($0.url),
                                    "title": .string($0.title), "loading": .bool($0.loading)]) }
        }
    }
    static let clearDataKey = "wovenmatter.browser.clear-on-launch"

    func openNote(_ id: String) {
        do { try tabs.open(.note(id)) } catch { notice = error.localizedDescription }
    }

    /// URLs must be prepared by the Library/attachment service, never taken from message text.
    func openDocument(_ url: URL, identity: String? = nil) throws {
        guard url.isFileURL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw WorkspaceToolError.invalid("This file is no longer available. Open it again from the conversation or Library.")
        }
        let url = url.standardizedFileURL
        let id = documents.first(where: { $0.value == url })?.key ?? identity ?? url.path
        try tabs.open(.document(id))
        documents[id] = url
    }

    @discardableResult
    func openBrowser(url: String = "about:blank", load: Bool = true) -> WMBrowserPage? {
        guard tabs.browserIDs.count < WorkspaceAssetTabs.maximumBrowsers else {
            notice = WorkspaceAssetTabs.Capacity.browsers.localizedDescription
            return nil
        }
        do {
            try prepareBrowser()
            guard let page = WMBrowserRuntime.shared().createPage() else {
                notice = "The browser is shutting down. Reopen Woven Matter to browse again."
                return nil
            }
            let id = UUID()
            pages[id] = page
            page.delegate = self
            try tabs.open(.browser(id))
            if load { page.loadURL(url) }
            return page
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    func close(_ tab: WorkspaceAssetTabs.Tab) {
        switch tab {
        case .note: tabs.close(tab)
        case .document(let id):
            documents.removeValue(forKey: id)
            tabs.close(tab)
        case .browser(let id): pages[id]?.close()
        }
    }

    func focusAutomationBrowser(_ id: UUID) {
        tabs.select(.browser(id))
        browserPresentationRevision &+= 1
    }

    func title(for tab: WorkspaceAssetTabs.Tab, notes: [WorkspaceNoteRecord]) -> String {
        switch tab {
        case .document(let id): documents[id]?.lastPathComponent ?? "Document"
        case .note(let id): notes.first { $0.id == id }?.title ?? "Note"
        case .browser(let id):
            pages[id].map { $0.title.isEmpty ? "New tab" : $0.title } ?? "New tab"
        }
    }

    func snapshot(notes: [WorkspaceNoteRecord], title: (WorkspaceNoteRecord) -> String) -> WorkspaceVisibleContext? {
        guard tabs.isPresented else { return nil }
        let openNotes = tabs.noteIDs.compactMap { id -> WorkspaceVisibleContext.Note? in
            guard let note = notes.first(where: { $0.id == id }) else { return nil }
            let edited = (note.updatedAt ?? note.createdAt).map { $0.formatted(.iso8601) } ?? ""
            return .init(id: id, title: title(note), revision: edited,
                         active: tabs.selected == .note(id), kind: note.kind)
        }
        let openPages = tabs.browserIDs.compactMap { id -> WorkspaceVisibleContext.Page? in
            guard let page = pages[id] else { return nil }
            return .init(title: page.title, url: page.url, active: tabs.selected == .browser(id))
        }
        return .init(notes: openNotes, pages: openPages)
    }

    func browserPageDidChange(_ page: WMBrowserPage) { pageRevision &+= 1 }
    func browserPageDidClose(_ page: WMBrowserPage) {
        guard let id = pages.first(where: { $0.value === page })?.key else { return }
        pages.removeValue(forKey: id)
        tabs.close(.browser(id))
    }
    func browserPage(_ page: WMBrowserPage, createPopup url: String) -> WMBrowserPage? {
        openBrowser(url: url, load: false)
    }
    func browserPage(_ page: WMBrowserPage, showMessage message: String) { notice = message }

    /// Website passwords are not saved yet, so there is nothing to fill.
    func browserPage(_ page: WMBrowserPage, passwordsForOrigin origin: String) -> [[String: String]] { [] }

    func browserPage(_ page: WMBrowserPage, saveUsername username: String, password: String,
                     origin: String) -> String? { nil }

    /// The browser keeps its profile in memory: a saved profile needs the
    /// Keychain, which the app does not open on its own.
    private func prepareBrowser() throws {
        if UserDefaults.standard.bool(forKey: Self.clearDataKey) {
            UserDefaults.standard.removeObject(forKey: Self.clearDataKey)
        }
        try WMBrowserRuntime.shared().start(withProfilePath: nil)
    }

    static func shutdown() async -> Bool {
        await withCheckedContinuation { continuation in
            WMBrowserRuntime.shared().shutdown { continuation.resume(returning: $0) }
        }
    }

    static func prepareForRestart() async -> Bool {
        await withCheckedContinuation { continuation in
            WMBrowserRuntime.shared().prepareForTermination { continuation.resume(returning: $0) }
        }
    }

    static func cancelPreparedRestart() {
        WMBrowserRuntime.shared().cancelPreparedTermination()
    }
}
