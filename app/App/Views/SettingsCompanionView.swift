import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsCompanionView: View {
    @Bindable var model: ApplicationModel
    @Bindable var host: CompanionHostController
    @State private var recoveryError: String?
    var reservesRailControlSpace = false
    var onBack: () -> Void

    var body: some View {
        SettingsPage(title: "iPhone companion",
            detail: "Capture ideas anywhere. Work with the same folders, notes, and agents on your Mac.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            SettingsCard(title: "Share this workspace", detail: "Connect this Mac and your iPhone to the same Tailscale network.") {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(host.status, systemImage: host.endpoint == nil ? "iphone.slash" : "iphone.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .medium))
                        Text("Sharing prevents idle sleep. Keep this Mac powered on and awake. Closing its window keeps access available; quitting Woven Matter or stopping sharing ends access.")
                            .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        if let endpoint = host.endpoint {
                            Text(endpoint.absoluteString).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 12)
                    Button(host.endpoint == nil ? "Start sharing" : "Stop sharing") {
                        if host.endpoint == nil { Task { await host.start() } }
                        else { host.stopSharing() }
                    }
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(host.isStarting)
                    .accessibilityIdentifier("companion.sharing")
                }
            }
            if !model.companionRecoveredNoteDrafts.isEmpty {
                SettingsCard(title: "Recovered writing", detail: "These drafts are preserved locally after a conflict or deletion. Save a copy to keep them as separate notes.") {
                    ForEach(model.companionRecoveredNoteDrafts) { draft in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.title.isEmpty ? "Untitled note" : draft.title).font(.system(size: 13, weight: .medium))
                                Text(draft.error).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                            Spacer()
                            Button("Save a copy") {
                                Task {
                                    do { _ = try await model.preserveRecoveredNoteAsCopy(id: draft.id); recoveryError = nil }
                                    catch { recoveryError = error.localizedDescription }
                                }
                            }.buttonStyle(SettingsQuietButtonStyle())
                        }
                    }
                    if let recoveryError { Text(recoveryError).font(.system(size: 12)).foregroundStyle(.red) }
                }
            }
            if let message = host.errorMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.red)
                    .textSelection(.enabled).accessibilityIdentifier("companion.error")
            }
            if !host.pairedDevices.isEmpty {
                SettingsCard(title: "Paired iPhone", detail: "Revoking access keeps the iPhone's locally saved writing on that device.") {
                    ForEach(host.pairedDevices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone").font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.system(size: 13, weight: .medium))
                                if let seen = host.lastSeenAt {
                                    Text("Last connected \(seen.formatted(date: .omitted, time: .shortened))")
                                        .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                } else {
                                    Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                }
                            }
                            Spacer()
                            Button("Revoke access", role: .destructive) { Task { await host.revoke(device.id) } }
                                .buttonStyle(SettingsQuietButtonStyle())
                                .accessibilityIdentifier("companion.revoke")
                        }
                    }
                }
            } else if host.endpoint != nil {
                SettingsCard(title: "Pair your iPhone", detail: "Open Woven Matter on your iPhone and scan this code. It expires in five minutes and can be used once.") {
                    if let payload = host.pairingPayload {
                        HStack(alignment: .center, spacing: 24) {
                            if let qr = qrImage(payload.encodedURL.absoluteString) {
                                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                                    .padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .accessibilityLabel("One-time iPhone pairing QR code")
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
                                Button("New code") { Task { await host.createPairingCode() } }
                                    .buttonStyle(SettingsQuietButtonStyle())
                            }
                        }.accessibilityIdentifier("companion.pairing-code")
                    } else {
                        Button("Create pairing code") { Task { await host.createPairingCode() } }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .accessibilityIdentifier("companion.create-code")
                    }
                }
            }
        }
    }

    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
