import Foundation
import WovenMatterLibraryHost

exit(await LibraryHostCommand.main(Array(CommandLine.arguments.dropFirst())))
