import SwiftUI
import VisionKit
import AVFoundation

struct PairingPane: View {
  @Bindable var model: CompanionModel
  @Environment(\.dismiss) private var dismiss
  @State private var scanning = false
  @State private var scannerError: String?
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Image(systemName: "iphone.and.arrow.forward").font(.system(size: 40)).foregroundStyle(MobileTheme.green)
          Text("Your workspace, within reach.").font(.title.bold())
          Text("On your Mac, open Woven Matter → Settings → iPhone Companion and create a pairing code. Keep both devices connected to the same Tailscale network.").foregroundStyle(.secondary)
          Button { Task { await beginScanning() } } label: { Label("Scan Mac pairing code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(6) }.buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(model.connecting)
          if let scannerError { Text(scannerError).font(.caption).foregroundStyle(.secondary) }
          Text("Or paste the pairing link").font(.subheadline.weight(.semibold))
          TextField("wovenmatter://pair?…", text: $model.pairingText, axis: .vertical)
            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            .padding(12).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("pairing-link")
          Button(model.connecting ? "Pairing…" : "Pair with Mac") {
            guard let url = URL(string: model.pairingText.trimmingCharacters(in: .whitespacesAndNewlines)) else { model.errorMessage = "Paste the full pairing link from your Mac."; return }
            Task { await model.pair(url: url) }
          }.buttonStyle(.bordered).disabled(model.connecting || model.pairingText.isEmpty)
          Text("Pairing gives this iPhone access to your Mac workspace. Provider credentials stay on your Mac. You can revoke this iPhone in desktop Settings.").font(.caption).foregroundStyle(.secondary)
          Text("Closing the Mac window can leave Woven Matter running. Quitting the app, stopping companion access, sleep, or a network interruption ends the connection. Notes saved here remain available.").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
      }.navigationTitle("Pair your Mac").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $scanning) {
          NavigationStack {
            QRScanner(found: { value in
              scanning = false
              if let url = URL(string: value) { Task { await model.pair(url: url) } }
            }, failed: { message in scanning = false; scannerError = message }).ignoresSafeArea(edges: .bottom).navigationTitle("Scan pairing code")
              .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
          }
        }
    }.tint(MobileTheme.green)
  }
  private func beginScanning() async {
    guard DataScannerViewController.isSupported else { scannerError = "Camera scanning is unavailable on this device. Paste the pairing link instead."; return }
    let allowed = await AVCaptureDevice.requestAccess(for: .video)
    guard allowed, DataScannerViewController.isAvailable else { scannerError = "Enable Camera access in iPhone Settings, or paste the pairing link."; return }
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
