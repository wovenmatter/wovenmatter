import AppKit
import Foundation

/// A windowless test process, with runtime resources and all data explicitly scoped.
@main
struct EmbeddedRuntimeSmokeMain {
  @MainActor
  static func main() {
    precondition(CommandLine.arguments.count == 3)
    let documents = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
      await SmokeRunner(documents: documents, resourceURL: resources).run()
      application.terminate(nil)
    }
    application.run()
  }
}
