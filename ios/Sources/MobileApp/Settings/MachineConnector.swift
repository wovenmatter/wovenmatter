import Foundation
import Observation
import WovenDevice
import WovenProtocol

/// Connecting this device to the person's machines with a code from one of
/// their Macs: the typed text, and how the attempt is going. The device's
/// core dials that Mac and learns where every other machine is.
@MainActor
@Observable
final class MachineConnector {
    enum Phase: Equatable {
        case idle
        case connecting
        /// The Mac answered; waiting for the machines it named to appear.
        case finding
        case failed(String)
    }

    /// What the person typed or pasted: a code in any case, with or without
    /// dashes, or a connection link.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            submitted = false
            if case .failed = phase { phase = .idle }
        }
    }
    private(set) var phase: Phase = .idle
    /// The person tried to connect with what is typed.
    private var submitted = false
    @ObservationIgnored private var attempt: Task<Void, Never>?

    var code: ConnectionCode? { ConnectionCode(text) }
    var isBusy: Bool { phase == .connecting || phase == .finding }

    /// Why the text is not a code: as soon as it cannot become one, or once
    /// the person tries it. A six-character code may still be the start of a
    /// ten-character one.
    var problem: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == nil, !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return "That link isn’t a connection link from Woven Matter." }
        let symbols = trimmed.filter { $0 != "-" && !$0.isWhitespace }
        let impossible = symbols.count >= 10 || symbols.contains { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        guard impossible || submitted else { return nil }
        return "Check the code against your Mac; a character is off."
    }

    /// Connects with what is typed, or says why it is not a code.
    func submit(model: MobileModel, done: @escaping @MainActor () -> Void = {}) {
        guard let code else { return submitted = true }
        connect(code, model: model, done: done)
    }

    /// Dials the Mac `code` names. On success the text clears and `done` runs
    /// once the machines are listed.
    func connect(_ code: ConnectionCode, model: MobileModel, done: @escaping @MainActor () -> Void = {}) {
        attempt?.cancel()
        text = code.code
        phase = .connecting
        attempt = Task {
            do {
                try await model.device.add(code)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.message(for: error))
                return
            }
            phase = .finding
            // The core links to each machine on its own; the list follows.
            let machines = model.app.machines
            for _ in 0..<40 where !Task.isCancelled {
                await machines.reload()
                if machines.machines.contains(where: { machines.serverStatus(on: $0.id)?.hostName != nil }) { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return }
            text = ""
            phase = .idle
            done()
        }
    }

    func cancel() {
        attempt?.cancel()
        attempt = nil
        if isBusy { phase = .idle }
    }

    /// Shown when scanning cannot start or finds no code.
    func fail(_ message: String) {
        phase = .failed(message)
    }

    static func message(for error: any Error) -> String {
        switch error as? DeviceConnectionError {
        case .unreachable:
            "Nothing answered at that code. Check that Tailscale is on for this \(ThisDevice.kind) and that the Mac is awake."
        case .notWoven:
            "Something answered there, but it isn’t Woven Matter. Check the code against your Mac."
        case .otherRelease(let name, let version):
            "\(name) runs Woven Matter \(version) — update it or this \(ThisDevice.kind) so they match."
        case nil:
            error.localizedDescription
        }
    }
}
