import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite struct CompanionPairingApprovalTests {
    @Test func approvalIsExplicitSecretBoundAndRecoverableAfterRestart() async throws {
        let fixture = try PairingFixture(); defer { fixture.remove() }
        let auth = try fixture.authentication()
        let request = fixture.request()
        let pending = try await auth.requestPairing(request)
        #expect(pending.state == .pending && pending.pairing == nil)
        #expect(await auth.devices().isEmpty)
        await #expect(throws: CompanionAPIError.self) { try await auth.authenticate(bearer: request.requestSecret) }
        await #expect(throws: CompanionAPIError.self) {
            try await auth.pairingResult(.init(requestID: request.requestID, requestSecret: String(repeating: "x", count: 43)))
        }
        let poll = CompanionPairingPoll(requestID: request.requestID, requestSecret: request.requestSecret)
        try await auth.approvePairing(id: request.requestID, workspaceID: fixture.libraryID)
        let first = try #require(try await auth.pairingResult(poll).pairing)
        let reopened = try fixture.authentication()
        let replay = try #require(try await reopened.pairingResult(poll).pairing)
        #expect(first == replay)
        #expect(try await reopened.authenticate(bearer: first.credential).id == request.identity.deviceID)
        let contents = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(!contents.contains(request.requestSecret) && !contents.contains(first.credential))
        let roster = try JSONEncoder().encode(await reopened.deviceConnections())
        #expect(!String(decoding: roster, as: UTF8.self).contains("credentialHash"))
        try await reopened.revoke(deviceID: request.identity.deviceID)
        await #expect(throws: CompanionAPIError.self) { try await reopened.pairingResult(poll) }
    }

    @Test func invitationApprovalBindsTheAdvertisedDeviceAndRecoversLostReply() async throws {
        let fixture = try PairingFixture(); defer { fixture.remove() }
        let auth = try fixture.authentication(), original = fixture.request()
        let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.test.ts.net:8443/wovenmatter")!, deviceID: original.identity.deviceID)
        let wrong = CompanionPairingApprovalRequest(requestID: UUID().uuidString, requestSecret: original.requestSecret,
            identity: fixture.request().identity, invitationToken: offer.payload.token)
        await #expect(throws: CompanionAPIError.self) { try await auth.requestPairing(wrong, workspaceID: fixture.libraryID) }
        let accepted = CompanionPairingApprovalRequest(requestID: original.requestID, requestSecret: original.requestSecret,
            identity: original.identity, invitationToken: offer.payload.token)
        let result = try await auth.requestPairing(accepted, workspaceID: fixture.libraryID)
        #expect(result.state == .approved)
        let reopened = try fixture.authentication()
        let replay = try await reopened.requestPairing(accepted, workspaceID: fixture.libraryID)
        #expect(replay.pairing == result.pairing)
        #expect(await reopened.devices().count == 1)
        let disk = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(!disk.contains(offer.payload.token) && !disk.contains(accepted.requestSecret))
    }

    @Test func immutablePendingIdentitySurvivesRestartButRequiresClaimBeforeApproval() async throws {
        let fixture = try PairingFixture(); defer { fixture.remove() }
        let auth = try fixture.authentication(), request = fixture.request()
        _ = try await auth.requestPairing(request)
        let changed = CompanionPairingApprovalRequest(requestID: request.requestID, requestSecret: request.requestSecret,
            identity: .init(deviceID: request.identity.deviceID, deviceName: "Changed Mac", metadata: .init(kind: .mac)))
        await #expect(throws: CompanionAPIError.self) { try await auth.requestPairing(changed) }
        let reopened = try fixture.authentication()
        await #expect(throws: CompanionAPIError.self) { try await reopened.approvePairing(id: request.requestID, workspaceID: fixture.libraryID) }
        _ = try await reopened.requestPairing(request)
        try await reopened.approvePairing(id: request.requestID, workspaceID: fixture.libraryID)
        #expect(await reopened.devices().count == 1)
    }

    @Test func deniedExpiredAndCancelledRequestsNeverRegainAuthority() async throws {
        let fixture = try PairingFixture(); defer { fixture.remove() }
        let clock = PairingClock(), auth = try fixture.authentication(now: { clock.now })
        let denied = fixture.request()
        _ = try await auth.requestPairing(denied)
        try await auth.denyPairing(id: denied.requestID)
        #expect(try await auth.pairingResult(.init(requestID: denied.requestID, requestSecret: denied.requestSecret)).state == .denied)
        await #expect(throws: CompanionAPIError.self) { try await auth.approvePairing(id: denied.requestID, workspaceID: fixture.libraryID) }
        let approved = fixture.request()
        _ = try await auth.requestPairing(approved)
        try await auth.approvePairing(id: approved.requestID, workspaceID: fixture.libraryID)
        let poll = CompanionPairingPoll(requestID: approved.requestID, requestSecret: approved.requestSecret)
        let credential = try #require(try await auth.pairingResult(poll).pairing?.credential)
        try await auth.cancelPairing(poll)
        await #expect(throws: CompanionAPIError.self) { try await auth.authenticate(bearer: credential) }
        let expired = fixture.request()
        _ = try await auth.requestPairing(expired)
        clock.advance(601)
        await #expect(throws: CompanionAPIError.self) { try await auth.approvePairing(id: expired.requestID, workspaceID: fixture.libraryID) }
        #expect(await auth.pendingPairingRequests().isEmpty)
    }

    @Test func cancellationClosesPendingApprovalAtomicallyAndRequiresHostRevocationForApprovedClaims() async throws {
        let fixture = try PairingFixture(); defer { fixture.remove() }
        let auth = try fixture.authentication(), pending = fixture.request()
        _ = try await auth.requestPairing(pending)
        let pendingPoll = CompanionPairingPoll(requestID: pending.requestID, requestSecret: pending.requestSecret)
        #expect(try await auth.preparePairingCancellation(pendingPoll) == nil)
        await #expect(throws: CompanionAPIError.self) { try await auth.approvePairing(id: pending.requestID, workspaceID: fixture.libraryID) }
        let approved = fixture.request()
        _ = try await auth.requestPairing(approved)
        try await auth.approvePairing(id: approved.requestID, workspaceID: fixture.libraryID)
        let poll = CompanionPairingPoll(requestID: approved.requestID, requestSecret: approved.requestSecret)
        let device = try #require(try await auth.preparePairingCancellation(poll))
        await #expect(throws: CompanionAPIError.self) { try await auth.cancelPairing(poll, revokeApproved: false) }
        #expect(await auth.isCurrent(device))
        try await auth.revoke(deviceID: device.id, expected: device)
        try await auth.cancelPairing(poll, revokeApproved: false)
        #expect(try await auth.preparePairingCancellation(poll) == nil)
    }

    @Test func metadataAndSeenTimesArePerDeviceAndDoNotChangeCredentialIdentity() async throws {
        let fixture = try PairingFixture(); defer { fixture.remove() }
        let clock = PairingClock(), auth = try fixture.authentication(now: { clock.now })
        let first = try await fixture.pair(auth, kind: .iPhone)
        let second = try await fixture.pair(auth, kind: .iPad)
        let firstGrant = try await auth.authenticate(bearer: first.credential)
        let secondSeen = try await auth.authenticate(bearer: second.credential).lastSeenAt
        clock.advance(61)
        let updated = try await auth.authenticate(bearer: first.credential,
            metadata: .init(kind: .iPhone, osVersion: "iOS fixture", appVersion: "2"))
        #expect(updated.lastSeenAt == clock.now && updated.metadata?.appVersion == "2")
        #expect(await auth.isCurrent(firstGrant))
        let secondStored = await auth.devices().first { $0.id == second.deviceID }
        #expect(secondStored?.lastSeenAt == secondSeen && secondStored?.kind == .iPad)
        let reopened = try fixture.authentication(now: { clock.now })
        #expect(await reopened.devices().first { $0.id == first.deviceID }?.lastSeenAt == clock.now)
        try await reopened.revoke(deviceID: first.deviceID)
        #expect(await reopened.isCurrent(firstGrant) == false)
    }

    @Test func moreThanSixteenDevicesAndLegacyUnknownMetadataRemainValid() async throws {
        let fixture = try PairingFixture(); defer { fixture.remove() }
        let clock = PairingClock(), auth = try fixture.authentication(now: { clock.now })
        for index in 0..<20 {
            if index % 8 == 0 { clock.advance(61) }
            _ = try await fixture.pair(auth, kind: .mac)
        }
        #expect(await auth.devices().count == 20)
        // Simulate a v1 device record written before metadata existed.
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any])
        var devices = try #require(document["devices"] as? [[String: Any]])
        devices[0].removeValue(forKey: "metadata"); devices[0].removeValue(forKey: "lastSeenAt")
        document["devices"] = devices; document.removeValue(forKey: "approvals")
        try JSONSerialization.data(withJSONObject: document).write(to: fixture.file)
        let legacy = try fixture.authentication()
        #expect(await legacy.devices().first?.kind == .unknown)
    }

    @Test func untrustedMetadataIsBoundedBeforeItEntersSettings() async throws {
        let fixture = try PairingFixture(); defer { fixture.remove() }
        let auth = try fixture.authentication()
        for name in ["Bad\nName", String(repeating: "a", count: 121)] {
            let request = CompanionPairingApprovalRequest(requestID: UUID().uuidString, requestSecret: String(repeating: "s", count: 43),
                identity: .init(deviceID: UUID().uuidString, deviceName: name, metadata: .init(kind: .mac)))
            await #expect(throws: CompanionAPIError.self) { try await auth.requestPairing(request) }
        }
        #expect(await auth.devices().isEmpty)
        #expect(await auth.pendingPairingRequests().isEmpty)
    }
}

private struct PairingFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "pairing-approval-\(UUID())")
    let libraryID = UUID().uuidString.lowercased()
    var file: URL { directory.appending(path: "devices.json") }
    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func authentication(now: @escaping @Sendable () -> Date = Date.init) throws -> CompanionAuthentication { try .init(fileURL: file, now: now) }
    func request() -> CompanionPairingApprovalRequest {
        .init(requestID: UUID().uuidString.lowercased(), requestSecret: UUID().uuidString + UUID().uuidString,
            identity: .init(deviceID: UUID().uuidString.lowercased(), deviceName: "Fixture Mac", metadata: .init(kind: .mac, osVersion: "fixture", appVersion: "1")))
    }
    func pair(_ auth: CompanionAuthentication, kind: CompanionDeviceKind) async throws -> CompanionPairResponse {
        let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.test.ts.net:8443/wovenmatter")!)
        return try await auth.pair(.init(token: offer.payload.token, deviceID: UUID().uuidString.lowercased(), deviceName: "Fixture",
            metadata: .init(kind: kind, osVersion: "fixture", appVersion: "1")), workspaceID: libraryID)
    }
}
private final class PairingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { instant } }
    func advance(_ seconds: Double) { lock.withLock { instant.addTimeInterval(seconds) } }
}
