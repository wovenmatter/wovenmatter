import Foundation
import WovenMatterCompanion

// Maintenance generator: one canonical Swift catalog, bundled for Linux's
// independently running workspace service. No account or runtime access.
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let bytes = try encoder.encode(WovenMCPCatalog.tools) + Data("\n".utf8)
if CommandLine.arguments.count == 2 {
  try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
} else if CommandLine.arguments.count == 1 {
  FileHandle.standardOutput.write(bytes)
} else {
  throw NSError(domain: "WovenMCPCatalogExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: WovenMCPCatalogExport [output.json]"])
}
