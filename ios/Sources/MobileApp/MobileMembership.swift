import Foundation
import UIKit
import LibraryClient
import MobileInference
import WovenMatterShared

/// Membership (docs/architecture/WOVEN_EVERYWHERE.md): the phone pairs once
/// with any Mac, which adds it as an `ios` member. From then on it signs every
/// request with its own key, learns every Mac and Linux member from whichever
/// one it syncs with, syncs with any online library host and manages sessions
/// on every workspace directly. It has no home Mac.
extension MobileModel {
  /// Paired, but not a member any Mac or Linux host accepts (the Mac refused
  /// its key, as after a backup is restored): it syncs nothing until it pairs again.
  var needsMemberPairing: Bool { credential != nil && libraryHosts == nil }
  /// Never paired (or unpaired): everything runs on this device. Pairing a Mac
  /// adds workspaces, agents on your computers and sync; it keeps local data.
  var isStandalone: Bool { credential == nil && state.workspaceID == nil }
  /// The Mac or Linux host this phone synced with last. Its own sessions are
  /// the "central" route; every other device's sessions go to that device.
  var libraryHostDeviceID: String? { membership?.currentHost?.deviceID ?? membership?.pairedHostDeviceID }
  var libraryHostName: String? {
    // The saved membership carries the host's real device ID and name once learned.
    guard let host = membership?.currentHost ?? synchronizationStatus.libraryHost else { return nil }
    if let member = membership?.members.first(where: { $0.deviceID == host.deviceID }) { return member.name }
    return host.name
  }
  /// The registered workspace of the library host itself, when it is a Mac.
  /// Every Mac that hosts a library advertises central history, so the host
  /// is matched by device; only a pairing that never learned its host's
  /// device ID falls back to the first such Mac.
  var centralExecutionWorkspace: ExecutionWorkspace? {
    // A copied snapshot owner keeps the capability for its history only.
    let central = executionWorkspaces.filter(\.isLiveCentralMac)
    if let host = libraryHostDeviceID?.lowercased() {
      return central.first { $0.ownerDeviceID.lowercased() == host || $0.executionDeviceID?.lowercased() == host }
    }
    return central.first
  }
  /// "Update everything" and re-pairing notices for Settings and the sync status.
  var membershipNotice: String? {
    if membership?.memberRejected == true {
      return "Pair again: \(membership?.pairedName ?? "your Mac") did not accept \(deviceWorkspaceInSentence)'s key, so it doesn't sync. In that Mac's device list remove \(deviceWorkspaceInSentence) if it is listed, then pair again."
    }
    if let message = synchronizationStatus.updateRequired { return message }
    if needsMemberPairing {
      return "Pair again with any Mac so \(deviceWorkspaceInSentence) connects directly to every Mac and Linux machine. Your notes and chats stay on \(deviceWorkspaceInSentence)."
    }
    return nil
  }

  func loadMemberIdentity() throws -> MobileMemberIdentity {
    if let memberIdentity, memberIdentity.deviceID == state.deviceID { return memberIdentity }
    let (identity, created) = try MobileMemberKeyVault.loadOrCreateReportingNew(deviceID: state.deviceID, storage: memberKeyStorage)
    // The key is this device only, so a restored backup brings the
    // membership but not the key: no Mac knows the new key until this phone
    // pairs again, so say so instead of signing requests nobody accepts.
    if created, let file = membershipFile, var saved = try? MobileLibraryHosts.load(file: file), saved.deviceID == state.deviceID,
       saved.memberRejected != true {
      saved.memberRejected = true
      try? MobileLibraryHosts.save(saved, to: file)
    }
    memberIdentity = identity
    // Inference connections whose host scope names the host Mac sign with this key.
    let signer = identity.signer
    InferenceMemberSigning.install { request, audience in try MobileRequestSigning.sign(&request, with: signer, audience: audience) }
    return identity
  }

  /// The host Mac's member device ID for an inference connection to
  /// `workspaceID`; nil while it cannot be signed for.
  func inferenceHostDeviceID(_ workspaceID: String) -> String? {
    guard let workspace = executionWorkspaces.first(where: { $0.id == workspaceID }) else { return nil }
    return membership?.audience(for: workspace)
  }

  /// Connects as a member when this phone paired with its key and the Mac
  /// accepted it. Returns false when it is not a member yet.
  func configureMemberTransport() throws -> Bool {
    // First, so a membership whose key was lost reads as refused below.
    _ = try? loadMemberIdentity()
    guard let store, let file = membershipFile, let saved = try MobileLibraryHosts.load(file: file),
          saved.deviceID == state.deviceID, saved.memberRejected != true else {
      libraryHosts = nil; membership = nil
      if let path = membershipFile, let saved = try? MobileLibraryHosts.load(file: path), saved.deviceID == state.deviceID { membership = saved }
      return false
    }
    let identity = try loadMemberIdentity()
    let hosts = try MobileLibraryHosts(state: saved, identity: identity, file: file, metadata: deviceMetadata, performer: httpPerformer)
    let first = saved.candidates(registry: executionWorkspaces).first
      ?? MobileLibraryHost(deviceID: saved.pairedHostDeviceID ?? "paired", kind: "mac", name: saved.pairedName ?? "Mac", endpoint: saved.pairedEndpoint)
    // A paired Mac whose member device ID is unknown cannot be addressed.
    guard MemberRequestSignature.isDeviceID(first.deviceID) else { libraryHosts = nil; membership = saved; return false }
    let initial = try HTTPSLibraryTransport(host: first.endpoint, hostDeviceID: first.deviceID, identity: identity, metadata: deviceMetadata, performer: httpPerformer)
    libraryHosts = hosts; membership = saved
    transport = initial
    engine = MobileSyncEngine(store: store, hosts: hosts, initial: initial)
    return true
  }

  /// Analytics go to a Mac only: the current host when it is a Mac, else the
  /// preferred Mac. Nil while this phone is not a member, so a standalone
  /// phone sends nothing. Each synchronization re-binds this as the host
  /// changes (`MobileSyncEngine`).
  func analyticsTransport() async -> (any ProductAnalyticsTransport)? {
    guard credential != nil, let hosts = libraryHosts else { return nil }
    return await hosts.analyticsTransport(current: membership?.currentHost, connection: nil, registry: executionWorkspaces)
  }

  /// After a synchronization: direct calls (note bodies, capabilities,
  /// receipts) go to the host it chose.
  func adoptCurrentLibraryHost(_ engine: MobileSyncEngine) async {
    guard let hosts = engine.hosts else { return }
    if let current = await engine.currentTransport() as? HTTPSLibraryTransport { transport = current }
    let snapshot = await hosts.snapshot()
    if membership != snapshot { membership = snapshot }
  }

  enum MemberPairingProbe: Equatable { case accepted, rejected, unknown }

  /// Right after a confirmed pairing: does the Mac accept this phone's
  /// signature? A refusal (it does not list this key) means it did not add
  /// this phone, which is never taken as acceptance.
  func probeMemberPairing(endpoint: URL, hostDeviceID: String?, identity: MobileMemberIdentity) async -> MemberPairingProbe {
    guard let hostDeviceID else { return .rejected }
    do {
      _ = try await HTTPSLibraryTransport(host: endpoint, hostDeviceID: hostDeviceID, identity: identity, metadata: deviceMetadata, performer: httpPerformer).probe()
      return .accepted
    } catch MobileConnectionError.memberUnknown { return .rejected }
    catch { return .unknown }
  }

  /// Probes the Mac once the pairing is confirmed (it signs this phone's
  /// member entry then) and records the result.
  func completeMemberPairing(endpoint: URL, hostDeviceID: String?) async {
    guard let identity = try? loadMemberIdentity() else { transport = nil; connectionLabel = "Pair again"; return }
    let probe = await probeMemberPairing(endpoint: endpoint, hostDeviceID: hostDeviceID, identity: identity)
    await finishMemberPairing(endpoint: endpoint, hostDeviceID: hostDeviceID, rejected: probe == .rejected)
  }

  /// Records the membership after a successful pairing and switches to signed
  /// requests. When the Mac refused the key nothing syncs, and Settings says
  /// "Pair again".
  func finishMemberPairing(endpoint: URL, hostDeviceID: String?, rejected: Bool = false) async {
    guard let file = membershipFile else { return }
    do {
      let identity = try loadMemberIdentity()
      var next = MobileMembershipState(deviceID: state.deviceID, pairedEndpoint: endpoint, pairedHostDeviceID: hostDeviceID)
      next.memberRejected = rejected ? true : nil
      if let previous = try MobileLibraryHosts.load(file: file), previous.deviceID == state.deviceID {
        // Keep what the phone already knows about the other members.
        next.members = previous.members; next.membersRevision = previous.membersRevision
      }
      _ = try MobileLibraryHosts(state: next, identity: identity, file: file, metadata: deviceMetadata, performer: httpPerformer)
      membership = next
      // The pairing connection confirmed the pairing; from here on every
      // request is signed, or nothing syncs.
      let previousEngine = engine
      let member = rejected ? false : try configureMemberTransport()
      if !member {
        libraryHosts = nil; transport = nil; engine = nil; connectionLabel = "Pair again"
      }
      await previousEngine?.cancelSynchronization()
    } catch { pairingError = error.localizedDescription }
  }

  func clearMembership() {
    if let file = membershipFile { try? MobileLibraryHosts.clear(file: file) }
    libraryHosts = nil; membership = nil
  }
}
