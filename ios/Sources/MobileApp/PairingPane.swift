import SwiftUI
import LibraryClient
import VisionKit
import AVFoundation

struct PairingPane: View {
  @Environment(\.wovenTheme) private var theme
  @Bindable var model: MobileModel
  @State private var scanning = false
  @State private var scannerError: String?
  @State private var confirmDisconnect = false
  var body: some View {
    Form {
      if let credential = model.credential {
        Section {
          Text(model.libraryHostName.map { "Syncing with " + $0 } ?? credential.endpoint.host ?? "Paired database")
            .textSelection(.enabled).accessibilityIdentifier("pairing-library-host")
          ForEach(memberDevices) { member in
            LabeledContent(member.name, value: peerState(member)).accessibilityIdentifier("pairing-member-" + member.kind)
          }
          Button("Unpair", role: .destructive) { confirmDisconnect = true }.disabled(model.pairingInProgress)
        } header: { Text("Your devices") } footer: {
          if let notice = model.membershipNotice { Text(notice).accessibilityIdentifier("pairing-membership-notice") }
          else { Text("\(model.deviceWorkspaceName) connects directly to each Mac and Linux machine. Any one that is online keeps it in sync.") }
        }
        if model.needsMemberPairing { pairingControls(header: "Pair again", footer: "Scan the code from Woven Matter → Settings → Apple Devices on any of your Macs. Pairing once is enough for every device.") }
      } else {
        pairingControls(header: "Device Connections", footer: "On any Mac with Woven Matter, open Settings → Apple Devices. Scan its code or paste its link. Both devices must use the same Tailscale network. After pairing once, \(model.deviceWorkspaceInSentence) reaches every Mac and Linux machine directly.")
      }
      if let problem = model.pairingError ?? scannerError {
        Section { Text(problem).font(.callout).foregroundStyle(WovenPalette.danger).textSelection(.enabled) }
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
  @ViewBuilder private func pairingControls(header: String, footer: String) -> some View {
    Section {
      Button { Task { await beginScanning() } } label: { Label("Scan pairing code", systemImage: "qrcode.viewfinder") }
        .disabled(model.pairingInProgress).accessibilityIdentifier("pairing-scan")
      TextField("Paste pairing link", text: $model.pairingText, axis: .vertical)
        .wovenInput().textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("pairing-link")
      Button(model.pairingInProgress ? "Pairing…" : "Pair") {
        guard let url = URL(string: model.pairingText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
          model.pairingError = "Paste the full pairing link from your Mac."; return
        }
        Task { await model.pair(url: url) }
      }.disabled(model.pairingInProgress || model.pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("pairing-connect")
    } header: { Text(header) } footer: { Text(footer) }
  }
  /// Every Mac and Linux member, from whichever one this phone synced with.
  private var memberDevices: [MobileLibraryMember] {
    (model.membership?.members ?? []).filter { !$0.revoked && ($0.kind == "mac" || $0.kind == "linux") }
      .sorted { $0.kind == $1.kind ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.kind == "mac" }
  }
  private func peerState(_ member: MobileLibraryMember) -> String {
    if member.deviceID == model.libraryHostDeviceID, model.online { return "Syncing" }
    switch model.membership?.syncStatus?.peers.first(where: { $0.deviceID == member.deviceID })?.state {
    case "online": return "Online"
    case "updateRequired": return "Update needed"
    case "failing": return "Not syncing"
    case "offline": return "Offline"
    default: return member.kind == "mac" ? "Mac" : "Linux"
    }
  }
  private func beginScanning() async {
    scannerError = nil
    guard DataScannerViewController.isSupported else { scannerError = "Camera scanning is unavailable on this device. Paste the pairing link instead."; return }
    // Tests and UI fixtures never raise the camera prompt; nothing would dismiss it.
    guard MobileModel.systemPermissionPromptsAllowed || AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      scannerError = "Camera scanning is unavailable here. Paste the pairing link instead."; return
    }
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
