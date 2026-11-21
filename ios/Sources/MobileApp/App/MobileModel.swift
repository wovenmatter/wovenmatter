import Observation
import SwiftUI
import WovenProtocol

/// The iPhone and iPad app's root: the shared client layer (`app`), the
/// device's own core it talks to, and which tab and page are showing. The
/// stores do the work; this only routes between the tabs.
@MainActor
@Observable
final class MobileModel {
    enum Tab: String, CaseIterable, Identifiable {
        case chat, bots, folders, artifacts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chat: "Chat"
            case .bots: "Bots"
            case .folders: "Folders"
            case .artifacts: "Artifacts"
            }
        }

        var glyph: LucideGlyph {
            switch self {
            case .chat: .messageSquare
            case .bots: .bot
            case .folders: .folder
            case .artifacts: .fileText
            }
        }
    }

    /// The shared stores and connections, as the Mac UI has them.
    let app = ApplicationModel()
    /// The in-app core: the UI's own server on this device.
    let device = DeviceCore()
    /// The Chat tab's open chat and drafts.
    let chat: ChatModel

    var tab: Tab = .chat
    /// Each tab's own navigation stack; reselecting a tab empties its stack.
    var paths: [Tab: NavigationPath] = Dictionary(uniqueKeysWithValues: Tab.allCases.map { ($0, NavigationPath()) })
    /// Settings, over whatever tab is showing.
    var settingsPresented = false
    /// The Settings page to open on, for a link elsewhere in the app (a
    /// composer setup notice, say). The Settings root reads and clears it.
    var settingsDestination: SettingsDestination?
    /// The artifact the Artifacts tab shows; nil until one is opened.
    var artifactID: String?

    init() {
        chat = ChatModel(app: app)
    }

    /// This device's identifier: the machine the local connection's core
    /// answers as. Quick Chat sessions belong to it.
    var deviceID: String? { app.server?.remote?.machine.id }

    /// Starts the device's core and connects the stores to it.
    func start() async {
        do {
            app.connect(try await device.start())
        } catch {
            return app.fail(error.localizedDescription)
        }
        // Each finished dictation is saved to the library, as on a Mac.
        app.settings.configureDictationHistory()
        #if DEBUG
        // Development: connect to the Mac a connection code names at launch.
        if let text = ProcessInfo.processInfo.environment["WOVENMATTER_CONNECT_CODE"], let code = ConnectionCode(text) {
            try? await device.add(code)
        }
        #endif
    }

    /// The page showing has a composer on the bottom bar, which brings its own fade:
    /// a chat, any page opened in the Bots tab, or an open artifact (its gutter).
    var showsComposerOnBar: Bool {
        tab == .chat || tab == .bots && paths[.bots]?.isEmpty == false || tab == .artifacts && artifactID != nil
    }

    /// Chooses a tab; choosing the one showing returns it to its root.
    func select(_ tab: Tab) {
        if self.tab == tab { paths[tab] = NavigationPath() }
        self.tab = tab
    }

    /// Shows a chat in the Chat tab.
    func open(sessionID: String) {
        chat.open(sessionID)
        paths[.chat] = NavigationPath()
        tab = .chat
    }

    /// Shows a new chat with `target` in the Chat tab; its session starts with the first message.
    func newChat(_ target: ChatTarget) {
        chat.newChat(target)
        paths[.chat] = NavigationPath()
        tab = .chat
    }

    /// Shows an artifact in the Artifacts tab.
    func open(artifactID: String) {
        self.artifactID = artifactID
        paths[.artifacts] = NavigationPath()
        tab = .artifacts
    }

    /// Opens Settings, on `destination` when one is given.
    func openSettings(_ destination: SettingsDestination? = nil) {
        settingsDestination = destination
        settingsPresented = true
    }
}

/// A Settings page another part of the app links to.
enum SettingsDestination: Hashable {
    /// Where Quick Chat's model providers are signed in on this device.
    case modelProviders
    /// Where a web search key is added for Quick Chat.
    case webSearch
    /// Connecting to the Mac a scanned or opened link names.
    case connect(ConnectionCode)
    /// The connect screen, with no code yet.
    case connectMachine
}
