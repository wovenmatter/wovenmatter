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
    var canPairWithCentral: Bool
    @State private var devices = MacDeviceSetupModel()
    var body: some View {
        SettingsSummaryRow("Find on your network") {
            SettingsNote("Find other Macs on your Tailscale network, even when Woven Matter is closed.")
            MacTailnetDiscoveryView(devices: devices, pairing: pairing, host: host, canPairWithCentral: canPairWithCentral)
        }
        // Stays visible when the row above is collapsed.
        if let error = pairing.errorMessage { SettingsError(error) }
    }
}

struct DevicePairingCodeCard: View {
    @Bindable var host: CompanionHostController
    var body: some View {
        SettingsSummaryRow("Show a QR code or link") {
            SettingsNote("Scan the QR code or paste its link on another device.")
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
                                .font(.settingsBody).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Button("Copy pairing link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(payload.encodedURL.absoluteString, forType: .string)
                        }.buttonStyle(SettingsQuietButtonStyle())
                        Button("New code") { Task { await host.createPairingCode() } }.buttonStyle(SettingsQuietButtonStyle())
                    }
                }.accessibilityIdentifier("companion.pairing-code")
            } else {
                Button("Create QR code or link") { Task { await host.createPairingCode() } }
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(host.endpoint == nil || host.isStarting)
                    .accessibilityIdentifier("companion.create-code")
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
