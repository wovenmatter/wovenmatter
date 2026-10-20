import SwiftUI
import Foundation

@main
struct SmokeApp: App {
  var body: some Scene {
    WindowGroup {
      Text("Embedded Python runtime validation").task {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        await SmokeRunner(documents: documents).run()
      }
    }
  }
}
