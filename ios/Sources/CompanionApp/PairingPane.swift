import SwiftUI
import VisionKit
import AVFoundation

struct PairingPane: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CompanionModel
  @State private var scanning = false
  @State private var scannerError: String?
  @State private var confirmDisconnect = false
  var body: some View {
    Form {
      if let credential = model.credential {
        Section("Central database") {
          Text(credential.endpoint.host ?? "Paired database").textSelection(.enabled)
          Button("Unpair", role: .destructive) { confirmDisconnect = true }.disabled(model.pairingInProgress)
        }
      } else {
        Section {
          Button { Task { await beginScanning() } } label: { Label("Scan pairing code", systemImage: "qrcode.viewfinder") }
            .disabled(model.pairingInProgress).accessibilityIdentifier("pairing-scan")
          TextField("Paste pairing link", text: $model.pairingText, axis: .vertical)
            .dashboardInput().textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("pairing-link")
          Button(model.pairingInProgress ? "Pairing…" : "Pair") {
            guard let url = URL(string: model.pairingText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
              model.pairingError = "Paste the full pairing link from your Mac."; return
            }
            Task { await model.pair(url: url) }
          }.disabled(model.pairingInProgress || model.pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("pairing-connect")
        } header: { Text("Device Connections") } footer: {
          Text("On the Mac hosting your central database, open Woven Matter → Settings → Apple Devices. Scan its code or paste its link. Both devices must use the same Tailscale network.")
        }

      }
      if let problem = model.pairingError ?? scannerError {
        Section { Text(problem).font(.callout).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
      }
    }.mobileNavigationPage("Device Connections")
      .sheet(isPresented: $scanning) {
        NavigationStack {
          QRScanner(found: { value in
            scanning = false
            if let url = URL(string: value) { Task { await model.pair(url: url) } }
          }, failed: { message in scanning = false; scannerError = message }).ignoresSafeArea(edges: .bottom).navigationTitle("Scan pairing code")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
        }
      }
      .confirmationDialog("Unpair from the central database?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
        Button("Unpair", role: .destructive) { Task { await model.disconnectMac() } }
      } message: { Text("Your notes, chats, provider sign-ins, and pending changes stay on this device. Access to its connected workspaces ends until you pair again.") }
      .tint(theme.palette.themeAccent)
  }
  private func beginScanning() async {
    scannerError = nil
    guard DataScannerViewController.isSupported else { scannerError = "Camera scanning is unavailable on this device. Paste the pairing link instead."; return }
    let allowed = await AVCaptureDevice.requestAccess(for: .video)
    guard allowed, DataScannerViewController.isAvailable else { scannerError = "Enable Camera access in Settings, or paste the pairing link."; return }
    scanning = true
  }
}

private struct QRScanner: UIViewControllerRepresentable {
  var found: (String) -> Void
  var failed: (String) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(found: found) }
  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
      recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    do { try scanner.startScanning() } catch { Task { @MainActor in failed("The camera could not start. Paste the pairing link instead.") } }
    return scanner
  }
  func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
  static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }
  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    var found: (String) -> Void
    var handled = false
    init(found: @escaping (String) -> Void) { self.found = found }
    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      guard !handled else { return }
      for item in addedItems {
        if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, value.hasPrefix("wovenmatter://pair") {
          handled = true; dataScanner.stopScanning(); found(value); return
        }
      }
    }
  }
}
