import CryptoKit
import Foundation

/// Identity of deployment inputs, independent of archive timestamps.
struct RemoteWorkspaceDeployment {
    let fingerprint: String
    let script: String
    let sourceFiles: [String]

    init(root: URL, kind: RemoteWorkspaceKind = .container) throws {
        let manager = FileManager.default
        let inputs = kind == .host
            ? ["remote/package.json", "remote/src", "remote/host", "remote/npm-runtime/package.json", "remote/npm-runtime/package-lock.json", "harnesses", "default-agent/package.json",
               "default-agent/package-lock.json", "default-agent/src", "default-agent/.node-version", "scripts/remote-host.sh"]
            : ["remote/Dockerfile", "remote/build-image.sh", "remote/entrypoint.sh", "remote/package.json",
                      "remote/src", "remote/security", "remote/npm-runtime/package.json", "remote/npm-runtime/package-lock.json", "harnesses", "default-agent/package.json", "default-agent/package-lock.json", "default-agent/src"]
        var files: [String] = []
        for input in inputs {
            let url = root.appending(path: input)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory) else {
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
        fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        script = try String(contentsOf: root.appending(path: kind == .host ? "scripts/remote-host.sh" : "remote/build-image.sh"), encoding: .utf8)
    }

    static func imageID(_ output: Data) -> String? {
        let value = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.wholeMatch(of: /^sha256:[a-f0-9]{64}$/) == nil ? nil : value
    }
}

/// Only known build phases reach UI; raw shell output remains diagnostic data.
final class RemoteWorkspaceBuildProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var previous: String?
    private let report: @Sendable (String) -> Void
    private let kind: RemoteWorkspaceKind
    init(kind: RemoteWorkspaceKind = .container, report: @escaping @Sendable (String) -> Void) {
        self.kind = kind; self.report = report
    }

    func receive(_ data: Data) {
        lock.withLock {
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                if let message = Self.message(line, kind: kind), message != previous {
                    previous = message; report(message)
                }
            }
            if pending.count > 8192 { pending = Data(pending.suffix(8192)) }
        }
    }

    static func message(_ line: String, kind: RemoteWorkspaceKind = .container) -> String? {
        if kind == .host {
            switch line {
            case "WM_PROGRESS waiting": return "Waiting for the host’s installer…"
            case "WM_PROGRESS verifying": return "Verifying the host service bundle…"
            case "WM_PROGRESS uploading": return "Uploading the host service…"
            case "WM_PROGRESS node": return "Installing the verified Node runtime…"
            case "WM_PROGRESS dependencies": return "Installing agent dependencies…"
            case "WM_PROGRESS browser": return "Installing Chromium…"
            case "WM_PROGRESS activating": return "Starting the host service…"
            case "WM_PROGRESS selftest": return "Verifying the Chromium sandbox…"
            case "WM_PROGRESS rollback": return "Restoring the previous host service…"
            case "WM_PROGRESS ready": return "Host service ready."
            default: return nil
            }
        }
        if line == "WM_PROGRESS waiting" { return "Waiting for the host’s image builder…" }
        if line == "WM_PROGRESS reused" { return "Reusing the up-to-date workspace image…" }
        if line == "WM_PROGRESS building" { return "Building the workspace image…" }
        if line == "WM_PROGRESS ready" { return "Workspace image ready." }
        // BuildKit headers identify actual phases. Installer text cannot supply UI instructions.
        guard line.hasPrefix("#") else { return nil }
        if line.contains("load metadata for") { return "Checking the latest base image…" }
        if line.contains("load build context") || line.contains("transferring context:") { return "Uploading workspace files…" }
        if line.contains("exporting") || line.contains("naming to") { return "Saving the workspace image…" }
        guard line.contains("] ") else { return nil }
        if line.contains("playwright install") { return "Installing Playwright, Chromium, and agent dependencies…" }
        if line.contains("apt-get") { return "Installing Linux packages and browser dependencies…" }
        if line.contains("COPY ") { return "Adding workspace services…" }
        if line.contains("FROM ") { return "Downloading the base image…" }
        return nil
    }
}
