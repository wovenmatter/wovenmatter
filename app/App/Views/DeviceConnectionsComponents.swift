import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import WovenMatterCompanion

struct DeviceConnectionIcon: View {
    let kind: CompanionDeviceKind
    var size: CGFloat = 20
    var body: some View {
        Group {
            switch kind {
            case .mac: DashboardLucideIcon(glyph: .monitor, size: size)
            case .iPhone: DashboardLucideIcon(glyph: .smartphone, size: size)
            case .iPad: DashboardLucideIcon(glyph: .tablet, size: size)
            case .unknown: DashboardLucideIcon(glyph: .panelsTopLeft, size: size)
            }
        }.frame(width: size + 4, height: size + 4).foregroundStyle(DashboardPalette.foreground)
    }
    static func label(_ kind: CompanionDeviceKind) -> String {
        switch kind { case .mac: "Mac"; case .iPhone: "iPhone"; case .iPad: "iPad"; case .unknown: "Device" }
    }
}

struct DevicePairingDiscoveryCard: View {
    @Bindable var pairing: CompanionMacPairingController
    @Bindable var host: CompanionHostController
    var isCentral: Bool
    var canPairWithCentral: Bool
    private var peers: [CompanionDiscoveredPeer] {
        let candidates = pairing.peers + (isCentral ? host.discoveredPeers : [])
        var endpoints = Set<String>()
        return candidates.filter { peer in
            guard peer.endpoint != host.endpoint, endpoints.insert(peer.id).inserted else { return false }
            return peer.advertisement.role == .central ? canPairWithCentral : isCentral && host.endpoint != nil
        }.sorted { $0.advertisement.identity.deviceName.localizedStandardCompare($1.advertisement.identity.deviceName) == .orderedAscending }
    }
    var body: some View {
        SettingsCard(title: "Find devices", detail: "Devices must be on the same Tailscale network.") {
            HStack {
                Button(pairing.isDiscovering ? "Searching…" : "Find devices") {
                    Task { await pairing.refreshDiscovery(); if isCentral { await host.refreshDiscovery() } }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(pairing.isDiscovering)
                if canPairWithCentral {
                    Button(pairing.isPairingMode ? "Stop pairing mode" : "Allow a central Mac to invite this Mac") {
                        if pairing.isPairingMode { pairing.stopPairingMode() }
                        else { Task { await pairing.startPairingMode() } }
                    }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
            ForEach(peers) { peer in
                HStack(spacing: 12) {
                    DeviceConnectionIcon(kind: peer.advertisement.identity.metadata.kind)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peer.advertisement.identity.deviceName).font(.system(size: 13, weight: .medium))
                        Text(peer.advertisement.role == .central ? "Central library" : DeviceConnectionIcon.label(peer.advertisement.identity.metadata.kind))
                            .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer()
                    if peer.advertisement.role == .central {
                        Button("Pair") { Task { await pairing.requestPairing(with: peer) } }
                            .buttonStyle(SettingsQuietButtonStyle()).disabled(pairing.isRequestPending)
                    } else {
                        Button("Invite") { Task { await host.invitePairing(peer: peer) } }.buttonStyle(SettingsQuietButtonStyle())
                    }
                }
            }
            if pairing.isRequestPending {
                HStack {
                    Text("Waiting for approval on the central Mac").font(.system(size: 12))
                    Spacer()
                    Button("Cancel") { pairing.cancelRequest() }.buttonStyle(SettingsQuietButtonStyle())
                }
            } else if pairing.isPairingMode {
                Text("This Mac can receive an invitation for ten minutes.").font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            ForEach(pairing.invitations) { invitation in
                HStack {
                    Text("Connect to \(invitation.central.deviceName)?").font(.system(size: 13))
                    Spacer()
                    Button("Decline") { pairing.declineInvitation(id: invitation.id) }.buttonStyle(SettingsQuietButtonStyle())
                    Button("Connect") { Task { await pairing.acceptInvitation(id: invitation.id) } }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
            if let error = pairing.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
        }
    }
}

struct DevicePairingCodeCard: View {
    @Bindable var host: CompanionHostController
    var body: some View {
        SettingsCard(title: "Pair with a code", detail: "Scan the QR code or paste its link on another device.") {
            if let payload = host.pairingPayload {
                HStack(alignment: .center, spacing: 24) {
                    if let qr = qrImage(payload.encodedURL.absoluteString) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 160, height: 160)
                            .padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("One-time device pairing QR code")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if let expiry = host.pairingExpiresAt {
                            Text("Expires at \(expiry.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Button("Copy pairing link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(payload.encodedURL.absoluteString, forType: .string)
                        }.buttonStyle(SettingsQuietButtonStyle())
                        Button("New code") { Task { await host.createPairingCode() } }.buttonStyle(SettingsQuietButtonStyle())
                    }
                }.accessibilityIdentifier("companion.pairing-code")
            } else {
                Button("Create pairing code") { Task { await host.createPairingCode() } }
                    .buttonStyle(SettingsQuietButtonStyle()).accessibilityIdentifier("companion.create-code")
            }
        }
    }
    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
