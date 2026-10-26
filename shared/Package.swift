// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "WovenMatterCompanion",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [.library(name: "WovenMatterCompanion", targets: ["WovenMatterCompanion"])],
  targets: [
    .target(name: "WovenMatterCompanion"),
    .executableTarget(name: "WovenMCPCatalogExport", dependencies: ["WovenMatterCompanion"], path: "Tools/WovenMCPCatalogExport"),
    .testTarget(name: "WovenMatterCompanionTests", dependencies: ["WovenMatterCompanion"])
  ]
)
