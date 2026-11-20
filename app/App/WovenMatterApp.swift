import AppKit
import Foundation
import SwiftUI

/// This app's own data folder: Application Support, named by the bundle
/// identifier. A dev build has its own identifier per instance, so it never
/// shares a folder with the installed app.
enum AppDataFolder {
    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: Bundle.main.bundleIdentifier ?? "wovenmatter.desktop", directoryHint: .isDirectory)
    }

    /// The dev instance name `scripts/build_and_run.sh --instance` writes into
    /// Info.plist; nil in a release build.
    static var developmentInstance: String? {
        Bundle.main.object(forInfoDictionaryKey: "WovenMatterDevelopmentInstance") as? String
    }
}

/// Actions belong to the active workspace window. Settings and setup windows
/// publish no workspace actions.
struct WorkspaceMenuActions {
    var newChat: @MainActor () -> Void
    var newNote: @MainActor () -> Void
    var newBrowserTab: @MainActor () -> Void
    var refresh: @MainActor () -> Void
}

private struct WorkspaceMenuActionsKey: FocusedValueKey {
    typealias Value = WorkspaceMenuActions
}

extension FocusedValues {
    var workspaceMenuActions: WorkspaceMenuActions? {
        get { self[WorkspaceMenuActionsKey.self] }
        set { self[WorkspaceMenuActionsKey.self] = newValue }
    }
}

@main
enum WovenMatterEntryPoint {
    @MainActor static func main() {
        // Run with --server, the program is this Mac's background server and nothing of the UI.
        if let index = CommandLine.arguments.firstIndex(of: ServerEntry.argument) {
            ServerEntry.run(Array(CommandLine.arguments[(index + 1)...]))
        }
        // SwiftUI's delegate adaptor can initialize NSApplication before App.init.
        // Install CEF's required AppKit subclass first, without loading Chromium.
        WMBrowserRuntime.prepareApplication()
        WovenMatterApp.main()
    }
}

struct WorkspaceMenuCommands: Commands {
    @FocusedValue(\.workspaceMenuActions) private var actions
    @AppStorage(WovenTheme.storageKey) private var themeRawValue = WovenTheme.green.rawValue
    @AppStorage(SidebarStyle.storageKey) private var sidebarStyleRawValue = SidebarStyle.defaultStyle.rawValue

    private var dictationTitle: String {
        if DictationModel.shared.isRecording { return "Stop Dictation" }
        return DictationModel.shared.retainedTranscript == nil ? "Start Dictation" : "Insert Dictation"
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandMenu("File") {
            Button("New Chat") { actions?.newChat() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
            Button("New Artifact") { actions?.newNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("New Browser Tab") { actions?.newBrowserTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button(dictationTitle) { DictationModel.shared.toggleActiveEditor() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(DictationModel.shared.shortcutEditor?.ticket() == nil
                    || DictationModel.shared.phase == .finishing)
            Divider()
            Button("Refresh Workspace") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandMenu("Appearance") {
            Picker("Theme", selection: $themeRawValue) {
                ForEach(WovenTheme.allCases) { theme in
                    Text(theme.title).tag(theme.rawValue)
                }
            }
            Divider()
            Picker("Sidebar Layout", selection: $sidebarStyleRawValue) {
                ForEach(SidebarStyle.allCases) { style in
                    Text(style.title).tag(style.rawValue)
                }
            }
        }
    }
}

struct WovenMatterApp: App {
    @NSApplicationDelegateAdaptor(WovenMatterLifecycleDelegate.self) private var lifecycleDelegate
    @State private var applicationModel = ApplicationModel()

    init() {
        HarnessSetupPresentation.shared.prepareForLaunch()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: applicationModel)
                .onAppear {
                    applicationModel.settings.configureDictationHistory()
                    DesktopUpdater.shared.start()
                    lifecycleDelegate.prepareBrowserTermination = { await WorkspaceAssetSession.shutdown() }
                    #if DEBUG
                    WindowCapture.startIfRequested()
                    #endif
                }
                .frame(minWidth: WovenMetrics.windowMinimumWidth, minHeight: 640)
                .task { await applicationModel.connect() }
                .scrollIndicators(.never)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUpdateNotification)) { _ in
                    // AppKit focus is not observable. Publish changes after its
                    // event cycle so the dictation command's enabled state follows it.
                    DictationModel.shared.refreshShortcutEditor()
                }

        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands { WorkspaceMenuCommands() }

        Window("Set up Woven Matter", id: HarnessSetupPresentation.windowID) {
            if applicationModel.state == .ready {
                HarnessSetupView(model: applicationModel)
            } else {
                ProgressView("Opening workspace…").frame(width: 740, height: 640)
            }
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            Group {
                SettingsView(model: applicationModel)
            }.scrollIndicators(.never)
        }
    }
}
