import AppKit
import Darwin
import Foundation

/// Woven Matter VM helper: a per-user launch agent (KeepAlive) that owns the
/// Woven-managed Linux VM running Docker Engine for bots.
///   WovenMatterVMHelper --root <support>/WovenVM [--resources <dir>]
@main
enum VMHelperMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        var arguments = CommandLine.arguments.dropFirst()
        var root: URL?
        var resources = Bundle.main.executableURL!.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/WovenVM", directoryHint: .isDirectory)
        while let argument = arguments.popFirst() {
            switch argument {
            case "--root": root = arguments.popFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--resources": resources = arguments.popFirst().map { URL(fileURLWithPath: $0, isDirectory: true) } ?? resources
            default:
                FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
                exit(64)
            }
        }
        guard let root else {
            FileHandle.standardError.write(Data("usage: WovenMatterVMHelper --root DIR [--resources DIR]\n".utf8))
            exit(64)
        }
        let helper: VMHelper
        do {
            helper = try VMHelper(paths: WovenVMPaths(root: root), resources: resources)
            try helper.start()
        } catch {
            FileHandle.standardError.write(Data("WovenMatterVMHelper: \(error.localizedDescription)\n".utf8))
            // A second helper for the same root exits cleanly so launchd does
            // not keep relaunching it; anything else is retried by launchd.
            exit(error is HelperAlreadyRunning ? 0 : 1)
        }
        // launchd stops the job with SIGTERM (logout, bootout): shut the guest
        // down cleanly within the job's ExitTimeOut.
        var sources: [any DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { detach { helper.terminate(code: 0) } }
            source.resume()
            sources.append(source)
        }
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            detach { helper.pushTimeAfterWake() }
        }
        withExtendedLifetime((sources, observer)) { RunLoop.main.run() }
    }
}
