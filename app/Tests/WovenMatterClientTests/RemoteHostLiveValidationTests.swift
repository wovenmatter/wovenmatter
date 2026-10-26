import Darwin
import Foundation
import Testing
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
                hostName: host, userName: user, kind: .host, accessMode: .fullRoot),
                token: UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        }
        let client = RemoteWorkspaceSSHClient()
        var inspection = try await client.preflight(hostName: host, userName: user, kind: .host, accessMode: .fullRoot)
        if !inspection.ready {
            print("Host preparation actions: " + (inspection.requiredPrivilegedActions ?? inspection.preparationActions ?? []).joined(separator: "\n"))
            guard environment["WOVENMATTER_LIVE_HOST_PREPARE"] == "1" else {
                throw RemoteWorkspaceClientError.invalidResponse("Review the reported host preparation actions and set WOVENMATTER_LIVE_HOST_PREPARE=1 to execute them.")
            }
            inspection = try await client.prepareHost(hostName: host, userName: user, kind: .host, accessMode: .fullRoot)
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
            #expect(health.runtimeKind == .host && health.accessMode == .fullRoot)
            #expect(health.workspaceRoot == state.configuration.workspaceRoot)
            #expect(health.serviceFingerprint != nil)
            await tunnel.stop()
        } catch {
            await tunnel.stop()
            throw error
        }
        print("Native host deployment and authenticated Tailnet tunnel verified. Private state: " + stateURL.path)
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
