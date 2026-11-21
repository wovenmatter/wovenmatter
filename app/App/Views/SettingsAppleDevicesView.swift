import AppKit
import CoreImage
import SwiftUI
import WovenProtocol

/// Settings → Apple Devices: the code an iPhone or iPad connects with, and the
/// devices in the library with Remove.
struct SettingsAppleDevicesView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var pendingRemoval: DeviceStatus?

    private var devices: DevicesStore { model.devices }

    var body: some View {
        SettingsPage(title: "Apple Devices", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if devices.hasLoaded {
                connectSection
                devicesSection
            }
            if let error = devices.errorMessage { SettingsError(error) }
        }
        // A device's last sync is not a library change, so the page reads it again while it is open.
        .task {
            while !Task.isCancelled {
                await devices.reload()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.device.name ?? "this device")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { status in
            Button("Remove", role: .destructive) {
                pendingRemoval = nil
                Task { await devices.remove(status.device.id) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { status in
            Text("This deletes its Quick Chats and folders from every machine. The \(Self.kind(status.device)) starts again empty.")
        }
    }

    @ViewBuilder private var connectSection: some View {
        if let code = devices.connectionCode {
            SettingsSection(
                title: "Connect an iPhone or iPad",
                detail: "Open Woven Matter on your iPhone or iPad and scan this code, or type it. Both need to be on the same tailnet."
            ) {
                HStack(alignment: .center, spacing: 24) {
                    ConnectionQRCode(link: code.link(scheme: Self.linkScheme))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(code.code)
                            .font(.system(.largeTitle, design: .monospaced).weight(.medium))
                            .textSelection(.enabled)
                            .accessibilityLabel("Code \(code.code.map(String.init).joined(separator: " "))")
                        Button("Copy code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code.code, forType: .string)
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
                .padding(.top, 4)
            }
        } else {
            SettingsSection(title: "Connect an iPhone or iPad") {
                SettingsEmpty("This Mac is not on your tailnet.")
            }
        }
    }

    private var devicesSection: some View {
        SettingsSection(title: "Your devices") {
            if devices.devices.isEmpty {
                SettingsEmpty("No devices yet.")
            } else {
                ForEach(devices.devices, id: \.device.id) { status in
                    SettingsRow(title: status.device.name, detail: Self.detail(status)) {
                        Button("Remove…") { pendingRemoval = status }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .accessibilityLabel("Remove \(status.device.name)")
                    }
                }
            }
        }
    }

    static func kind(_ device: WovenProtocol.Machine) -> String { device.platform == .iPad ? "iPad" : "iPhone" }

    private static func detail(_ status: DeviceStatus) -> String {
        guard let synced = status.lastSyncedAt else { return kind(status.device) + " · Not synced with this Mac yet" }
        return kind(status.device) + " · Synced with this Mac " + min(synced, Date()).formatted(.relative(presentation: .named))
    }

    /// A development build connects the development iPhone and iPad app; a release build the released one.
    private static var linkScheme: String {
        #if DEBUG
        "wovenmatter-dev"
        #else
        "wovenmatter"
        #endif
    }
}

/// The link as a QR code, black on a plain light tile in every theme so it scans.
private struct ConnectionQRCode: View {
    let link: URL

    var body: some View {
        Group {
            if let image = Self.image(link) {
                // Each module is a whole number of points, never smoothed.
                let side = CGFloat(image.width * max(1, 148 / image.width))
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("QR code to connect an iPhone or iPad")
    }

    private static func image(_ link: URL) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(link.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }
}
