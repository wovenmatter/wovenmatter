#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import WovenMatterCore

/// Identity of deployment inputs, independent of archive timestamps.
struct RemoteWorkspaceDeployment {
    static let botInputs: Set<String> = ["bots/package.json", "bots/package-lock.json", "bots/src", "bots/helper", "bots/image"]
    let fingerprint: String
    let script: String
    let sourceFiles: [String]

    init(root: URL) throws {
        let manager = FileManager.default
        let inputs = ["remote/package.json", "remote/src", "remote/host", "remote/npm-runtime/package.json", "remote/npm-runtime/package-lock.json", "harnesses", "default-agent/package.json",
                      "default-agent/package-lock.json", "default-agent/src", "default-agent/.node-version", "scripts/remote-host.sh"]
        // The bots runtime ships with host releases whenever this checkout or
        // app bundle contains it; hosts require it only for the bots role.
        var files: [String] = []
        for input in inputs + Self.botInputs.sorted() {
            let url = root.appending(path: input)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory) else {
                if Self.botInputs.contains(input) { continue }
                throw RemoteWorkspaceClientError.deploymentBundleUnavailable
            }
            if directory.boolValue {
                guard let entries = manager.enumerator(atPath: url.path) else {
                    throw RemoteWorkspaceClientError.deploymentBundleUnavailable
                }
                for case let relativePath as String in entries {
                    let file = url.appending(path: relativePath)
                    if file.lastPathComponent == ".DS_Store" { continue }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { entries.skipDescendants() }
                    if values.isRegularFile == true || values.isSymbolicLink == true {
                        files.append(input + "/" + relativePath)
                    }
                }
            } else { files.append(input) }
        }
        sourceFiles = files.sorted()
        var hash = SHA256()
        for path in files.sorted() {
            let url = root.appending(path: path)
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let isLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
            let bytes = try isLink ? Data(manager.destinationOfSymbolicLink(atPath: url.path).utf8) : Data(contentsOf: url)
            let executable = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            hash.update(data: Data("\(path)\0\(isLink)\0\(executable & 0o111)\0".utf8))
            hash.update(data: Data(SHA256.hash(data: bytes)))
        }
        fingerprint = hash.finalize().hexString
        script = try String(contentsOf: root.appending(path: "scripts/remote-host.sh"), encoding: .utf8)
    }
}

/// Only known build phases reach UI; raw shell output remains diagnostic data.
final class RemoteWorkspaceBuildProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var previous: String?
    private let report: @Sendable (String) -> Void
    init(report: @escaping @Sendable (String) -> Void) {
        self.report = report
    }

    func receive(_ data: Data) {
        lock.withLock {
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                if let message = Self.message(line), message != previous {
                    previous = message; report(message)
                }
            }
            if pending.count > 8192 { pending = Data(pending.suffix(8192)) }
        }
    }

    static func message(_ line: String) -> String? {
        switch line {
        case "WM_PROGRESS waiting": return "Waiting for the host’s installer…"
        case "WM_PROGRESS verifying": return "Verifying the host service bundle…"
        case "WM_PROGRESS uploading": return "Uploading the host service…"
        case "WM_PROGRESS node": return "Installing the verified Node runtime…"
        case "WM_PROGRESS dependencies": return "Installing agent dependencies…"
        case "WM_PROGRESS browser": return "Installing Chromium…"
        case "WM_PROGRESS activating": return "Starting the host service…"
        case "WM_PROGRESS library": return "Updating the library…"
        case "WM_PROGRESS bots": return "Setting up bots…"
        case "WM_PROGRESS bots-engine": return "Installing the bots engine…"
        case "WM_PROGRESS preparing": return "Preparing the host…"
        case "WM_PROGRESS selftest": return "Verifying the Chromium sandbox…"
        case "WM_PROGRESS rollback": return "Restoring the previous host service…"
        case "WM_PROGRESS ready": return "Host service ready."
        default: return nil
        }
    }
}
