import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct OpenCodeCreationTests {
    @Test(arguments: [false, true], [false, true])
    func creationOwnsDefaultsAndRejectedDefaultsStillOpen(remote: Bool, rejected: Bool) async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let transport = CreationTransport()
        CreationProtocol.transport = transport
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CreationProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let identity = remote ? "remote-workspace:" + f.remote.id.uuidString.lowercased()
            : "local:" + OpenCodeConnection.registrationURL().standardizedFileURL.path
        let connection = try OpenCodeConnection(identity: identity, url: URL(string: "http://creation.invalid")!, password: "fixture")
        let coordinator = OpenCodeSessionCoordinator(database: f.database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        let preference = "wovenmatter.opencode." + (remote ? "remote." + f.remote.id.uuidString.lowercased() + "." : "")
        f.defaults.set(true, forKey: preference + "local-connected")
        let model = await OpenCodeModel(store: f.store, ownerDeviceID: UUID(), defaults: f.defaults,
            remoteConfiguration: remote ? f.remote : nil, remoteWorkspaces: remote ? f.model.remoteWorkspaces : nil,
            coordinator: coordinator, connectionProvider: { connection })
        let saved = SessionSelectionPreferences(defaults: f.defaults)
        saved.saveDefaults(.init(model: rejected ? "fixture/unavailable" : "fixture/saved", tools: ["notes"]), harness: "opencode")
        let gate = FacadeGate(); gate.hold(); defer { gate.open() }
        var toolsApplied = 0
        model.applyInitialSessionTools = { _, _ in toolsApplied += 1; await gate.pass() }
        let owner = remote ? "remote:" + f.remote.id.uuidString.lowercased() : try await f.store.executionWorkspaceID()
        let root = SessionCreationRoot(folderID: nil, location: .init(workspaceID: owner, rootPath: f.directory.path, managed: false), defaultPath: f.directory.path)
        let uuid = UUID()
        let creation = Task { try await model.create(workspace: f.directory, requestedConversationID: uuid, executionRoot: root) }
        await gate.waitForArrival()
        let id = uuid.uuidString.lowercased()
        let link = try #require(model.links[id])
        // A read during creation cannot start a second initialization.
        try await model.refreshCatalog(id)
        #expect(toolsApplied == 1)
        #expect(model.updatingSessions.isEmpty)
        saved.saveDefaults(.init(model: "fixture/newer"), harness: "opencode")
        gate.open()
        #expect(try await creation.value == id)
        #expect(saved.conversation(id: id)?.requiresApplication == false)
        #expect(model.metadata(id)?.model == (rejected ? "fixture/native" : "fixture/saved"))
        let changes = transport.modelChanges
        #expect(changes == (rejected ? 0 : 1))
        await model.watch(link)
        try await model.refreshCatalog(id)
        _ = try await model.send(id, input: .init(text: "First message"))
        #expect(toolsApplied == 1)
        #expect(transport.modelChanges == changes)
        // A manual correction changes only its selected field, not old defaults.
        let edit = try #require(model.updateSelection(id, model: "fixture/newer"))
        try await edit.value
        #expect(model.metadata(id)?.model == "fixture/newer")
        #expect(toolsApplied == 1)
        #expect(transport.modelChanges == changes + 1)
        await model.shutdown()
    }
}

private final class CreationTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: OpenCodeValue] = [:]
    private var changes = 0
    var modelChanges: Int { lock.withLock { changes } }
    private func body(_ request: URLRequest) throws -> OpenCodeValue {
        if let data = request.httpBody { return try OpenCodeValue.decode(data) }
        guard let stream = request.httpBodyStream else { return .null }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return try OpenCodeValue.decode(data)
    }
    func response(_ request: URLRequest) throws -> (Int, OpenCodeValue) {
        try lock.withLock {
            let path = request.url!.path
            let method = request.httpMethod ?? "GET"
            if path == "/api/info" || path == "/api/health" {
                return (200, ["version": "2.1.3", "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))])
            }
            if path == "/api/model" {
                return (200, ["data": .array(["native", "saved", "newer"].map {
                    ["id": .string($0), "providerID": "fixture", "name": .string($0), "enabled": .bool(true)]
                })])
            }
            if path == "/api/model/default" { return (200, ["data": ["id": "native", "providerID": "fixture"]]) }
            if path == "/api/command" { return (200, ["data": .array([])]) }
            if path == "/api/session/active" { return (200, ["data": [:]]) }
            if path == "/api/session", method == "POST" {
                let input = try body(request)
                let id = input["id"].text
                sessions[id] = ["id": .string(id), "title": "New chat", "location": input["location"],
                    "model": ["id": "native", "providerID": "fixture"], "permissions": .array([])]
                return (200, ["data": sessions[id]!])
            }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 3, parts[0] == "api", parts[1] == "session", var info = sessions[parts[2]] else { return (404, [:]) }
            let id = parts[2]
            if parts.count == 3 {
                if method == "PATCH" { info["permissions"] = try body(request)["permissions"]; sessions[id] = info }
                return (200, ["data": info])
            }
            if parts.last == "model", method == "POST" {
                info["model"] = try body(request)["model"]; sessions[id] = info; changes += 1
                return (200, ["data": info])
            }
            if parts.last == "prompt", method == "POST" {
                let input = try body(request)
                return (200, ["data": ["id": input["id"], "type": "user", "text": input["text"]]])
            }
            if ["message", "inbox", "form", "permission"].contains(parts.last ?? "") {
                return (200, ["data": .array([]), "cursor": ["next": .null]])
            }
            return (404, [:])
        }
    }
}

private final class CreationProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var transport = CreationTransport()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Real sessions keep both event feeds open. A 404 here triggers the
        // production reconnect fence and cancels unrelated fixture requests.
        if request.url?.path == "/api/event" || (request.url?.path.hasPrefix("/api/experimental/session/") == true && request.url?.path.hasSuffix("/log") == true) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            return
        }
        do {
            let (code, value) = try Self.transport.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(value))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
