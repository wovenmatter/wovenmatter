#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

/// Opt-in deployment verification through the exact client used by the Mac app.
/// It is disabled in normal test runs and never invokes an account login.
struct RemoteHostLiveValidationTests {
    struct State: Codable {
        var configuration: RemoteWorkspaceConfiguration
        let token: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WOVENMATTER_LIVE_HOST"] != nil))
    func deployFromMacAndConnectOverTailnet() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try #require(environment["WOVENMATTER_LIVE_HOST"])
        let user = environment["WOVENMATTER_LIVE_HOST_USER"] ?? "trey"
        let workspaceID = environment["WOVENMATTER_LIVE_HOST_ID"] ?? "host-mode-validation"
        // `user` validates a Normal user account, which needs no sudo; the default is Full root.
        let accessMode = try #require(RemoteWorkspaceAccessMode(rawValue: environment["WOVENMATTER_LIVE_HOST_ACCESS_MODE"] ?? "fullRoot"))
        let stateURL = URL(fileURLWithPath: environment["WOVENMATTER_LIVE_HOST_STATE"] ?? "/private/tmp/wovenmatter-host-test-state.json")
        var state: State
        let existing = FileManager.default.fileExists(atPath: stateURL.path)
        if existing {
            let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw RemoteWorkspaceClientError.invalidResponse("The validation state must be a private regular file owned by this account.")
            }
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
            guard state.configuration.hostName == host, state.configuration.userName == user,
                  state.configuration.workspaceID == workspaceID else {
                throw RemoteWorkspaceClientError.invalidResponse("The private validation state belongs to a different workspace.")
            }
        } else {
            state = State(configuration: .init(name: "Native host validation", workspaceID: workspaceID,
                hostName: host, userName: user, kind: .host, accessMode: accessMode),
                token: UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        }
        let client: RemoteWorkspaceSSHClient
        if let bundlePath = environment["WOVENMATTER_LIVE_HOST_BUNDLE_ROOT"] {
            let bundleRoot = URL(fileURLWithPath: bundlePath, isDirectory: true)
            client = RemoteWorkspaceSSHClient(runner: RemoteWorkspaceSSHClient.runSSH,
                scriptLoader: { try Data(contentsOf: bundleRoot.appending(path: "scripts/remote-host.sh")) },
                deploymentRoot: bundleRoot,
                streamingRunner: { destination, command, input, progress in
                    try RemoteWorkspaceSSHClient.runSSH(destination: destination, command: command, input: input,
                        timeLimit: nil, onStandardError: progress)
                })
        } else {
            client = RemoteWorkspaceSSHClient()
        }
        var inspection = try await client.preflight(hostName: host, userName: user, accessMode: accessMode)
        if !inspection.ready {
            print("Host preparation actions: " + (inspection.requiredPrivilegedActions ?? inspection.preparationActions ?? []).joined(separator: "\n"))
            guard environment["WOVENMATTER_LIVE_HOST_PREPARE"] == "1" else {
                throw RemoteWorkspaceClientError.invalidResponse("Review the reported host preparation actions and set WOVENMATTER_LIVE_HOST_PREPARE=1 to execute them.")
            }
            inspection = try await client.prepareHost(hostName: host, userName: user, accessMode: accessMode)
        }
        #expect(inspection.ready)
        guard inspection.workspaceID == nil || inspection.workspaceID == workspaceID else {
            throw RemoteWorkspaceClientError.invalidResponse("A different host workspace already belongs to this account.")
        }
        let updating = inspection.workspaceID == workspaceID
        state.configuration.dataRoot = inspection.dataRoot
        state.configuration.workspaceRoot = inspection.workspaceRoot
        state.configuration.databasesDirectory = inspection.databasesDirectory
        state.configuration.attachmentsDirectory = inspection.attachmentsDirectory
        try Self.save(state, to: stateURL)
        let status = try await client.deployHost(configuration: state.configuration, token: state.token,
            update: updating) { print("Host deployment: " + $0) }
        #expect(status.running && status.kind == .host)
        state.configuration.remotePort = status.hostPort
        state.configuration.dataRoot = status.dataRoot ?? state.configuration.dataRoot
        state.configuration.workspaceRoot = status.workspaceRoot ?? state.configuration.workspaceRoot
        state.configuration.databasesDirectory = status.databasesDirectory ?? state.configuration.databasesDirectory
        state.configuration.attachmentsDirectory = status.attachmentsDirectory ?? state.configuration.attachmentsDirectory
        try Self.save(state, to: stateURL)
        let token = state.token
        let tunnel = RemoteWorkspaceTunnel()
        do {
            try await tunnel.start(configuration: state.configuration, localPort: 45500) { port in
                let service = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token)
                return (try? await service.health().status) == "ready"
            }
            let port = try #require(await tunnel.localPort)
            let service = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token)
            let health = try await service.health()
            #expect(health.runtimeKind == .host && health.accessMode == accessMode)
            #expect(health.workspaceRoot == state.configuration.workspaceRoot)
            #expect(health.serviceFingerprint != nil)
            if environment["WOVENMATTER_LIVE_HOST_ROLLBACK"] == "1" {
                try await Self.verifyRollback(state: state, client: client, service: service)
            }
            await tunnel.stop()
        } catch {
            await tunnel.stop()
            throw error
        }
        print("Native host deployment and authenticated Tailnet tunnel verified. Private state: " + stateURL.path)
    }

    private struct InstallationSnapshot: Decodable, Equatable {
        let current: String
        let node: String
        let browsers: String
        let environmentDigest: String
        let unitDigest: String
        let recordDigest: String
        let browserSelfTestDigest: String?
    }

    /// Sends a valid, independently fingerprinted candidate whose browser check
    /// deliberately fails. Only a private temporary source copy is changed.
    private static func verifyRollback(state: State, client: RemoteWorkspaceSSHClient,
                                       service: RemoteWorkspaceServiceClient) async throws {
        try requireValidationWorkspace(state.configuration)
        let previousStatus = try await client.status(configuration: state.configuration)
        let previousHealth = try await service.health()
        let previousFingerprint = try #require(previousHealth.serviceFingerprint)
        let before = try installationSnapshot(configuration: state.configuration)
        #expect(before.browserSelfTestDigest != nil)
        let sourceRoot = try RemoteWorkspaceSSHClient.loadDeploymentRoot()
        let sourceDeployment = try RemoteWorkspaceDeployment(root: sourceRoot)
        let candidateRoot = FileManager.default.temporaryDirectory.appending(path: ".wovenmatter-rollback-candidate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: candidateRoot) }
        for source in sourceDeployment.sourceFiles {
            let destination = candidateRoot.appending(path: source)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: sourceRoot.appending(path: source), to: destination)
        }
        let failedSelfTest = #"""
        import { realpathSync } from 'node:fs'
        import { fileURLToPath } from 'node:url'
        const failure = () => ({ ok:false, reason:'sandbox_inactive', missingLibraries:[], hint:'Deliberate rollback validation fixture.' })
        export async function browserSelfTest() { return failure() }
        export async function verifySandboxProcesses() { return failure() }
        export function missingLibrariesFromLdd() { return [] }
        if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
          process.stdout.write(JSON.stringify(failure()) + '\n')
          process.exitCode = 1
        }
        """#
        try Data(failedSelfTest.utf8).write(to: candidateRoot.appending(path: "remote/src/browser-selftest.mjs"))
        let candidate = try RemoteWorkspaceDeployment(root: candidateRoot)
        guard candidate.fingerprint != previousFingerprint else {
            throw RemoteWorkspaceClientError.invalidResponse("The rollback candidate must have a distinct source identity.")
        }
        let hostScript = try Data(contentsOf: sourceRoot.appending(path: "scripts/remote-host.sh"))
        let updating = RemoteWorkspaceSSHClient(runner: RemoteWorkspaceSSHClient.runSSH,
            scriptLoader: { hostScript }, deploymentRoot: candidateRoot,
            streamingRunner: { destination, command, input, progress in
                try RemoteWorkspaceSSHClient.runSSH(destination: destination, command: command, input: input,
                    timeLimit: nil, onStandardError: progress)
            })
        var rejectedByBrowserCheck = false
        do {
            _ = try await updating.deployHost(configuration: state.configuration, token: state.token, update: true) {
                print("Rollback candidate: " + $0)
            }
        } catch RemoteWorkspaceClientError.commandFailed(let detail) {
            guard detail.contains("browser_selftest_failed") else {
                throw RemoteWorkspaceClientError.invalidResponse("The rollback candidate failed before the expected browser verification.")
            }
            rejectedByBrowserCheck = true
        }
        guard rejectedByBrowserCheck else {
            // Keep this test deployment usable even when a regression accepts
            // the deliberately bad candidate instead of rolling it back.
            _ = try await client.deployHost(configuration: state.configuration, token: state.token, update: true)
            throw RemoteWorkspaceClientError.invalidResponse("The candidate unexpectedly passed; the original host source bundle was restored.")
        }
        let restoredStatus = try await client.status(configuration: state.configuration)
        #expect(restoredStatus.running)
        #expect(restoredStatus.fingerprint == previousStatus.fingerprint)
        #expect(restoredStatus.hostPort == previousStatus.hostPort)
        #expect(restoredStatus.dataRoot == previousStatus.dataRoot)
        #expect(restoredStatus.workspaceRoot == previousStatus.workspaceRoot)
        #expect(restoredStatus.databasesDirectory == previousStatus.databasesDirectory)
        #expect(restoredStatus.attachmentsDirectory == previousStatus.attachmentsDirectory)
        let restoredHealth = try await waitForHealth(service: service, fingerprint: previousFingerprint)
        #expect(restoredHealth.workspaceRoot == previousHealth.workspaceRoot)
        #expect(restoredHealth.databasesDirectory == previousHealth.databasesDirectory)
        #expect(restoredHealth.attachmentsDirectory == previousHealth.attachmentsDirectory)
        #expect(restoredHealth.dataRoot == previousHealth.dataRoot)
        #expect(restoredHealth.accessMode == previousHealth.accessMode)
        #expect(try installationSnapshot(configuration: state.configuration) == before)
        print("Failed browser verification rejected the candidate; prior service fingerprint, port, paths, links, private environment, unit, and diagnostics were restored.")
    }

    private static func waitForHealth(service: RemoteWorkspaceServiceClient, fingerprint: String) async throws -> RemoteWorkspaceHealth {
        for _ in 0..<150 {
            if let health = try? await service.health(), health.status == "ready", health.serviceFingerprint == fingerprint {
                return health
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RemoteWorkspaceClientError.invalidResponse("The previous host service did not recover after the rollback fixture.")
    }

    private static func installationSnapshot(configuration: RemoteWorkspaceConfiguration) throws -> InstallationSnapshot {
        let root = try RemoteWorkspaceExecTarget(configuration: configuration).dataRoot
        let script = #"""
        const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto');
        const root=process.argv[1],home=os.homedir();
        const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
        const browser=path.join(root,'run/browser-selftest.json');
        console.log(JSON.stringify({current:fs.readlinkSync(path.join(root,'current')),node:fs.readlinkSync(path.join(root,'node/current')),
          browsers:fs.readlinkSync(path.join(root,'browsers/current')),environmentDigest:hash(path.join(home,'.config/wovenmatter/service.env')),
          unitDigest:hash(path.join(home,'.config/systemd/user/wovenmatter.service')),recordDigest:hash(path.join(root,'installation.json')),
          browserSelfTestDigest:fs.existsSync(browser)?hash(browser):null}));
        """#
        return try JSONDecoder().decode(InstallationSnapshot.self,
            from: runLiveCommand(configuration: configuration, arguments: ["node", "-e", script, "--", root]))
    }

    private static func runLiveCommand(configuration: RemoteWorkspaceConfiguration, arguments: [String]) throws -> Data {
        let destination = try RemoteWorkspaceSSHClient.validatedDestination(hostName: configuration.hostName,
            userName: configuration.userName)
        let command = try RemoteWorkspaceExecTarget(configuration: configuration).shellCommand(arguments)
        return try RemoteWorkspaceSSHClient.runAttachmentSSH(destination: destination, command: command, input: nil)
    }

    private static func requireValidationWorkspace(_ configuration: RemoteWorkspaceConfiguration) throws {
        guard configuration.kind == .host, configuration.workspaceID == "host-mode-validation",
              configuration.hostName == "workstation-home-1" else {
            throw RemoteWorkspaceClientError.invalidResponse("Mutating live fixtures are limited to host-mode-validation on workstation-home-1.")
        }
    }

    private static func save(_ state: State, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".wovenmatter-validation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bytes = try JSONEncoder().encode(state)
        guard FileManager.default.createFile(atPath: temporary.path, contents: bytes,
            attributes: [.posixPermissions: 0o600]) else {
            throw RemoteWorkspaceClientError.invalidResponse("Cannot save private host validation state.")
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
}
