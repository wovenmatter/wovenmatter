import Foundation

/// The shared browser a machine's agents use. These go straight to the owning
/// machine's server, which holds the browser; this Mac's server does not relay them.
extension DocumentsStore {
    func remoteBrowserTabs(machineID: String, profile: String) async throws -> RemoteBrowserTabs {
        throw ClientError.notConnected
    }

    /// The selected tab's newest image. An empty image means it has not changed since `previousFrameID`.
    func remoteBrowserFrame(machineID: String, tabID: String, previousFrameID: String?,
                            profile: String) async throws -> RemoteBrowserFrame {
        throw ClientError.notConnected
    }

    /// Clicks, keys, scrolling and navigation, in order, each bound to the image it was made on.
    func sendRemoteBrowserActions(_ actions: [RemoteBrowserAction], machineID: String,
                                  profile: String) async throws -> RemoteBrowserActionBatchResult {
        throw ClientError.notConnected
    }
}
