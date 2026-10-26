import CryptoKit
import Foundation

/// Source-only host bundle. The app uses Foundation and the macOS gzip binary,
/// so deployment does not require Python, npm, Xcode, or a local Linux runtime.
enum RemoteHostBundle {
    private struct Versions: Decodable { let nodeVersion: String; let playwrightVersion: String }
    private struct Record: Encodable {
        let sha256: String
        let mode: Int
        let sourcePath: String
        let sourceMode: Int
    }
    private struct Manifest: Encodable {
        let fingerprint: String
        let nodeVersion: String
        let playwrightVersion: String
        let dependencyInstallation = "target-npm-ci"
        let files: [String: Record]
    }

    static func archive(root: URL, deployment: RemoteWorkspaceDeployment) throws -> Data {
        let versions = try JSONDecoder().decode(Versions.self,
            from: Data(contentsOf: root.appending(path: "remote/host/runtime-versions.json")))
        let recordedNode = try String(contentsOf: root.appending(path: "default-agent/.node-version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "default-agent/package-lock.json"))) as? [String: Any]
        let packages = lock?["packages"] as? [String: Any]
        let playwright = packages?["node_modules/playwright-core"] as? [String: Any]
        guard versions.nodeVersion == recordedNode,
              versions.playwrightVersion == playwright?["version"] as? String else {
            throw RemoteWorkspaceClientError.invalidResponse("The host runtime selections differ from the committed dependency graph.")
        }
        var records: [String: Record] = [:]
        var files: [String: (Data, Int)] = [:]
        var hash = SHA256()
        for source in deployment.sourceFiles {
            let url = root.appending(path: source)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw RemoteWorkspaceClientError.invalidResponse("Host bundle sources must be regular files.")
            }
            let bytes = try Data(contentsOf: url)
            let sourceMode = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111
            let mode = sourceMode == 0 ? 0o600 : 0o700
            let target = try targetPath(source)
            guard records[target] == nil else { throw RemoteWorkspaceClientError.deploymentBundleUnavailable }
            records[target] = Record(sha256: digest(bytes), mode: mode, sourcePath: source, sourceMode: sourceMode)
            files[target] = (bytes, mode)
            hash.update(data: Data("\(source)\0false\0\(sourceMode)\0".utf8))
            hash.update(data: Data(SHA256.hash(data: bytes)))
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == deployment.fingerprint else {
            throw RemoteWorkspaceClientError.invalidResponse("The host sources changed while preparing deployment. Retry the update.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var manifest = try encoder.encode(Manifest(fingerprint: deployment.fingerprint,
            nodeVersion: versions.nodeVersion, playwrightVersion: versions.playwrightVersion, files: records))
        manifest.append(10)
        files["manifest.json"] = (manifest, 0o600)
        var tar = Data()
        for name in files.keys.sorted() {
            let (data, mode) = files[name]!
            try append(name: name, bytes: data, mode: mode, to: &tar)
        }
        tar.append(Data(repeating: 0, count: 1024))
        let result = try RemoteWorkspaceProcess.run(executable: "/usr/bin/gzip", arguments: ["-n", "-c"], input: tar)
        guard result.status == 0 else { throw RemoteWorkspaceClientError.commandFailed(result.output) }
        return result.data
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func targetPath(_ source: String) throws -> String {
        if source == "remote/package.json" { return "package.json" }
        if source == "remote/host/bin/wm-exec" { return "bin/wm-exec" }
        if source == "scripts/remote-host.sh" { return "host/remote-host.sh" }
        if source.hasPrefix("remote/src/") { return String(source.dropFirst("remote/".count)) }
        if source.hasPrefix("remote/host/") { return String(source.dropFirst("remote/".count)) }
        if source == "remote/npm-runtime/package.json" || source == "remote/npm-runtime/package-lock.json" {
            return String(source.dropFirst("remote/".count))
        }
        if source.hasPrefix("default-agent/") || source.hasPrefix("harnesses/") { return source }
        throw RemoteWorkspaceClientError.deploymentBundleUnavailable
    }

    /// Minimal USTAR encoder: zero metadata, regular files only, sorted callers.
    /// It deliberately emits no links, devices, ownership, or extraction paths.
    private static func append(name: String, bytes: Data, mode: Int, to tar: inout Data) throws {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ value: String, at offset: Int, length: Int) throws {
            let data = Array(value.utf8)
            guard data.count <= length else { throw RemoteWorkspaceClientError.deploymentBundleUnavailable }
            header.replaceSubrange(offset..<(offset + data.count), with: data)
        }
        func octal(_ value: Int, at offset: Int, length: Int) throws {
            let number = String(value, radix: 8)
            guard number.count < length else { throw RemoteWorkspaceClientError.deploymentBundleUnavailable }
            try put(String(repeating: "0", count: length - number.count - 1) + number + "\0", at: offset, length: length)
        }
        if name.utf8.count <= 100 { try put(name, at: 0, length: 100) }
        else {
            let parts = name.split(separator: "/")
            var split: Int?
            for index in 1..<parts.count {
                if parts.prefix(index).joined(separator: "/").utf8.count <= 155,
                   parts.dropFirst(index).joined(separator: "/").utf8.count <= 100 { split = index }
            }
            guard let split else { throw RemoteWorkspaceClientError.deploymentBundleUnavailable }
            try put(parts.dropFirst(split).joined(separator: "/"), at: 0, length: 100)
            try put(parts.prefix(split).joined(separator: "/"), at: 345, length: 155)
        }
        try octal(mode, at: 100, length: 8)
        try octal(0, at: 108, length: 8)
        try octal(0, at: 116, length: 8)
        try octal(bytes.count, at: 124, length: 12)
        try octal(0, at: 136, length: 12)
        header.replaceSubrange(148..<156, with: [UInt8](repeating: 32, count: 8))
        header[156] = 48
        try put("ustar\0", at: 257, length: 6)
        try put("00", at: 263, length: 2)
        let sum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
        try put(String(repeating: "0", count: 6 - sum.count) + sum + "\0 ", at: 148, length: 8)
        tar.append(contentsOf: header)
        tar.append(bytes)
        let padding = (512 - bytes.count % 512) % 512
        tar.append(Data(repeating: 0, count: padding))
    }
}
