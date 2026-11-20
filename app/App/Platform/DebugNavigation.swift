import SwiftUI

/// Debug builds only: with `--debug-open FILE`, every SIGUSR2 reads FILE and
/// shows what it names (`note:ID`, a window destination such as `library`, or
/// a sheet such as `history` or `trash`), so a build can be checked without
/// driving the mouse. Release builds ignore it.
struct DebugNavigation: ViewModifier {
    let openNote: (String) -> Void
    let show: (WindowDestination) -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(NotificationCenter.default.publisher(for: DebugNavigationSignal.name)) { notification in
            guard let request = notification.object as? String else { return }
            if request.hasPrefix("note:") { openNote(String(request.dropFirst(5))) }
            else if let destination = WindowDestination(rawValue: request) { show(destination) }
        }
        .onAppear { DebugNavigationSignal.startIfRequested() }
        #else
        content
        #endif
    }
}

/// Runs `action` when the debug request names `request`.
struct DebugRequest: ViewModifier {
    let request: String
    let action: () -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(NotificationCenter.default.publisher(for: DebugNavigationSignal.name)) { notification in
            if notification.object as? String == request { action() }
        }
        #else
        content
        #endif
    }
}

/// Runs `action` with the rest of a debug request that starts with `prefix`.
struct DebugCommand: ViewModifier {
    let prefix: String
    let action: (String) -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(NotificationCenter.default.publisher(for: DebugNavigationSignal.name)) { notification in
            if let request = notification.object as? String, request.hasPrefix(prefix) { action(String(request.dropFirst(prefix.count))) }
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Debug builds: `PREFIX…` requests run `action` with what follows the prefix.
    func debugCommand(_ prefix: String, _ action: @escaping (String) -> Void) -> some View {
        modifier(DebugCommand(prefix: prefix, action: action))
    }

    func debugRequest(_ request: String, _ action: @escaping () -> Void) -> some View {
        modifier(DebugRequest(request: request, action: action))
    }

    func debugNavigation(openNote: @escaping (String) -> Void, show: @escaping (WindowDestination) -> Void) -> some View {
        modifier(DebugNavigation(openNote: openNote, show: show))
    }
}

#if DEBUG
@MainActor
enum DebugNavigationSignal {
    static let name = Notification.Name("WovenDebugNavigation")
    private static var source: (any DispatchSourceSignal)?

    static func startIfRequested() {
        let arguments = CommandLine.arguments
        guard source == nil, let index = arguments.firstIndex(of: "--debug-open"), index + 1 < arguments.count else { return }
        let file = URL(fileURLWithPath: arguments[index + 1])
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            NotificationCenter.default.post(name: name, object: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        source.resume()
        self.source = source
    }

}
#endif
