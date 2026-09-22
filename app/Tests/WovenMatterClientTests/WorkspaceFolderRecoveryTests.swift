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
            destination, backUpExistingContents: true, copyExistingContents: copyContents
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
        let result = try await store.configureDatabases(destination, backUpExistingContents: true, copyExistingContents: true)
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
            try await store.configureRepositories(destination, backUpExistingContents: true, copyExistingContents: true)
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

    @Test("a destination inside the folder being replaced cannot move itself into a backup")
    func rejectNestedDestination() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = f.store("nested")
        _ = await store.resolve()
        let nested = f.repos.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        do {
            try await store.configureRepositories(nested, backUpExistingContents: true, copyExistingContents: true)
            Issue.record("Expected an invalid destination")
        } catch { #expect(error as? LocalACPWorkspaceError == .repositoriesDirectoryContainsWorkspace) }
        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(!LocalACPWorkspaceProvisioner.isSymbolicLink(f.repos))
    }
}

private struct Fixture {
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
    func store(_ name: String) -> LocalACPWorkspaceConfigurationStore {
        LocalACPWorkspaceConfigurationStore(homeDirectory: home, defaultsSuiteName: "workspace-recovery-\(home.lastPathComponent)-\(name)")
    }
    func remove() {
        for name in ["production", "development", "fresh", "default", "recovery", "broken", "databases", "migration", "nested", "copy-failure"] {
            let suite = "workspace-recovery-\(home.lastPathComponent)-\(name)"
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try? FileManager.default.removeItem(at: home)
    }
}
