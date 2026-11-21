import AVFoundation
import SwiftUI
import UIKit
import VisionKit
import WovenProtocol

/// The connect screen's rows: where the code is on the Mac, Scan code, and a
/// field for typing or pasting it, with Connect.
struct ConnectSection: View {
    @Bindable var model: MobileModel
    @Bindable var connector: MachineConnector
    /// Runs once the machines are listed.
    var done: @MainActor () -> Void = {}
    @State private var scanning = false
    @State private var cameraDenied = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Section {
            Button {
                startScanning()
            } label: {
                Label("Scan code", systemImage: "qrcode.viewfinder")
                    .foregroundStyle(WovenPalette.foreground)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(connector.isBusy)
            .settingsRow()
            .accessibilityIdentifier("connect-scan")
        } header: {
            SettingsHeader(title: "Connect to your Mac",
                           detail: "Open Settings → Apple Devices in Woven Matter on your Mac, with both on the same tailnet.")
        }
        Section {
            TextField("Code or link", text: $connector.text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
                .focused($fieldFocused)
                .onSubmit { connector.submit(model: model, done: done) }
                .disabled(connector.isBusy)
                .wovenInput()
                .settingsFieldRow()
                .accessibilityLabel("Connection code")
                .accessibilityIdentifier("connect-code")
            SettingsPrimaryButton("Connect") {
                fieldFocused = false
                connector.submit(model: model, done: done)
            }
            .disabled(connector.code == nil || connector.isBusy)
            .accessibilityIdentifier("connect-submit")
            if let line = statusLine {
                SettingsCaption(line.text, isError: line.isError).accessibilityIdentifier("connect-status")
            }
            if cameraDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Allow camera access", destination: url)
                    .foregroundStyle(WovenPalette.success)
                    .frame(minHeight: 44)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            CodeScannerPage { code in
                scanning = false
                connector.connect(code, model: model, done: done)
            } failed: { message in
                scanning = false
                connector.fail(message)
            }
        }
    }

    private var statusLine: (text: String, isError: Bool)? {
        switch connector.phase {
        case .connecting: ("Connecting to your Mac…", false)
        case .finding: ("Finding your machines…", false)
        case .failed(let message): (message, true)
        case .idle: connector.problem.map { ($0, true) }
        }
    }

    /// The camera, when this device has one and Woven Matter may use it.
    private func startScanning() {
        cameraDenied = false
        guard DataScannerViewController.isSupported else {
            return connector.fail("This \(ThisDevice.kind) can’t scan codes here. Type the code instead.")
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scanning = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) { scanning = true } else { denied() }
            }
        default:
            denied()
        }
    }

    private func denied() {
        cameraDenied = true
        connector.fail("Woven Matter can’t use the camera. Allow it in Settings, or type the code.")
    }
}

/// The camera, full screen, until it sees a connection code.
private struct CodeScannerPage: View {
    let found: (ConnectionCode) -> Void
    let failed: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CodeScanner(found: found, failed: failed)
                .ignoresSafeArea()
                .navigationTitle("Scan code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.accessibilityIdentifier("scan-cancel")
                    }
                }
        }
    }
}

/// VisionKit's QR scanner, reporting the first connection code it reads.
private struct CodeScanner: UIViewControllerRepresentable {
    let found: (ConnectionCode) -> Void
    let failed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            let failed = failed
            Task { @MainActor in failed("The camera could not start. Type the code instead.") }
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (ConnectionCode) -> Void
        private var handled = false

        init(found: @escaping (ConnectionCode) -> Void) {
            self.found = found
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for case .barcode(let barcode) in addedItems {
                guard let payload = barcode.payloadStringValue, let code = ConnectionCode(payload) else { continue }
                handled = true
                dataScanner.stopScanning()
                found(code)
                return
            }
        }
    }
}
