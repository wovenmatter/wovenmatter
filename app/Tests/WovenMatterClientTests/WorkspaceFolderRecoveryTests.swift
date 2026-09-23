import Foundation
import Testing
@testable import WovenMatterClient

@Suite("Workspace folder recovery")
struct WorkspaceFolderRecoveryTests {
    @Test("builds discover existing links and observe each other's folder changes")
    func sharedFilesystemIsAuthoritative() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let production = f.store("production")
        let development = f.store("development")
        let first = try f.directory("first")
        let second = try f.directory("second")
        try await production.configureRepositories(first)
        try await production.configureDatabases(second)

        let discovered = await development.resolve()
        #expect(discovered.availability.isReady)
        #expect(discovered.availability.repositoriesPath == first.path)
        #expect(discovered.availability.databasesPath == second.path)
        try Data("agent work".utf8).write(to: f.repos.appending(path: "new-repository"))
        #expect(try String(contentsOf: first.appending(path: "new-repository"), encoding: .utf8) == "agent work")

        try await development.configureRepositories(second)
        let refreshed = await production.resolve()
        #expect(refreshed.availability.repositoriesPath == second.path)
        #expect(try String(contentsOf: first.appending(path: "new-repository"), encoding: .utf8) == "agent work")

        try await development.configureRepositories(nil)
        try Data("default work".utf8).write(to: f.repos.appending(path: "default-repository"))
        let defaultFolder = await production.resolve()
        #expect(defaultFolder.availability.isReady)
        #expect(!defaultFolder.availability.usesExternalRepositories)
        #expect(FileManager.default.fileExists(atPath: f.repos.appending(path: "default-repository").path))
    }

    @Test("startup preserves relative links without a saved preference")
    func relativeLink() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let external = try f.directory("external")
        try FileManager.default.createDirectory(at: f.workspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.repos.path, withDestinationPath: "../external")
        let resolution = await f.store("fresh").resolve()
        #expect(resolution.availability.isReady)
        #expect(resolution.availability.repositoriesPath == external.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.repos.path) == "../external")
        _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(at: f.workspace, repositoriesURL: nil)
        #expect(f.repos.resolvingSymlinksInPath() == external)
    }

    @Test("a populated default folder can be selected directly")
    func selectingDefault() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("default")
        _ = await store.resolve()
        let marker = f.repos.appending(path: "existing-repository")
        try Data("keep".utf8).write(to: marker)
        let change = try await store.configureRepositories(f.repos)
        #expect(change.backupURL == nil)
        #expect(!LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))
        #expect((await store.resolve()).availability.isReady)
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    @Test("relinking requires confirmation and preserves originals while optionally copying", arguments: [false, true])
    func relinkWithBackup(copyContents: Bool) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("recovery")
        _ = await store.resolve()
        let destination = try f.directory("destination")
        let unique = f.repos.appending(path: "new-repository")
        let conflict = f.repos.appending(path: "existing-repository")
        try FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)
        try Data("work".utf8).write(to: unique.appending(path: "file"))
        try Data("original".utf8).write(to: conflict)
        try Data("destination".utf8).write(to: destination.appending(path: conflict.lastPathComponent))
        do {
            try await store.configureRepositories(destination)
            Issue.record("A nonempty default must require confirmation")
        } catch { #expect(error as? LocalACPWorkspaceError == .defaultRepositoriesNotEmpty) }
        #expect(!LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))
        #expect(try Data(contentsOf: conflict) == Data("original".utf8))
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.workspace.path)).filter { $0.contains("Backup") }.isEmpty)

        let change = try await store.configureRepositories(
            destination, recovery: copyContents ? .copyAndBackUp : .backUp
        )
        let backup = try #require(change.backupURL)
        #expect(f.repos.resolvingSymlinksInPath() == destination)
        #expect(try Data(contentsOf: backup.appending(path: "existing-repository")) == Data("original".utf8))
        #expect(try Data(contentsOf: backup.appending(path: "new-repository/file")) == Data("work".utf8))
        #expect(try Data(contentsOf: destination.appending(path: "existing-repository")) == Data("destination".utf8))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "new-repository/file").path) == copyContents)
        #expect(change.skippedItemNames == (copyContents ? ["existing-repository"] : []))
        #expect((await store.resolve()).availability.isReady)
        // The backup can itself be selected to recover the original contents.
        try await store.configureRepositories(backup)
        #expect(f.repos.resolvingSymlinksInPath() == backup.resolvingSymlinksInPath())
        #expect((await store.resolve()).availability.isReady)
    }

    @Test("broken links retain useful paths and each folder can be repaired independently")
    func unavailableDestinations() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("broken")
        let repos = try f.directory("external-repos")
        let databases = try f.directory("external-databases")
        try await store.configureRepositories(repos)
        try await store.configureDatabases(databases)
        try FileManager.default.removeItem(at: repos)
        try FileManager.default.removeItem(at: databases)
        let invalid = await store.resolve()
        #expect(!invalid.availability.isReady)
        #expect(invalid.availability.rootPath == f.workspace.path)
        #expect(invalid.availability.repositoriesPath == repos.path)
        #expect(invalid.availability.usesExternalDatabases)
        #expect(LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))

        let replacement = try f.directory("replacement")
        try await store.configureRepositories(replacement)
        #expect(f.repos.resolvingSymlinksInPath() == replacement)
        try await store.configureDatabases(nil)
        #expect((await store.resolve()).availability.isReady)
    }

    @Test("database recovery copies contents and preserves its original folder")
    func databaseRecovery() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("databases")
        _ = await store.resolve()
        let databases = f.workspace.appending(path: "Databases")
        try Data("data".utf8).write(to: databases.appending(path: "important.sqlite"))
        let destination = try f.directory("destination")
        do {
            try await store.configureDatabases(destination)
            Issue.record("Expected a confirmation requirement")
        } catch { #expect(error as? LocalACPWorkspaceError == .defaultDatabasesNotEmpty) }
        let result = try await store.configureDatabases(destination, recovery: .copyAndBackUp)
        let backup = try #require(result.backupURL)
        #expect(try Data(contentsOf: backup.appending(path: "important.sqlite")) == Data("data".utf8))
        #expect(try Data(contentsOf: destination.appending(path: "important.sqlite")) == Data("data".utf8))
    }

    @Test("legacy Repos spelling migrates without losing contents or link targets", arguments: [false, true])
    func legacyCapitalization(linked: Bool) async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace, withIntermediateDirectories: true)
        let legacy = f.workspace.appending(path: "REPOS")
        let target = try f.directory("external")
        if linked {
            try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: target)
        } else {
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        }
        try Data("keep".utf8).write(to: legacy.appending(path: "repository"))
        let store = f.store("migration")
        #expect((await store.resolve()).availability.isReady)
        #expect((await store.resolve()).availability.isReady) // migration is idempotent
        let names = try FileManager.default.contentsOfDirectory(atPath: f.workspace.path)
        #expect(names.contains("Repos"))
        #expect(try Data(contentsOf: f.repos.appending(path: "repository")) == Data("keep".utf8))
        #expect(try Data(contentsOf: legacy.appending(path: "repository")) == Data("keep".utf8))
        if linked { #expect(f.repos.resolvingSymlinksInPath() == target) }
    }

    @Test("a failed copy keeps the original folder in use")
    func copyFailurePreservesDefault() async throws {
        // Permission failures cannot be exercised by a root test runner.
        guard geteuid() != 0 else { return }
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("copy-failure")
        _ = await store.resolve()
        let unreadable = f.repos.appending(path: "unreadable")
        try Data("original".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let destination = try f.directory("destination")
        do {
            try await store.configureRepositories(destination, recovery: .copyAndBackUp)
            Issue.record("Expected copying the unreadable source to fail")
        } catch {
            guard case .copyFailed = error as? LocalACPWorkspaceError else {
                Issue.record("Unexpected copy error: \(error)")
                return
            }
        }
        #expect(!LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
        #expect((await store.resolve()).availability.isReady)
    }

    @Test("startup never applies a stale destination to an existing link or directory")
    func startupDoesNotReplaceExistingFolders() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let current = try f.directory("current")
        let stale = try f.directory("stale")
        let store = f.store("startup")
        try await store.configureRepositories(current)
        _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(at: f.workspace, repositoriesURL: stale)
        #expect(f.repos.resolvingSymlinksInPath() == current)
        try await store.configureRepositories(nil)
        try Data("work".utf8).write(to: f.repos.appending(path: "repository"))
        _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(at: f.workspace, repositoriesURL: stale)
        #expect(!LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))
        #expect(try Data(contentsOf: f.repos.appending(path: "repository")) == Data("work".utf8))
    }

    @Test("startup does not change external folder permissions")
    func externalPermissions() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let external = try f.directory("external")
        let store = f.store("permissions")
        try await store.configureRepositories(external)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: external.path)
        #expect((await store.resolve()).availability.isReady)
        let mode = try FileManager.default.attributesOfItem(atPath: external.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o750)
    }

    @Test("a malformed database path cannot block repository repair")
    func independentRepairWithFileObstruction() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("obstruction")
        _ = await store.resolve()
        let databases = f.workspace.appending(path: "Databases")
        try FileManager.default.removeItem(at: databases)
        try Data("keep".utf8).write(to: databases)
        let external = try f.directory("external")
        try await store.configureRepositories(external)
        #expect(f.repos.resolvingSymlinksInPath() == external)
        #expect(try Data(contentsOf: databases) == Data("keep".utf8))
    }

    @Test("a failed repository copy does not leave a partial destination")
    func partialRepositoryCopy() async throws {
        guard geteuid() != 0 else { return }
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("partial-copy")
        _ = await store.resolve()
        let repo = f.repos.appending(path: "repository")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("readable".utf8).write(to: repo.appending(path: "first"))
        let unreadable = repo.appending(path: "unreadable")
        try Data("secret".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let destination = try f.directory("destination")
        do {
            try await store.configureRepositories(destination, recovery: .copyAndBackUp)
            Issue.record("Expected the repository copy to fail")
        } catch { #expect(error is LocalACPWorkspaceError) }
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "repository").path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: destination.path)).isEmpty)
        #expect(!LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        let retry = try await store.configureRepositories(destination, recovery: .copyAndBackUp)
        #expect(retry.skippedItemNames.isEmpty)
        #expect(try Data(contentsOf: destination.appending(path: "repository/first")) == Data("readable".utf8))
        #expect(try Data(contentsOf: destination.appending(path: "repository/unreadable")) == Data("secret".utf8))
    }

    @Test("a destination inside the folder being replaced cannot move itself into a backup")
    func rejectNestedDestination() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("nested")
        _ = await store.resolve()
        let nested = f.repos.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        do {
            try await store.configureRepositories(nested, recovery: .copyAndBackUp)
            Issue.record("Expected an invalid destination")
        } catch { #expect(error as? LocalACPWorkspaceError == .repositoriesDirectoryContainsWorkspace) }
        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(!LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))
    }

    @Test("workspace ancestors, including the filesystem root, cannot be linked", arguments: [LocalACPWorkspaceFolder.repositories, .databases])
    func rejectWorkspaceAncestors(folder: LocalACPWorkspaceFolder) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("ancestors")
        _ = await store.resolve()
        let original = f.workspace.appending(path: folder.directoryName)
        try Data("keep".utf8).write(to: original.appending(path: "marker"))
        for target in [URL(fileURLWithPath: "/", isDirectory: true), f.home, f.workspace] {
            do {
                try LocalACPWorkspaceProvisioner.configureDirectory(
                    folder, at: f.workspace, externalURL: target, recovery: .backUp
                )
                Issue.record("Expected ancestor rejection: \(target.path)")
            } catch { #expect(error as? LocalACPWorkspaceError == folder.containsWorkspaceError) }
            #expect(!LocalACPWorkspaceProvisioner.isSymbolicLink(original))
            #expect(try Data(contentsOf: original.appending(path: "marker")) == Data("keep".utf8))
        }
    }

    @Test("readers never lose the folder while links and defaults are exchanged")
    func continuousFolderAvailability() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("continuous")
        _ = await store.resolve()
        let first = try f.directory("first")
        let second = try f.directory("second")
        try Data("preserve first".utf8).write(to: first.appending(path: "marker"))
        try Data("preserve second".utf8).write(to: second.appending(path: "marker"))
        let path = f.repos.path
        let (readiness, ready) = AsyncStream<Void>.makeStream()
        let observer = Task.detached { () -> (available: Bool, checks: Int) in
            defer { ready.finish() }
            var checks = 0
            while !Task.isCancelled {
                guard FileManager.default.fileExists(atPath: path) else { return (false, checks) }
                checks += 1
                if checks == 1 {
                    ready.yield()
                    ready.finish()
                }
                await Task.yield()
            }
            return (true, checks)
        }
        defer { observer.cancel() }
        // Starting a detached task does not guarantee it runs before these actor
        // calls complete, especially under a constrained test executor.
        var readinessIterator = readiness.makeAsyncIterator()
        _ = await readinessIterator.next()
        for _ in 0..<12 {
            try await store.configureRepositories(first)
            try await store.configureRepositories(second)
            try await store.configureRepositories(nil)
        }
        observer.cancel()
        let observed = await observer.value
        #expect(observed.available)
        #expect(observed.checks > 0)
        #expect(try Data(contentsOf: first.appending(path: "marker")) == Data("preserve first".utf8))
        #expect(try Data(contentsOf: second.appending(path: "marker")) == Data("preserve second".utf8))
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.workspace.path))
            .allSatisfy { !$0.hasPrefix(".wovenmatter-folder-") })
    }

    @Test("saved destinations seed missing folders but never override existing folders")
    func savedDestinationMigration() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let external = try f.directory("external")
        let store = f.store("legacy-preferences", repositories: external, databases: external)
        let resolution = await store.resolve()
        #expect(resolution.availability.isReady)
        #expect(resolution.launchConfiguration?.repositoriesURL == external)
        #expect(resolution.launchConfiguration?.databasesURL == external)
        #expect(resolution.availability.usesExternalRepositories)
        #expect(resolution.availability.usesExternalDatabases)
        try await f.store("other-build").configureRepositories(nil)
        let refreshed = await store.resolve()
        #expect(refreshed.availability.isReady)
        #expect(!refreshed.availability.usesExternalRepositories)
    }

    @Test("copying preserves symlinks and never replaces a dangling destination link")
    func copySymbolicLinks() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("copy-links")
        _ = await store.resolve()
        let destination = try f.directory("destination")
        try FileManager.default.createSymbolicLink(atPath: f.repos.appending(path: "shortcut").path, withDestinationPath: "missing")
        try Data("keep".utf8).write(to: f.repos.appending(path: "conflict"))
        let existing = destination.appending(path: "conflict")
        try FileManager.default.createSymbolicLink(atPath: existing.path, withDestinationPath: "unavailable")
        let result = try await store.configureRepositories(destination, recovery: .copyAndBackUp)
        #expect(result.skippedItemNames == ["conflict"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: existing.path) == "unavailable")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "shortcut").path) == "missing")
        let backup = try #require(result.backupURL)
        #expect(try Data(contentsOf: backup.appending(path: "conflict")) == Data("keep".utf8))
    }

    @Test("simultaneous builds serialize initialization and folder changes")
    func concurrentBuilds() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.directory("first")
        let second = try f.directory("second")
        let stores = (0..<8).map { f.store("concurrent-\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, store) in stores.enumerated() {
                group.addTask {
                    for _ in 0..<3 {
                        try await store.configureRepositories(index.isMultiple(of: 2) ? first : second)
                        let resolution = await store.resolve()
                        #expect(resolution.availability.isReady)
                        #expect([first, second].contains(resolution.launchConfiguration?.repositoriesURL))
                    }
                }
            }
            try await group.waitForAll()
        }
        let instructions = try String(contentsOf: f.workspace.appending(path: "AGENTS.md"), encoding: .utf8)
        #expect(instructions.components(separatedBy: "<!-- BEGIN WOVEN MATTER MANAGED -->").count == 2)
        #expect(LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))
    }
}

private final class Fixture {
    private var suites: [String] = []
    let home: URL
    var workspace: URL { home.appending(path: ".woven-matter") }
    var repos: URL { workspace.appending(path: "Repos") }
    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "workspace-recovery-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func directory(_ name: String) throws -> URL {
        let url = home.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func store(_ name: String, repositories: URL? = nil, databases: URL? = nil) -> LocalACPWorkspaceConfigurationStore {
        let suite = "workspace-recovery-\(home.lastPathComponent)-\(name)"
        suites.append(suite)
        if repositories != nil || databases != nil {
            let paths = ["repositoriesPath": repositories?.path, "databasesPath": databases?.path].compactMapValues { $0 }
            UserDefaults(suiteName: suite)?.set(
                try? JSONEncoder().encode(paths), forKey: "wovenmatter.local-agent-workspace.folders"
            )
        }
        return LocalACPWorkspaceConfigurationStore(homeDirectory: home, defaultsSuiteName: suite)
    }
    func remove() {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try? FileManager.default.removeItem(at: home)
    }
}
