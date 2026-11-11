/// Names that released Woven Matter desktop apps and Linux hosts already wrote to
/// disk, the Keychain or user defaults, from when paired devices were called
/// "companions". Existing installs and mixed versions depend on them, so they
/// never change. Code refers to them only through these constants.
///
/// Kept elsewhere because they cannot be constants: SQLite tables and triggers
/// named `companion_*` (created by `LibraryWorkspaceSchema`, `FederationSchema`
/// and the tool, MCP and calendar stores, written into SQL text, and part of the
/// peer-synced table set in `PairedLibraryStore`), the `companion` key of
/// `BackendApplicationCommand.libraryHost` and `BackendApplicationResult.libraryHost`,
/// and `TailscaleServeSupervisor.argument`, which installed helpers are launched with.
public enum LegacyStorageNames {
  /// Paired-device grants, in the Mac's support directory and a Linux host's library directory.
  public static let pairedDevicesFile = "companion-devices.json"

  /// Keychain service of a client's central-library pairing, on the Mac and the iPhone.
  public static let centralPairingKeychainService = "com.wovenmatter.companion.dev.pairing"

  /// Note version sources recorded for edits that arrive from another device.
  public static let deviceNoteEditSource = "companion"
  public static let beforeDeviceNoteDeleteSource = "before-companion-delete"
  public static let beforeDeviceNoteEditSource = "before-companion-edit"

  /// Desktop user-defaults keys.
  public static let pendingExecutionRevocationsKey = "companion.execution.pending-revocations"
  public static let pendingInstallerRotationsKey = "companion.execution.pending-installer-rotations"
  public static let appliedPeerRevocationsKey = "companion.peers.applied-revocations"
  /// Followed by the library workspace ID.
  public static let httpsPortKeyPrefix = "companion.https.port."
  /// Followed by the library ID.
  public static let localExecutionIDKeyPrefix = "companion.execution.local-id."
}
