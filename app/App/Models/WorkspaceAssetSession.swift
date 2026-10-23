#if COMPANION_FACADE_TESTS
import CompanionBrowserTestBridge
#endif
import AppKit
import Observation
import WovenMatterCore
import WovenMatterClient

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
    var automationTabs: [GatewayJSONValue] {
        tabs.browserIDs.compactMap { id in
            pages[id].map { .object(["tabId": .string(id.uuidString.lowercased()), "url": .string($0.url),
                                    "title": .string($0.title), "loading": .bool($0.loading)]) }
        }
    }
    private static var preparedProfile = false
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
            return .init(id: id, title: title(note), revision: note.updatedAt ?? note.createdAt ?? "",
                         active: tabs.selected == .note(id))
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

    func browserPage(_ page: WMBrowserPage, passwordsForOrigin origin: String) -> [[String: String]] {
        (try? BrowserCredentialStore.shared.savedPasswords(for: origin))?.map {
            ["username": $0.username, "password": $0.password]
        } ?? []
    }

    func browserPage(_ page: WMBrowserPage, saveUsername username: String, password: String,
                     origin: String) -> String? {
        do {
            try BrowserCredentialStore.shared.save(origin: origin, username: username, password: password)
            return nil
        } catch { return error.localizedDescription }
    }

    private func prepareBrowser() throws {
        guard KeychainAccess.enforceCentralAuthorization() == 0 else {
            throw BrowserCredentialStore.AccessError.unavailable(-25308)
        }
        try BrowserCredentialStore.shared.prepare(consented:
            UserDefaults.standard.bool(forKey: BrowserCredentialStore.consentKey))
        let directory = (DevelopmentLaunch.isLiveHost ? nil : DevelopmentLaunch.supportDirectory)?.appending(path: "Browser", directoryHint: .isDirectory)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Woven Matter/Browser", directoryHint: .isDirectory)
            .appending(path: Bundle.main.bundleIdentifier ?? "wovenmatter.desktop", directoryHint: .isDirectory)
        if !Self.preparedProfile {
            if UserDefaults.standard.bool(forKey: Self.clearDataKey) {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                UserDefaults.standard.removeObject(forKey: Self.clearDataKey)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            Self.preparedProfile = true
        }
        try WMBrowserRuntime.shared().start(withProfilePath: directory.path)
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
