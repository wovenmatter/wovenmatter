import CryptoKit
import Darwin
import Foundation

/// Display metadata only. Reading enabled names never starts an SDK, checks accounts,
/// or contacts providers. Missing names remain the caller's scoped-cache/ID fallback.
public enum DefaultAgentEnabledModelMetadata {
    public static func names(for ids: [String], resources: URL?, local: Bool) async -> [String: String] {
        let requested = Array(Set(ids.prefix(4096).filter { !$0.isEmpty && $0.utf8.count <= 1024 }))
        guard !requested.isEmpty else { return [:] }
        let task = Task.detached(priority: .utility) { () -> [String: String] in
            guard !Task.isCancelled, let bundled = resources ?? DefaultAgentSupport.resources else { return [:] }
            let directory = stateDirectory()
            let cacheKey = metadataKey(ids: requested, bundled: bundled, directory: directory, local: local)
            if let saved = cacheLock.withLock({ snapshots[cacheKey] }) { return saved }
            let root = local ? effectiveRuntime(bundled: bundled, directory: directory) : bundled
            var names: [String: String] = [:]
            let groups = Dictionary(grouping: requested.compactMap { reference -> Reference? in
                guard let slash = reference.firstIndex(of: "/") else { return nil }
                return Reference(id: reference, provider: String(reference[..<slash]), model: String(reference[reference.index(after: slash)...]))
            }, by: \.provider)
            for (provider, references) in groups {
                guard !Task.isCancelled else { return names }
                if ["claude-subscription", "anthropic"].contains(provider) {
                    guard local else { continue }
                    let models = claudeModels(root: root, directory: directory) ?? []
                    let byID = Dictionary(models.map { ($0.value, $0) }, uniquingKeysWith: { _, latest in latest })
                    for reference in references {
                        if let model = byID[reference.model], let name = claudeName(model) {
                            names[reference.id] = name
                        } else if let name = claudeAliasName(reference.model) {
                            // Replace an older persisted version when its SDK
                            // metadata no longer matches the active runtime.
                            names[reference.id] = name
                        }
                    }
                    continue
                }
                let source = provider == "xai-api" ? "xai" : provider
                guard ["openai-codex", "openai", "openrouter", "opencode-go", "xai"].contains(source),
                      let data = read(root.appending(path: "node_modules/@earendil-works/pi-ai/dist/providers/data/\(source).json"), limit: 2_097_152),
                      let catalog = try? JSONDecoder().decode([String: [String: NamedModel]].self, from: data) else { continue }
                for reference in references {
                    // API groups can repeat an ID. Preserve its name only when the
                    // supplied metadata agrees, without inventing API precedence.
                    let candidates = Set(catalog.values.compactMap { models -> String? in
                        // Pi 1.0 keys models by type. App selectors contain chat
                        // IDs only; image/classifier entries cannot supply names.
                        let model = models["chat:\(reference.model)"] ?? models[reference.model]
                        guard model?.type == nil || model?.type == "chat" else { return nil }
                        return cleanName(model?.name)
                    })
                    if candidates.count == 1 { names[reference.id] = candidates.first }
                }
            }
            if !Task.isCancelled {
                cacheLock.withLock {
                    if snapshots.count >= 16 { snapshots.removeAll(keepingCapacity: true) }
                    snapshots[cacheKey] = names
                }
            }
            return names
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct MetadataKey: Hashable {
        let ids: [String]
        let root: String
        let local: Bool
        let identities: [String]
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var snapshots: [MetadataKey: [String: String]] = [:]

    /// Filesystem identities invalidate the small in-memory projection when an
    /// app/SDK update or explicit Claude discovery changes its source metadata.
    private static func metadataKey(ids: [String], bundled: URL, directory: URL, local: Bool) -> MetadataKey {
        var sources = [bundled.appending(path: "package-lock.json")]
        if local {
            sources.append(directory.appending(path: "sdk-runtime/active.json"))
            if ids.contains(where: { $0.hasPrefix("claude-subscription/") || $0.hasPrefix("anthropic/") }) {
                sources.append(directory.appending(path: "claude-models.json"))
            }
        }
        return MetadataKey(ids: ids.sorted(), root: bundled.path, local: local, identities: sources.map { url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return url.path + ":missing" }
            return "\(url.path):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        })
    }

    private struct Reference { let id: String; let provider: String; let model: String }
    private struct NamedModel: Decodable { let name: String?; let type: String? }
    private struct RuntimeMarker: Decodable { let base: String; let generation: String }
    private struct Package: Decodable { let version: String }
    private struct ClaudeCatalog: Decodable { let runtimeVersion: String?; let models: [ClaudeModel] }
    private struct ClaudeModel: Decodable {
        let value: String
        let displayName: String
        let resolvedModel: String?
        let description: String?
    }

    private static func stateDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["WOVEN_DEFAULT_AGENT_DIRECTORY"],
           path.hasPrefix("/"), !path.contains("\0") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".wovenmatter/default-agent", directoryHint: .isDirectory)
    }

    private static func effectiveRuntime(bundled: URL, directory: URL) -> URL {
        let runtime = directory.appending(path: "sdk-runtime", directoryHint: .isDirectory)
        // Most installations have no override. Do not walk the bundle's source
        // tree unless an active generation actually needs validation.
        guard let data = read(runtime.appending(path: "active.json"), limit: 16_384),
              let active = try? JSONDecoder().decode(RuntimeMarker.self, from: data),
              active.generation.count == 36,
              active.generation.allSatisfy({ "abcdef0123456789-".contains($0) }),
              let base = fingerprint(bundled), active.base == base else { return bundled }
        let root = runtime.appending(path: "generations/\(active.generation)", directoryHint: .isDirectory)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              let manifestData = read(root.appending(path: "woven-sdk-generation.json"), limit: 16_384),
              let manifest = try? JSONDecoder().decode(RuntimeMarker.self, from: manifestData),
              manifest.base == base, manifest.generation == active.generation,
              FileManager.default.isReadableFile(atPath: root.appending(path: "src/main-runtime.mjs").path) else { return bundled }
        return root
    }

    /// Same byte order as default-agent/src/sdk-management.mjs. The source hash
    /// prevents an older app's override from supplying names for a newer bundle.
    private static func fingerprint(_ root: URL) -> String? {
        #if arch(arm64)
        let platform = "darwin/arm64"
        #elseif arch(x86_64)
        let platform = "darwin/x64"
        #else
        return nil
        #endif
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "src").path) else { return nil }
        let sources = entries.filter { $0.hasSuffix(".mjs") }.sorted()
        guard sources.count <= 256 else { return nil }
        var hash = SHA256()
        hash.update(data: Data(platform.utf8))
        var remaining = 8_388_608
        for name in ["package.json", "package-lock.json"] + sources.map({ "src/" + $0 }) {
            guard !Task.isCancelled, let data = read(root.appending(path: name), limit: min(remaining, 2_097_152)) else { return nil }
            remaining -= data.count
            hash.update(data: Data(name.utf8)); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func claudeModels(root: URL, directory: URL) -> [ClaudeModel]? {
        guard let packageData = read(root.appending(path: "node_modules/@anthropic-ai/claude-agent-sdk/package.json"), limit: 65_536),
              let package = try? JSONDecoder().decode(Package.self, from: packageData),
              let data = read(directory.appending(path: "claude-models.json"), limit: 262_144),
              let catalog = try? JSONDecoder().decode(ClaudeCatalog.self, from: data),
              catalog.runtimeVersion == package.version, catalog.models.count <= 256 else { return nil }
        return catalog.models
    }

    private static func claudeAliasName(_ value: String) -> String? {
        let alias = value.hasSuffix("[1m]") ? String(value.dropLast(4)) : value
        return ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku", "default": "Default"][alias]
    }

    /// Mirrors claudeModelName: canonical resolved versions win over display prose;
    /// a dated release suffix is not a model version component.
    private static func claudeName(_ model: ClaudeModel) -> String? {
        var base = model.value
        if base.hasSuffix("[1m]") { base.removeLast(4) }
        if base.hasPrefix("claude-") { base.removeFirst(7) }
        guard base != "default", let family = capture("^([a-z]+)", in: base) else { return cleanName(model.displayName) }
        let title = family.prefix(1).uppercased() + family.dropFirst().lowercased()
        let escaped = NSRegularExpression.escapedPattern(for: family)
        if let version = capture("^claude-\(escaped)-(\\d+(?:[-.]\\d{1,2})?)(?:-\\d{8})?(?:\\[1m\\])?$", in: model.resolvedModel ?? model.value) {
            return "\(title) \(version.replacingOccurrences(of: "-", with: "."))"
        }
        for value in [model.displayName, model.description].compactMap({ $0 }) {
            if let version = capture("\\b\(escaped)\\s+(\\d+(?:\\.\\d+)*)\\b", in: value) { return "\(title) \(version)" }
        }
        return cleanName(model.displayName)
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard value.utf8.count <= 4096,
              let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func cleanName(_ name: String?) -> String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.utf8.count <= 512 else { return nil }
        return value
    }

    private static func read(_ url: URL, limit: Int) -> Data? {
        guard !Task.isCancelled, limit > 0, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
}
