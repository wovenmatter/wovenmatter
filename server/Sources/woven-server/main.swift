import Foundation
import WovenServerKit

// woven-server DATA-FOLDER [options]; see ServerCommand for the options.
do {
  exit(try await ServerCommand.run(Array(CommandLine.arguments.dropFirst())))
} catch {
  FileHandle.standardError.write(Data("woven-server: \(error)\n".utf8))
  exit(2)
}
