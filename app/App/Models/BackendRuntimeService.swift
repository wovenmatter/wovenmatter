import Foundation
import WovenMatterClient
import WovenMatterCore

/// Only public display state crosses this boundary, never launch environments or credentials.
enum BackendRuntimeCommand: Codable, Sendable {
    case refreshInventory
    case checkUpdate(AgentRuntimeKind)
    case install(AgentRuntimeKind)
    case update(AgentRuntimeKind)
    case confirmInstall
    case cancelInstall
    case refreshRuntimes(Set<AgentRuntimeKind>)
    case refreshSignIn
    case setShown(AgentRuntimeKind, Bool)
    case setCredentialAccess(AgentRuntimeKind, Bool)
    case setUpWorkspace(URL)
    case repositories(URL?)
    case databases(URL?)
    case confirmFolderChange(Bool)
    case cancelFolderChange
    case titleEnabled(Bool)
    case titleModel(String)
    case titleThinking(String)
    case refreshTitleCapabilities
}

struct BackendRuntimeSnapshot: Codable, Sendable {
    var availability: [LocalACPRuntimeAvailability]
    var readyKinds: Set<AgentRuntimeKind>
    var launchableKinds: Set<AgentRuntimeKind>
    var reconciliationError: String?
    var checkingKinds: Set<AgentRuntimeKind>
    var enabledKinds: Set<AgentRuntimeKind>
    var shownKinds: Set<AgentRuntimeKind>
    var inventories: [AgentRuntimeKind: RuntimeInventory]
    var failures: [AgentRuntimeKind: Int]
    var failureDetails: [AgentRuntimeKind: String]
    var checkingInventory: Bool
    var checkingUpdates: Set<AgentRuntimeKind>
    var checkedUpdates: Set<AgentRuntimeKind>
    var updatingKinds: Set<AgentRuntimeKind>
    var failedUpdates: Set<AgentRuntimeKind>
    var installingKinds: Set<AgentRuntimeKind>
    var installPreview: LocalACPInstallerPreview?
    var workspace: LocalACPWorkspaceAvailability
    var pendingFolder: LocalACPWorkspaceFolder?
    var pendingDestination: URL?
    var folderError: String?
    var folderInProgress: Bool
    var folderRecovery: LocalACPWorkspaceFolderChangeResult?
    var runError: String?
    var signInStatuses: [AgentSignInStatus]
    var checkingSignIn: Bool
    var signInError: String?
    var titleEnabled: Bool
    var titleModel: String
    var titleThinking: String
    var titleCapabilities: CodexTitleGenerationCapabilities?
    var titleStatus: String
    var checkingTitle: Bool
}
