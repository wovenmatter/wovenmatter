import Foundation
import UIKit
import CompanionClient
import WovenMatterCompanion

/// Member mode (docs/architecture/WOVEN_EVERYWHERE.md): the phone pairs once
/// with any Mac, which adds it as an `ios` member. From then on it signs every
/// request with its own key, learns every Mac and Linux member from whichever
/// one it syncs with, syncs with any online library host and manages sessions
/// on every workspace directly. It has no home Mac.
extension CompanionModel {
  var memberMode: Bool { libraryHosts != nil && memberIdentity != nil }
  /// Paired before members existed (or with a Mac that is too old): one more
  /// pairing makes this phone reach every device directly.
  var needsMemberPairing: Bool { credential != nil && !memberMode }
  /// The Mac or Linux host this phone synced with last. Its own sessions are
  /// the "central" route; every other device's sessions go to that device.
  var libraryHostDeviceID: String? { membership?.currentHost?.deviceID ?? membership?.pairedHostDeviceID }
  var libraryHostName: String? {
    // The saved membership carries the host's real device ID and name once learned.
    guard memberMode, let host = membership?.currentHost ?? synchronizationStatus.libraryHost else { return nil }
    if let member = membership?.members.first(where: { $0.deviceID == host.deviceID }) { return member.name }
    return host.name
  }
  /// The registered workspace of the library host itself, when it is a Mac.
  var centralExecutionWorkspace: CompanionExecutionWorkspace? {
    let central = executionWorkspaces.filter { $0.capabilities.contains("history.central.v1") }
    if memberMode, let host = libraryHostDeviceID {
      return central.first { $0.kind == .mac && $0.ownerDeviceID.lowercased() == host }
    }
    return central.first
  }
  /// "Update everything" and re-pairing notices for Settings and the sync status.
  var membershipNotice: String? {
    if membership?.memberRequestsAccepted == false {
      return "Update everything: \(membership?.pairedName ?? "your Mac") needs a newer Woven Matter so this iPhone can reach every device directly. Until then it syncs only through that Mac."
    }
    if let message = synchronizationStatus.updateRequired { return message }
    if needsMemberPairing {
      return "Pair again once with any Mac so this iPhone connects directly to every Mac and Linux machine, even when the Mac it first paired with is offline. Your notes and chats stay on this iPhone."
    }
    return nil
  }

  func loadMemberIdentity() throws -> MobileMemberIdentity {
    if let memberIdentity, memberIdentity.deviceID == state.deviceID { return memberIdentity }
    let identity = try MobileMemberKeyVault.loadOrCreate(deviceID: state.deviceID, storage: memberKeyStorage)
    memberIdentity = identity
    return identity
  }

  /// Member mode when this phone paired with its key and the Mac accepted it.
  /// Returns false to keep the bearer-era connection.
  func configureMemberTransport() throws -> Bool {
    guard let store, let file = membershipFile, let saved = try MobileLibraryHosts.load(file: file),
          saved.deviceID == state.deviceID, saved.memberRequestsAccepted != false else {
      libraryHosts = nil; membership = nil
      if let path = membershipFile, let saved = try? MobileLibraryHosts.load(file: path), saved.deviceID == state.deviceID { membership = saved }
      return false
    }
    let identity = try loadMemberIdentity()
    let hosts = try MobileLibraryHosts(state: saved, identity: identity, file: file, metadata: deviceMetadata, performer: httpPerformer)
    let first = saved.candidates(registry: executionWorkspaces).first
      ?? MobileLibraryHost(deviceID: saved.pairedHostDeviceID ?? "paired", kind: "mac", name: saved.pairedName ?? "Mac", endpoint: saved.pairedEndpoint)
    let initial = try HTTPSCompanionTransport(host: first.endpoint, identity: identity, metadata: deviceMetadata, performer: httpPerformer)
    libraryHosts = hosts; membership = saved
    transport = initial
    engine = MobileSyncEngine(store: store, hosts: hosts, initial: initial)
    return true
  }

  /// After a synchronization: direct calls (note bodies, capabilities,
  /// receipts) go to the host it chose.
  func adoptCurrentLibraryHost(_ engine: MobileSyncEngine) async {
    guard let hosts = engine.hosts else { return }
    if let current = await engine.currentTransport() as? HTTPSCompanionTransport { transport = current }
    let snapshot = await hosts.snapshot()
    if membership != snapshot { membership = snapshot }
  }

  /// Right after a pairing: does the Mac accept this phone's signature?
  /// An older Mac answers that it does not accept member requests.
  func probeMemberPairing(endpoint: URL, identity: MobileMemberIdentity) async -> Bool? {
    do {
      _ = try await HTTPSCompanionTransport(host: endpoint, identity: identity, metadata: deviceMetadata, performer: httpPerformer).probe()
      return true
    } catch MobileConnectionError.memberUnsupported { return false }
    catch { return nil }
  }

  /// Whether a Mac paired with now belongs to the same library set as this
  /// phone's existing replica: its registry holds a workspace of the library
  /// the phone was bound to. Then nothing is re-uploaded; the next sync moves
  /// the replica to it like any other host.
  func joinsSameLibrarySet(endpoint: URL, identity: MobileMemberIdentity, previousLibraryID: String?) async -> Bool {
    guard let previousLibraryID else { return false }
    guard let registry = try? await HTTPSCompanionTransport(host: endpoint, identity: identity, metadata: deviceMetadata,
                                                           performer: httpPerformer).executionWorkspaces() else { return false }
    return registry.contains { $0.libraryID == previousLibraryID }
  }

  /// Records the membership after a successful pairing and switches to signed
  /// requests. `accepted == false` keeps the bearer connection and shows
  /// "Update everything".
  func finishMemberPairing(endpoint: URL, accepted: Bool?) async {
    guard let file = membershipFile else { return }
    do {
      let identity = try loadMemberIdentity()
      var next = MobileMembershipState(deviceID: state.deviceID, pairedEndpoint: endpoint)
      next.memberRequestsAccepted = accepted
      if let previous = try MobileLibraryHosts.load(file: file), previous.deviceID == state.deviceID {
        // Keep what the phone already knows about the other members.
        next.members = previous.members; next.membersRevision = previous.membersRevision
      }
      _ = try MobileLibraryHosts(state: next, identity: identity, file: file, metadata: deviceMetadata, performer: httpPerformer)
      membership = next
      if accepted != false {
        let previousEngine = engine
        if try configureMemberTransport() { await previousEngine?.cancelSynchronization() }
      } else { libraryHosts = nil }
    } catch { pairingError = error.localizedDescription }
  }

  func clearMembership() {
    if let file = membershipFile { try? MobileLibraryHosts.clear(file: file) }
    libraryHosts = nil; membership = nil
  }
}
